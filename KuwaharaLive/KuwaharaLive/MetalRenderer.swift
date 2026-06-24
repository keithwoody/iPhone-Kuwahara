import Metal
import MetalKit
import CoreVideo
import CoreMedia

// Must stay byte-for-byte in sync with the KuwaharaParams struct in Shaders.metal.
struct KuwaharaParams {
    var kernelRadius: Int32  = 5       // half-width of sampling window in half-res pixels
    var N: Int32             = 8       // always 8 sectors
    var q: Float             = 8.0    // sharpness of variance suppression
    var hardness: Float      = 8.0    // scale in variance weighting denominator
    var zeroCrossing: Float  = 0.58   // sector-boundary angle (radians)
    var zeta: Float          = 0      // computed as 2/kernelRadius in draw()
    var enabled: UInt32      = 1
}

final class MetalPreviewView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var computePipeline: MTLComputePipelineState?
    private var downsamplePipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var currentPixelBuffer: CVPixelBuffer?

    // Tunable from ContentView via CameraPreview.updateUIView
    var kuwaharaEnabled: Bool = true
    var kernelRadius: Int     = 9     // radius in half-res pixels (≈ 2× in full-res units)
    var sharpness: Float      = 8.0
    var hardness: Float       = 8.0
    var passes: Int           = 1     // 1–4 Kuwahara passes; more = stronger painterly effect

    // Streaming support: set by SRTStreamer, called from Metal completion handler
    var onProcessedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var currentPresentationTime: CMTime = .zero

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
        // Pin the drawable to half the camera buffer size so CAMetalLayer
        // handles upscaling to fill the screen automatically.
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let targetSize = CGSize(width: w / 2, height: h / 2)
        if drawableSize != targetSize { drawableSize = targetSize }

        currentPixelBuffer = pixelBuffer
        draw()
    }

    override func draw(_ rect: CGRect) {
        guard
            let pixelBuffer = currentPixelBuffer,
            let cache = textureCache,
            let pipeline = computePipeline,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let drawable = currentDrawable
        else { return }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let halfW  = width  / 2
        let halfH  = height / 2

        // Wrap the CVPixelBuffer as a full-res Metal texture (zero-copy).
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard
            let cvTex = cvTexture,
            let inTexture = CVMetalTextureGetTexture(cvTex)
        else { return }

        // ── Pass 1: downsample full-res → half-res ────────────────────────────
        let halfDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: halfW, height: halfH, mipmapped: false)
        halfDesc.usage = [.shaderRead, .shaderWrite]
        guard let halfTex = device?.makeTexture(descriptor: halfDesc) else { return }

        if let dp = downsamplePipeline,
           let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(dp)
            enc.setTexture(inTexture, index: 0)
            enc.setTexture(halfTex,  index: 1)
            let tw = dp.threadExecutionWidth
            let th = dp.maxTotalThreadsPerThreadgroup / tw
            enc.dispatchThreadgroups(
                MTLSize(width: (halfW + tw - 1) / tw, height: (halfH + th - 1) / th, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
        }

        // ── Pass 2+: Kuwahara on the half-res texture (multi-pass ping-pong) ───
        let pingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: halfW, height: halfH, mipmapped: false)
        pingDesc.usage = [.shaderRead, .shaderWrite]
        guard let pingTex = device?.makeTexture(descriptor: pingDesc),
              let pongTex = device?.makeTexture(descriptor: pingDesc) else { return }

        let r = kernelRadius
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
        let threadgroups = MTLSize(width: (halfW + tw - 1) / tw, height: (halfH + th - 1) / th, depth: 1)
        let threadsPerGroup = MTLSize(width: tw, height: th, depth: 1)

        for i in 0..<max(1, passes) {
            let outputTex = pingPong[i % 2]
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline)
                enc.setTexture(inputTex,  index: 0)
                enc.setTexture(outputTex, index: 1)
                enc.setBytes(&params, length: MemoryLayout<KuwaharaParams>.stride, index: 0)
                enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                enc.endEncoding()
            }
            inputTex = outputTex
        }

        // ── Register streaming completion handler (must be before commit) ─────
        // pingTex/pongTex are new allocations each frame, so inputTex is unique
        // to this command buffer — safe to read in the completion handler.
        if let callback = onProcessedFrame {
            let capturedTex = inputTex
            let pts = currentPresentationTime
            let capW = halfW, capH = halfH
            commandBuffer.addCompletedHandler { _ in
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, capW, capH,
                                   kCVPixelFormatType_32BGRA, nil, &pb)
                guard let pb else { return }
                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    capturedTex.getBytes(base,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                        from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                                       size: MTLSize(width: capW, height: capH, depth: 1)),
                                        mipmapLevel: 0)
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                callback(pb, pts)
            }
        }

        // ── Blit final pass result → half-res drawable ────────────────────────
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: inputTex,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: halfW, height: halfH, depth: 1),
                      to: drawable.texture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
