import XCTest
@testable import VideoCoachCore

final class RollingRateTests: XCTestCase {
    func test_returnsNilWithFewerThanFiveSamples() {
        var r = RollingRate(windowSeconds: 30)
        // 4 samples spanning 4 seconds — count gate fails.
        for i in 0..<4 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i) * 1.5)
        }
        XCTAssertNil(r.compositionSecondsPerWallSecond())
    }

    func test_returnsNilBeforeTwoSecondsOfWallTimeElapsed() {
        var r = RollingRate(windowSeconds: 30)
        // 6 samples crammed into 1.0 seconds — sample-count gate passes
        // (≥5) but wall-time gate fails (<2s spread).
        for i in 0..<6 {
            r.record(wallTime: Double(i) * 0.2, encodedCompSeconds: Double(i) * 0.3)
        }
        XCTAssertNil(r.compositionSecondsPerWallSecond())
    }

    func test_returnsSteadyRateForEvenlySpacedSamples() {
        var r = RollingRate(windowSeconds: 30)
        // 10 samples, 1s apart, 1.5x rate (encoded grows 1.5 per wall sec).
        for i in 0..<10 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i) * 1.5)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 1.5, accuracy: 0.001)
    }

    func test_reflectsRateChangeAfterEvictionPastWindow() {
        var r = RollingRate(windowSeconds: 10)
        // 30 samples at 1s apart at 1.0x rate.
        for i in 0..<30 {
            r.record(wallTime: Double(i), encodedCompSeconds: Double(i))
        }
        // 30 more samples at 1s apart at 3.0x rate. After these, samples
        // older than (current wallTime - 10) should evict.
        for i in 30..<60 {
            let prevEncoded = 30.0 + Double(i - 30) * 3.0
            r.record(wallTime: Double(i), encodedCompSeconds: prevEncoded)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        // Surviving window only has 3.0x-rate samples.
        XCTAssertEqual(rate!, 3.0, accuracy: 0.05)
    }

    func test_returnsZeroWhenEncodedSecondsConstant() {
        var r = RollingRate(windowSeconds: 30)
        // 10 samples over 10 seconds wall time; encoded stuck at 1.0.
        for i in 0..<10 {
            r.record(wallTime: Double(i), encodedCompSeconds: 1.0)
        }
        let rate = r.compositionSecondsPerWallSecond()
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 0.0, accuracy: 0.001)
    }
}
