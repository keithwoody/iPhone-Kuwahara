import Metal
import MetalKit
import CoreVideo

final class MetalPreviewView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var computePipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var currentPixelBuffer: CVPixelBuffer?
    private let renderQueue = DispatchQueue(label: "metal.render", qos: .userInteractive)

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

        guard
            let library = gpu.makeDefaultLibrary(),
            let fn = library.makeFunction(name: "kuwahara")
        else { return }

        computePipeline = try? gpu.makeComputePipelineState(function: fn)

        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = false
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    func render(pixelBuffer: CVPixelBuffer) {
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

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard
            let cvTex = cvTexture,
            let inTexture = CVMetalTextureGetTexture(cvTex)
        else { return }

        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let outTexture = device?.makeTexture(descriptor: outDescriptor) else { return }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(inTexture, index: 0)
            encoder.setTexture(outTexture, index: 1)

            let w = pipeline.threadExecutionWidth
            let h = pipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(
                width: (width + w - 1) / w,
                height: (height + h - 1) / h,
                depth: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: outTexture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: drawable.texture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
