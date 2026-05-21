import XCTest
import CoreGraphics
@testable import VideoCoachCore

final class ScoreboardRenderTests: XCTestCase {
    /// Allocate a stable-lifetime CG context backed by an UnsafeMutableRawPointer
    /// the test owns and releases. The `&pixels` / `withUnsafeMutableBytes` shortcut
    /// creates a context whose backing pointer dangles past the closure — an
    /// explicit allocation is the only sound way to share a CGContext factory
    /// across a test method.
    private func makeContext(width: Int = 1280, height: Int = 720)
        -> (cg: CGContext, snapshot: () -> [UInt8], release: () -> Void)
    {
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let cg = CGContext(
            data: raw, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let snapshot: () -> [UInt8] = {
            let buf = UnsafeBufferPointer(
                start: raw.assumingMemoryBound(to: UInt8.self), count: byteCount)
            return Array(buf)
        }
        let release: () -> Void = { raw.deallocate() }
        return (cg, snapshot, release)
    }

    private func runningState() -> ScoreboardState {
        ScoreboardState(
            home: TeamConfig(name: "ARS",
                primaryColor: RGBA(r: 1, g: 0, b: 0, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
            away: TeamConfig(name: "BUR",
                primaryColor: RGBA(r: 0, g: 0, b: 1, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
            homeScore: 0, awayScore: 0,
            clock: .running(seconds: 7))
    }

    func test_smokeRender_drawsInsideBarRect_leavesOutsideUntouched() {
        let w = 1280, h = 720
        let (cg, snapshot, release) = makeContext(width: w, height: h)
        defer { release() }
        drawScoreboard(into: cg, size: CGSize(width: w, height: h), state: runningState())
        let bytes = snapshot()
        // Probe a point well inside the bar (top-left area).
        let insideOffset = (60 * w + 200) * 4
        let insideSum = Int(bytes[insideOffset]) + Int(bytes[insideOffset + 1]) + Int(bytes[insideOffset + 2])
        XCTAssertGreaterThan(insideSum, 10, "expected some non-background pixels inside bar rect")
        // Probe far outside the bar (bottom-right quadrant).
        let outsideOffset = ((h - 50) * w + (w - 50)) * 4
        let outsideSum = Int(bytes[outsideOffset]) + Int(bytes[outsideOffset + 1]) + Int(bytes[outsideOffset + 2])
        XCTAssertEqual(outsideSum, 0, "expected untouched (transparent black) pixels far outside bar")
    }

    /// Catches text-positioning regressions: the home block fills bright red
    /// and the team name renders in white on top. If text drew at the right
    /// vertical position, a horizontal row through the home block's center
    /// contains white pixels (high green channel). If text rendered
    /// elsewhere (off-bar / wrong Y / not at all), the row stays pure red.
    func test_homeTeamName_drawsOverHomeRect() {
        let w = 1280, h = 720
        let (cg, snapshot, release) = makeContext(width: w, height: h)
        defer { release() }
        drawScoreboard(into: cg, size: CGSize(width: w, height: h), state: runningState())
        let bytes = snapshot()
        // Geometry mirrors drawScoreboard.
        let barH = CGFloat(h) * 0.08
        let inset = CGFloat(h) * 0.015
        let accentH = barH * 0.08
        let scoreBarH = barH - accentH
        let scoreRowY = inset + accentH
        let probeY = Int(scoreRowY + scoreBarH / 2)
        let homeRectMaxX = Int(inset + CGFloat(w) * 0.36 * 0.30)
        // makeContext uses byteOrder32Little + premultipliedFirst → pixel
        // memory layout is [B, G, R, A]. Background red = (0,0,255,255);
        // white text = (255,255,255,255). Green channel discriminates.
        var maxGreen: UInt8 = 0
        for x in Int(inset) ..< homeRectMaxX {
            let g = bytes[(probeY * w + x) * 4 + 1]
            if g > maxGreen { maxGreen = g }
        }
        XCTAssertGreaterThan(maxGreen, 100, "expected white text pixels inside home rect at vertical center")
    }
}
