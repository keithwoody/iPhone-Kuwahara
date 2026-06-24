import XCTest
import Metal
@testable import KuwaharaLive

final class TexturePoolTests: XCTestCase {
    var device: MTLDevice!
    var pool: TexturePool!

    override func setUpWithError() throws {
        guard let gpu = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        device = gpu
        pool = TexturePool(device: gpu)
    }

    func testTextureReuse() {
        let t1 = pool.texture(width: 960, height: 540, slot: 0)
        let t2 = pool.texture(width: 960, height: 540, slot: 0)
        XCTAssertNotNil(t1)
        XCTAssertTrue(t1 === t2, "Same (w,h,slot) must return the identical MTLTexture instance")
    }

    func testSlotIsolation() {
        let t0 = pool.texture(width: 960, height: 540, slot: 0)
        let t1 = pool.texture(width: 960, height: 540, slot: 1)
        XCTAssertNotNil(t0)
        XCTAssertNotNil(t1)
        XCTAssertFalse(t0 === t1, "Different slots must return different MTLTexture instances")
    }

    func testDimensionChange() {
        let before = pool.texture(width: 960, height: 540, slot: 0)
        let after  = pool.texture(width: 480, height: 270, slot: 0)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertFalse(before === after, "Different dimensions must return different MTLTexture instances")
        XCTAssertEqual(after?.width,  480)
        XCTAssertEqual(after?.height, 270)
    }

    func testAllocationBaseline() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 960, height: 540, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        measure {
            for _ in 0..<1000 {
                _ = device.makeTexture(descriptor: descriptor)
            }
        }
    }

    func testPoolLookupSpeed() {
        // Warm the cache first so we measure pure lookup cost.
        _ = pool.texture(width: 960, height: 540, slot: 0)
        measure {
            for _ in 0..<1000 {
                _ = pool.texture(width: 960, height: 540, slot: 0)
            }
        }
    }
}
