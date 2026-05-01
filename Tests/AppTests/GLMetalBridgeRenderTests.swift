import XCTest
import Metal
import OpenGL.GL3

final class GLMetalBridgeRenderTests: XCTestCase {
    func test_clear_to_red_shows_red_in_metal_texture_bytes() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let bridge = try GLMetalBridge(device: device)
        try bridge.resize(to: CGSize(width: 64, height: 64))
        bridge.clearTo(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        glFlush()  // ensure GL writes are visible to Metal via IOSurface

        // Read the Metal texture back via getBytes (storageMode .shared makes this safe).
        let tex = bridge.metalTexture!
        var pixel = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&pixel, bytesPerRow: tex.width * 4,
                     from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // BGRA8Unorm: [B, G, R, A]. Red = (0, 0, 255, 255).
        XCTAssertEqual(pixel[0], 0)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], 255)
        XCTAssertEqual(pixel[3], 255)
    }
}
