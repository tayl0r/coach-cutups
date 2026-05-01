import XCTest
import Metal

final class GLMetalBridgeTests: XCTestCase {
    func test_bridge_creates_iosurface_at_requested_size() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let bridge = try GLMetalBridge(device: device)
        try bridge.resize(to: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(bridge.surfaceWidth, 1920)
        XCTAssertEqual(bridge.surfaceHeight, 1080)
        XCTAssertNotNil(bridge.metalTexture)
        XCTAssertEqual(bridge.metalTexture?.width, 1920)
    }
}
