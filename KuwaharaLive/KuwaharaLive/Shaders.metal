#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────────────────────
// KUWAHARA SHADER GOES HERE
//
// Replace this identity kernel with the Kuwahara implementation from your
// Unity project. The kernel receives the camera frame as `inTexture` and
// should write the filtered result to `outTexture`.
//
// Suggested signature to keep (matches MetalRenderer.swift dispatch call):
//   kernel void kuwahara(texture2d<float, access::read>  inTexture  [[texture(0)]],
//                        texture2d<float, access::write> outTexture [[texture(1)]],
//                        uint2 gid [[thread_position_in_grid]])
// ─────────────────────────────────────────────────────────────────────────────

kernel void kuwahara(texture2d<float, access::read>  inTexture  [[texture(0)]],
                     texture2d<float, access::write> outTexture [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    // Identity passthrough — replace with Kuwahara filter body
    float4 color = inTexture.read(gid);
    outTexture.write(color, gid);
}
