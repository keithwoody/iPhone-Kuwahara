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
 *
 * Performance note:
 *   The per-sample sector weights depend only on the kernel *offset* (dx, dy)
 *   and the radius — never on the pixel or its colour. So instead of recomputing
 *   the 8 polynomials + Gaussian for every one of the ~500k pixels each frame,
 *   they are precomputed once (whenever the radius changes) into `weights`, laid
 *   out as [(2r+1)² samples] × [8 sectors]. See MetalRenderer.ensureWeightBuffer.
 *   The inner loop then just reads a weight and accumulates — same output, far
 *   less ALU.
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
    constant float*                 weights    [[buffer(1)]],  // precomputed w[k]·gaussian, [(2r+1)²][8]
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

    const int kernelRadius = params.kernelRadius;
    const int side         = 2 * kernelRadius + 1;  // weight-table row stride

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

            // Sample the source pixel, clamped to texture borders.
            int2 coord = clamp(int2(gid) + int2(dx, dy),
                               int2(0), int2(width - 1, height - 1));
            float3 c = saturate(inTexture.read(uint2(coord)).rgb);

            // Look up this offset's 8 precomputed sector weights and accumulate.
            int base = ((dy + kernelRadius) * side + (dx + kernelRadius)) * 8;
            for (int k = 0; k < 8; ++k) {
                float wk = weights[base + k];
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
