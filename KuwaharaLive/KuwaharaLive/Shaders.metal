/*
 * Generalized Kuwahara Filter — Metal (MSL) implementation
 *
 * Algorithm: "Anisotropic Kuwahara Filtering with Polynomial Weighting Functions"
 *   Jan Eric Kyprianidis, Henry Kang, Jürgen Dörsey — IEEE Transactions on
 *   Visualization and Computer Graphics, 2010.
 *
 * Reference implementation (Unity/HLSL) by Garrett Gunnell:
 *   github.com/GarrettGunnell/Post-Processing — GeneralizedKuwahara.shader
 *   Used under MIT License.
 *
 * How the filter works:
 *   The classical Kuwahara filter splits a square neighbourhood around each
 *   output pixel into four overlapping quadrants, computes the mean and variance
 *   of each, then outputs the mean of the least-variant quadrant. This produces
 *   a painterly, edge-preserving smoothing — but the hard 4-way split causes
 *   block artifacts at diagonal edges.
 *
 *   The *generalized* variant replaces the 4 hard quadrants with 8 overlapping
 *   sectors whose boundaries are defined by smooth polynomial weighting functions.
 *   Each pixel in the neighbourhood is assigned a soft weight for each of the 8
 *   sectors based on its angular position. The final output blends all 8 sector
 *   means, weighted so that sectors with lower variance contribute more heavily.
 *   This eliminates block artifacts and gives a fluid, oil-painting quality.
 */

#include <metal_stdlib>
using namespace metal;

// Parameters shared between Swift and this shader.
// Must stay in sync with KuwaharaParams in MetalRenderer.swift.
struct KuwaharaParams {
    int   kernelRadius;   // half-width of the sampling window (e.g. 4 → 9×9 samples)
    int   N;              // number of sectors — always 8
    float q;              // sharpness: steeper fall-off from high-variance sectors
    float hardness;       // scale factor in the variance weighting denominator
    float zeroCrossing;   // angle (radians) at which the polynomial weight hits zero
    float zeta;           // polynomial shape parameter; auto = 2 / kernelRadius
    uint  enabled;        // 0 = passthrough, 1 = apply filter
};

