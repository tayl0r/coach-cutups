import XCTest

/// End-to-end gate for the video-zoom pipeline: synthesizes a scroll-wheel
/// event over the bring-up window and asserts the visible pixels at a fixed
/// view-relative position changed. If this test passes, the gesture →
/// workspace → mpv pipeline is wired and actually moves real pixels.
final class MPVZoomPlaybackTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Stage the fixture at /tmp like the other tests do.
        let fixturePath = "/tmp/mpv-test-fixture.mp4"
        let fm = FileManager.default
        if !fm.fileExists(atPath: fixturePath) {
            let source = "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4"
            if fm.fileExists(atPath: source) {
                try fm.copyItem(atPath: source, toPath: fixturePath)
            } else {
                throw XCTSkip("Test fixture not available at \(source)")
            }
        }

        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--mpv-default-file=\(fixturePath)",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testScrollZoomsBringUpWindow() throws {
        let debugMenu = app.menuBars.menuBarItems["Debug"]
        XCTAssertTrue(debugMenu.waitForExistence(timeout: 5))
        debugMenu.click()
        let bringUpItem = app.menuItems["Open MPV Bring-up Window"]
        XCTAssertTrue(bringUpItem.waitForExistence(timeout: 2))
        bringUpItem.click()

        let predicate = NSPredicate(format: "title == %@", "MPV Bring-up")
        let bringUp = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5))

        // Bring window to front + let video render.
        app.activate()
        bringUp.click()
        Thread.sleep(forTimeInterval: 2.0)

        // Capture before-zoom screenshot.
        let before = bringUp.screenshot()

        // Synthesize 5 scroll-wheel notches over the bring-up window.
        // CGEvent scroll uses screen coordinates; compute window center.
        let windowFrame = bringUp.frame
        let centerX = windowFrame.midX
        let centerY = windowFrame.midY

        for _ in 0..<5 {
            // units: .line (not .pixel) so NSEvent.hasPreciseScrollingDeltas is
            // false → MPVPlayerView routes to the mouse-wheel zoom branch, not
            // the trackpad-pan branch (which gates on scale > 1.0 and would
            // no-op at identity).
            if let e = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,             // positive deltaY = zoom in
                wheel2: 0, wheel3: 0
            ) {
                e.location = CGPoint(x: centerX, y: centerY)
                e.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Capture after-zoom screenshot.
        app.activate()
        bringUp.click()
        Thread.sleep(forTimeInterval: 0.5)
        let after = bringUp.screenshot()

        // Optional: persist for debugging.
        try? before.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-zoom-before.tiff")
        )
        try? after.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-zoom-after.tiff")
        )

        // Sample a fixed view-relative position; before vs after pixels
        // should differ (zoom changed what's visible there).
        let beforePixel = samplePixel(before, atFraction: CGPoint(x: 0.1, y: 0.5))
        let afterPixel  = samplePixel(after,  atFraction: CGPoint(x: 0.1, y: 0.5))
        XCTAssertNotEqual(beforePixel, afterPixel,
                          "Scroll did not change visible pixels — zoom not wired end-to-end")
    }

    /// Sample a 1×1 pixel from the screenshot at view-relative position
    /// (each component 0...1). Returns BGRA bytes or empty on failure.
    private func samplePixel(_ s: XCUIScreenshot, atFraction p: CGPoint) -> [UInt8] {
        guard let cg = s.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = cg.width, h = cg.height
        let x = Int(Double(w) * p.x)
        let y = Int(Double(h) * p.y)
        guard w > 0, h > 0, x >= 0, x < w, y >= 0, y < h else { return [] }

        var buffer = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: -x, y: y - h + 1, width: w, height: h))
        return buffer
    }
}
