import XCTest

/// Load-bearing test for the Path B architectural pivot (c02b041): every
/// owned-player mount creates a brand-new mpv_handle, attaches a freshly-
/// allocated CAMetalLayer pre-init, and resumes playback. The bring-up
/// window's `MPVDebugRepresentable` is the cleanest from-scratch case —
/// closing the window destroys the player, reopening creates a new one.
///
/// This test verifies that a SECOND mount renders pixels just as the first
/// did. If only the first screenshot has video content, handle recreation
/// is broken — exactly the failure mode this test is designed to catch.
final class MPVMountRemountTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Mirror MPVBringUpWindowTests: stage the fixture at /tmp so we
        // dodge the TCC prompts that hit ~/Downloads on every cdhash change.
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

    func testRemountResumesPlayback() throws {
        // Open the bring-up window via the Debug menu.
        let debugMenu = app.menuBars.menuBarItems["Debug"]
        XCTAssertTrue(debugMenu.waitForExistence(timeout: 5),
                      "Debug menu did not appear in menu bar")
        debugMenu.click()

        let bringUpItem = app.menuItems["Open MPV Bring-up Window"]
        XCTAssertTrue(bringUpItem.waitForExistence(timeout: 2),
                      "'Open MPV Bring-up Window' menu item missing")
        bringUpItem.click()

        // Match by title — the SwiftUI Window scene's accessibility id is
        // auto-generated ("mpv-debug-AppWindow-N"), title is stable.
        let predicate = NSPredicate(format: "title == %@", "MPV Bring-up")
        let bringUp = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5),
                      "Bring-up window did not appear (first mount)")

        // gpu-next VO takes ~500ms to come up on first attach; give it 2s
        // so the screenshot reliably captures decoded frames.
        Thread.sleep(forTimeInterval: 2.0)
        let firstShot = bringUp.screenshot()
        try? firstShot.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-mount-remount-1.tiff")
        )
        let firstAttachment = XCTAttachment(image: firstShot.image)
        firstAttachment.name = "mount-1"
        firstAttachment.lifetime = .keepAlways
        add(firstAttachment)

        // Close the window. viewWillMove(toWindow: nil) in MPVRenderingNSView
        // → tearDown → detachLayer → owned MPVSourcePlayer is deallocated.
        bringUp.buttons[XCUIIdentifierCloseWindow].click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(bringUp.exists,
                       "Bring-up window did not close on close-button click")

        // Reopen — this is the load-bearing case: fresh NSView, fresh
        // MPVSourcePlayer (owned-player path), fresh mpv_handle, layer
        // attached pre-mpv_initialize.
        debugMenu.click()
        bringUpItem.click()
        XCTAssertTrue(bringUp.waitForExistence(timeout: 5),
                      "Bring-up window did not reappear (second mount)")

        // Force VideoCoach to the front + raise the bring-up window so the
        // screenshot grabs OUR pixels and not whatever app is occluding us.
        // Without this, bringUp.screenshot() returns the screen region the
        // window occupies — which can be obscured by another app post-reopen.
        app.activate()
        bringUp.click()
        Thread.sleep(forTimeInterval: 2.0)

        let secondShot = bringUp.screenshot()
        try? secondShot.image.tiffRepresentation?.write(
            to: URL(fileURLWithPath: "/tmp/xcui-mpv-mount-remount-2.tiff")
        )
        let secondAttachment = XCTAttachment(image: secondShot.image)
        secondAttachment.name = "mount-2"
        secondAttachment.lifetime = .keepAlways
        add(secondAttachment)

        XCTAssertTrue(hasNonBlackPixels(in: firstShot),
                      "First mount: no video pixels — bring-up window did not render")
        XCTAssertTrue(hasNonBlackPixels(in: secondShot),
                      "Remount: no video pixels — possible attachLayer / state-replay regression")
    }

    /// Sample N pixels from across the screenshot; return true if any pixel
    /// has a channel value > 16 (ITU-R black-frame threshold). Uses CGImage
    /// readback against an explicit RGBA bitmap context so we get
    /// deterministic byte order regardless of source colorspace.
    private func hasNonBlackPixels(in screenshot: XCUIScreenshot) -> Bool {
        guard let cg = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return false }

        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Sample on a grid — center 60% of the image, 5x5 grid = 25 pixels.
        let xs = stride(from: w / 5, through: 4 * w / 5, by: max(1, (3 * w / 5) / 4))
        let ys = stride(from: h / 5, through: 4 * h / 5, by: max(1, (3 * h / 5) / 4))
        for y in ys {
            for x in xs {
                let i = (y * w + x) * 4
                let r = buffer[i], g = buffer[i + 1], b = buffer[i + 2]
                if r > 16 || g > 16 || b > 16 {
                    return true
                }
            }
        }
        return false
    }
}
