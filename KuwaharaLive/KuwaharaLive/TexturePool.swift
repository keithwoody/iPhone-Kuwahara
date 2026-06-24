import Metal

/// Caches MTLTextures keyed on (width, height, slot) so the render loop never
/// calls makeTexture(descriptor:) on a hot path.
///
/// - Thread safety: not thread-safe; call only from the Metal command-encoding
///   thread (same queue that calls MetalPreviewView.draw).
/// - Invalidation: call invalidate() if the source resolution changes. The pool
///   lazily rebuilds its cache on the next lookup.
final class TexturePool {
    private let device: MTLDevice
    private var cache: [Key: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(width: Int, height: Int, slot: Int,
                 format: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let key = Key(width: width, height: height, slot: slot)
        if let existing = cache[key] { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)
        cache[key] = texture
        return texture
    }

    func invalidate() {
        cache.removeAll()
    }
}

private struct Key: Hashable {
    let width: Int
    let height: Int
    let slot: Int
}