kernel void kuwahara(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant KuwaharaParams&        params     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint width  = inTexture.get_width();
    const uint height = inTexture.get_height();

    if (gid.x >= width || gid.y >= height) return;

    // Passthrough when the filter is toggled off.
    if (!params.enabled) {
        outTexture.write(inTexture.read(gid), gid);
        return;
    }

    const int   kernelRadius = params.kernelRadius;
    const float zeta         = params.zeta;
    const float zeroCross    = params.zeroCrossing;
    const float sinZC        = sin(zeroCross);

    // eta controls how quickly the polynomial weight drops at sector boundaries.
    // Derived from zeroCrossing so that the weight is exactly zero at ±zeroCross.
    const float eta = (zeta + cos(zeroCross)) / (sinZC * sinZC);

    // Per-sector accumulators.
    //   m[k].rgb = sum of (colour × weight),  m[k].w = sum of weights
    //   s[k]     = sum of (colour² × weight)  — used to compute variance
    float4 m[8];
    float3 s[8];
    for (int k = 0; k < 8; ++k) {
        m[k] = float4(0.0f);
        s[k] = float3(0.0f);
    }

    // ── Inner neighbourhood loop ──────────────────────────────────────────────
    for (int dy = -kernelRadius; dy <= kernelRadius; ++dy) {
        for (int dx = -kernelRadius; dx <= kernelRadius; ++dx) {

            // Normalised position within the kernel: maps [-kernelRadius,+kernelRadius] → [-1,+1].
            float2 v = float2(dx, dy) / float(kernelRadius);

            // Sample the source pixel, clamped to texture borders.
            int2 coord = clamp(int2(gid) + int2(dx, dy),
                               int2(0), int2(width - 1, height - 1));
            float3 c = saturate(inTexture.read(uint2(coord)).rgb);

            // ── Polynomial sector weights ─────────────────────────────────────
            // We evaluate 8 polynomial "bump" functions, one per sector.
            // Each bump peaks in one sector direction and falls to zero at the
            // sector boundaries defined by zeroCrossing.
            //
            // Sectors 0,2,4,6 are aligned to the cardinal axes (+y, -x, -y, +x).
            // Sectors 1,3,5,7 are the same set rotated 45°.
            //
            // For a vector v = (vx, vy) in the normalised kernel, the weight
            // for a sector centred on the +y axis is:
            //   z = max(0, vy + (zeta - eta * vx²))
            //   w = z²
            // (A cosine-like polynomial that is positive only in the +y half-plane
            //  and tapers to zero near the sector edges.)

            float w[8];
            float sumW = 0.0f;
            float z, vxx, vyy;

            // Axis-aligned sectors (0, 2, 4, 6)
            vxx = zeta - eta * v.x * v.x;
            vyy = zeta - eta * v.y * v.y;
            z = max(0.0f,  v.y + vxx); w[0] = z * z; sumW += w[0]; // +y sector
            z = max(0.0f, -v.x + vyy); w[2] = z * z; sumW += w[2]; // -x sector
            z = max(0.0f, -v.y + vxx); w[4] = z * z; sumW += w[4]; // -y sector
            z = max(0.0f,  v.x + vyy); w[6] = z * z; sumW += w[6]; // +x sector

            // Diagonal sectors (1, 3, 5, 7): same polynomials on a 45°-rotated v.
            // The rotation preserves magnitude so the Gaussian below is unaffected.
            float2 vr = (sqrt(2.0f) / 2.0f) * float2(v.x - v.y, v.x + v.y);
            vxx = zeta - eta * vr.x * vr.x;
            vyy = zeta - eta * vr.y * vr.y;
            z = max(0.0f,  vr.y + vxx); w[1] = z * z; sumW += w[1];
            z = max(0.0f, -vr.x + vyy); w[3] = z * z; sumW += w[3];
            z = max(0.0f, -vr.y + vxx); w[5] = z * z; sumW += w[5];
            z = max(0.0f,  vr.x + vyy); w[7] = z * z; sumW += w[7];

            if (sumW < 1e-6f) continue;

            // Gaussian roll-off: distant samples (large |v|) contribute less
            // regardless of which sector they land in. The constant 3.125 gives
            // a standard deviation of ~0.4 in normalised kernel space.
            float g = exp(-3.125f * dot(v, v)) / sumW;

            // Accumulate weighted colour and colour-squared into each sector.
            for (int k = 0; k < 8; ++k) {
                float wk = w[k] * g;
                m[k] += float4(c * wk, wk);
                s[k] += c * c * wk;
            }
        }
    }

    // ── Combine sectors ───────────────────────────────────────────────────────
    // Normalise each sector's weighted sum to get its mean colour and variance.
    // Sectors that captured a locally uniform region (low variance) get more
    // weight in the final blend. This is the core Kuwahara idea: pick the
    // locally most homogeneous neighbourhood.
    float4 output = float4(0.0f);
    for (int k = 0; k < params.N; ++k) {
        if (m[k].w < 1e-6f) continue;

        m[k].rgb /= m[k].w;
        float3 variance = abs(s[k] / m[k].w - m[k].rgb * m[k].rgb);
        float  sigma2   = variance.r + variance.g + variance.b;

        // Weight = 1 / (1 + (hardness × 1000 × σ²)^(q/2))
        // High variance → low weight; hardness and q control the sharpness
        // of this suppression.
        float wk = 1.0f / (1.0f + pow(params.hardness * 1000.0f * sigma2,
                                       0.5f * params.q));
        output += float4(m[k].rgb * wk, wk);
    }

    outTexture.write(saturate(output / output.w), gid);
}

// ─────────────────────────────────────────────────────────────────────────────
// 2× box-filter downsample
//
// Averages each 2×2 block of the source into a single output pixel. Running
// this before the Kuwahara pass reduces the pixel count to ¼, so a radius-9
// Kuwahara on the half-res image produces the same visual coverage as a
// radius-18 Kuwahara on the full-res image — but with ~15× less total compute
// (¼ the pixels × ¼ the samples per pixel at the smaller radius).
// ─────────────────────────────────────────────────────────────────────────────

kernel void downsample_2x(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 s = gid * 2;
    float4 c = src.read(s)
             + src.read(s + uint2(1, 0))
             + src.read(s + uint2(0, 1))
             + src.read(s + uint2(1, 1));
    dst.write(c * 0.25f, gid);
}
