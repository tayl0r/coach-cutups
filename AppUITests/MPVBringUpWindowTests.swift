import XCTest

final class MPVBringUpWindowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Launch arg lets the app know it's under test if needed later.
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Smoke test: app launches, main window appears.
    func testAppLaunches() throws {
        // The main window's existence proves the app got past launch.
        // Wait up to 5s for the SwiftUI scene to materialize.
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5),
                      "Main app window did not appear within 5s")
    }

    /// Bring-up window: open it via the Debug menu, capture a screenshot
    /// of the player surface area, save to /tmp for orchestrator to read.
    func testBringUpWindowOpensAndRendersPixels() throws {
        // Click Debug → Open MPV Bring-up Window via the menu bar.
        let debugMenu = app.menuBars.menuBarItems["Debug"]
        XCTAssertTrue(debugMenu.waitForExistence(timeout: 5),
                      "Debug menu did not appear in menu bar")
        debugMenu.click()

        let bringUpItem = app.menuItems["Open MPV Bring-up Window"]
        XCTAssertTrue(bringUpItem.waitForExistence(timeout: 2),
                      "'Open MPV Bring-up Window' menu item missing")
        bringUpItem.click()

        // Find the bring-up window. SwiftUI sets the window title from
        // WindowGroup("MPV Bring-up", id:). The accessibility identifier
        // is auto-generated as "mpv-debug-AppWindow-N", so match by title
        // via NSPredicate. Use firstMatch — clicking the menu item can
        // occasionally open more than one window, and we just need any.
        let predicate = NSPredicate(format: "title == %@", "MPV Bring-up")
        let bringUpWindow = app.windows.matching(predicate).firstMatch
        XCTAssertTrue(bringUpWindow.waitForExistence(timeout: 5),
                      "Bring-up window did not appear")

        // Wait long enough for mpv to load + decode + render the first
        // frames. SW renderer at 4K is slow; give it 5 seconds.
        Thread.sleep(forTimeInterval: 5.0)

        // Save a full-window screenshot to /tmp for the orchestrator.
        // (We screenshot the whole window rather than a specific element
        // because the player area is a Metal-backed NSView whose
        // accessibility-tree representation may not be reliable.)
        let png = bringUpWindow.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: "/tmp/xcui-mpv-bringup.png")
        try png.write(to: url)
        // Attach to xcresult too — useful when reviewing test failures.
        let attachment = XCTAttachment(image: bringUpWindow.screenshot().image)
        attachment.name = "mpv-bring-up-window"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
