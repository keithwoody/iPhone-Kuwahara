import Metal
import MetalKit
import CoreVideo
import CoreMedia

// Must stay byte-for-byte in sync with the KuwaharaParams struct in Shaders.metal.
struct KuwaharaParams {
    var kernelRadius: Int32  = 5
    var N: Int32             = 8
    var q: Float             = 8.0
    var hardness: Float      = 8.0
    var zeroCrossing: Float  = 0.58
    var zeta: Float          = 0
    var enabled: UInt32      = 1
}

final class MetalPreviewView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var computePipeline: MTLComputePipelineState?
    private var downsamplePipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var pool: TexturePool?
    // Precomputed per-offset Kuwahara sector weights; rebuilt only when radius changes.
    private var weightBuffer: MTLBuffer?
    private var weightBufferRadius: Int = -1
    private var currentPixelBuffer: CVPixelBuffer?
    private var lastHalfSize: (Int, Int) = (0, 0)

    // Streaming: IOSurface-backed buffer so the GPU can blit into it directly
    // and the completion handler can hand it to SRTStreamer without a CPU copy.
    private var streamingPixelBuffer: CVPixelBuffer?
    private var streamingCVTexture: CVMetalTexture?  // keeps the cache entry alive
    private var streamingTexture: MTLTexture?

    var kuwaharaEnabled: Bool = true
    var kernelRadius: Int     = 9
    var sharpness: Float      = 8.0
    var hardness: Float       = 8.0
    var passes: Int           = 1

    var onProcessedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var currentPresentationTime: CMTime = .zero
    // Set once; cleared after the next frame is captured and handed to the callback.
    var onCaptureFrame: ((CVPixelBuffer) -> Void)?

    // Optional perf sink; when set, every frame reports GPU time + counts.
    weak var perfMonitor: PerfMonitor?

    override init(frame: CGRect, device: MTLDevice?) {
        let gpu = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: gpu)
        setup()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        setup()
    }

    private func setup() {
        guard let gpu = self.device else { return }

        commandQueue = gpu.makeCommandQueue()
        pool = TexturePool(device: gpu)
        CVMetalTextureCacheCreate(nil, nil, gpu, nil, &textureCache)

        guard let library = gpu.makeDefaultLibrary() else { return }

        if let fn = library.makeFunction(name: "kuwahara") {
            computePipeline = try? gpu.makeComputePipelineState(function: fn)
        }
        if let fn = library.makeFunction(name: "downsample_2x") {
            downsamplePipeline = try? gpu.makeComputePipelineState(function: fn)
        }

        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = false
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    func render(pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let targetSize = CGSize(width: w / 2, height: h / 2)
        if drawableSize != targetSize { drawableSize = targetSize }
        currentPixelBuffer = pixelBuffer
        draw()
    }

    /// Builds the per-offset sector-weight table the Kuwahara kernel reads.
    /// The weights depend only on the radius (and fixed shape constants), so we
    /// rebuild only when the radius changes — never per frame. This mirrors the
    /// polynomial + Gaussian math that used to run per-pixel in the shader.
    private func ensureWeightBuffer(radius: Int) {
        guard radius > 0, radius != weightBufferRadius, let gpu = device else { return }

        let side  = 2 * radius + 1
        let count = side * side
        var weights = [Float](repeating: 0, count: count * 8)

        let zeta: Float      = 2.0 / Float(radius)
        let zeroCross: Float = 0.58
        let sinZC = sin(zeroCross)
        let eta   = (zeta + cos(zeroCross)) / (sinZC * sinZC)
        let s2    = Float(2.0).squareRoot() / 2.0

        func sq(_ x: Float) -> Float { let z = max(0, x); return z * z }

        var idx = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let vx = Float(dx) / Float(radius)
                let vy = Float(dy) / Float(radius)

                // Axis-aligned sectors (0, 2, 4, 6).
                var vxx = zeta - eta * vx * vx
                var vyy = zeta - eta * vy * vy
                var w = [Float](repeating: 0, count: 8)
                w[0] = sq( vy + vxx)
                w[2] = sq(-vx + vyy)
                w[4] = sq(-vy + vxx)
                w[6] = sq( vx + vyy)

                // Diagonal sectors (1, 3, 5, 7): same polynomials on a 45°-rotated v.
                let rx = s2 * (vx - vy)
                let ry = s2 * (vx + vy)
                vxx = zeta - eta * rx * rx
                vyy = zeta - eta * ry * ry
                w[1] = sq( ry + vxx)
                w[3] = sq(-rx + vyy)
                w[5] = sq(-ry + vxx)
                w[7] = sq( rx + vyy)

                let sumW = w.reduce(0, +)
                if sumW >= 1e-6 {
                    let g = exp(-3.125 * (vx * vx + vy * vy)) / sumW
                    for k in 0..<8 { weights[idx * 8 + k] = w[k] * g }
                }
                idx += 1
            }
        }

        weightBuffer = gpu.makeBuffer(bytes: weights,
                                      length: weights.count * MemoryLayout<Float>.stride,
                                      options: .storageModeShared)
        weightBufferRadius = radius
    }

    // Builds (or rebuilds) the IOSurface-backed streaming buffer + wrapped MTLTexture.
    private func ensureStreamingBuffer(width: Int, height: Int) {
        guard streamingPixelBuffer == nil ||
              CVPixelBufferGetWidth(streamingPixelBuffer!) != width ||
              CVPixelBufferGetHeight(streamingPixelBuffer!) != height
        else { return }

        streamingPixelBuffer = nil
        streamingCVTexture   = nil
        streamingTexture     = nil

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb, let cache = textureCache else { return }

        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTex)
        guard let cvTex else { return }

        streamingPixelBuffer = pb
        streamingCVTexture   = cvTex
        streamingTexture     = CVMetalTextureGetTexture(cvTex)
    }

    override func draw(_ rect: CGRect) {
        guard
            let pixelBuffer   = currentPixelBuffer,
            let cache         = textureCache,
            let pipeline      = computePipeline,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let drawable      = currentDrawable
        else { return }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let halfW  = width  / 2
        let halfH  = height / 2

        // Invalidate cached textures on resolution change (rare).
        if (halfW, halfH) != lastHalfSize {
            pool?.invalidate()
            lastHalfSize = (halfW, halfH)
        }

        // Full-res input — zero-copy wrap of the CVPixelBuffer.
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTex = cvTexture,
              let inTexture = CVMetalTextureGetTexture(cvTex)
        else { return }

        // ── Pass 1: downsample full-res → half-res ────────────────────────────
        guard let halfTex = pool?.texture(width: halfW, height: halfH, slot: 0) else { return }

        if let dp = downsamplePipeline,
           let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(dp)
            enc.setTexture(inTexture, index: 0)
            enc.setTexture(halfTex,   index: 1)
            let tw = dp.threadExecutionWidth
            let th = dp.maxTotalThreadsPerThreadgroup / tw
            enc.dispatchThreadgroups(
                MTLSize(width: (halfW + tw - 1) / tw, height: (halfH + th - 1) / th, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
        }

        // ── Pass 2+: Kuwahara ping-pong at half-res ───────────────────────────
        guard let pingTex = pool?.texture(width: halfW, height: halfH, slot: 1),
              let pongTex = pool?.texture(width: halfW, height: halfH, slot: 2)
        else { return }

        let r = kernelRadius
        ensureWeightBuffer(radius: r)
        var params = KuwaharaParams(
            kernelRadius: Int32(r),
            N:            8,
            q:            sharpness,
            hardness:     hardness,
            zeroCrossing: 0.58,
            zeta:         2.0 / Float(r),
            enabled:      kuwaharaEnabled ? 1 : 0
        )

        let pingPong: [MTLTexture] = [pingTex, pongTex]
        var inputTex: MTLTexture = halfTex
        let tw = pipeline.threadExecutionWidth
        let th = pipeline.maxTotalThreadsPerThreadgroup / tw
        let threadgroups     = MTLSize(width: (halfW + tw - 1) / tw, height: (halfH + th - 1) / th, depth: 1)
        let threadsPerGroup  = MTLSize(width: tw, height: th, depth: 1)

        for i in 0..<max(1, passes) {
            let outputTex = pingPong[i % 2]
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline)
                enc.setTexture(inputTex,  index: 0)
                enc.setTexture(outputTex, index: 1)
                enc.setBytes(&params, length: MemoryLayout<KuwaharaParams>.stride, index: 0)
                enc.setBuffer(weightBuffer, offset: 0, index: 1)
                enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                enc.endEncoding()
            }
            inputTex = outputTex
        }

        // ── Streaming + capture: blit final pass → IOSurface-backed buffer ──────
        // Always outputs landscape 16:9. In portrait mode, center-crop a 16:9
        // slice from the taller half-res buffer instead of sending the full frame.
        let needsSharedBuffer = onProcessedFrame != nil || onCaptureFrame != nil
        if needsSharedBuffer {
            let isPortrait = halfH > halfW
            let streamW = halfW
            let streamH = isPortrait ? (((halfW * 9 + 15) / 16) / 2) * 2 : halfH
            let streamYOffset = isPortrait ? (halfH - streamH) / 2 : 0

            ensureStreamingBuffer(width: streamW, height: streamH)
            if let streamTex = streamingTexture,
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: inputTex,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: .init(x: 0, y: streamYOffset, z: 0),
                          sourceSize:   .init(width: streamW, height: streamH, depth: 1),
                          to: streamTex,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }

            if let pb = streamingPixelBuffer {
                let streamCallback  = onProcessedFrame
                let captureCallback = onCaptureFrame
                let pts = currentPresentationTime
                if captureCallback != nil { onCaptureFrame = nil }
                commandBuffer.addCompletedHandler { _ in
                    streamCallback?(pb, pts)
                    captureCallback?(pb)
                }
            }
        }

        // ── Display: blit final pass → drawable ───────────────────────────────
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: inputTex,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: .init(x: 0, y: 0, z: 0),
                      sourceSize:   .init(width: halfW, height: halfH, depth: 1),
                      to: drawable.texture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        // ── Perf sampling: GPU time + achieved frame rate, every frame ────────
        // gpuStartTime/gpuEndTime are only valid once the buffer completes, so
        // read them inside the completion handler (runs on a background thread).
        if let monitor = perfMonitor {
            let streamed = onProcessedFrame != nil
            commandBuffer.addCompletedHandler { cb in
                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                monitor.recordFrame(gpuMs: gpuMs, streamed: streamed)
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        CVMetalTextureCacheFlush(cache, 0)
    }
}
