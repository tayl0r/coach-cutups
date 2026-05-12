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

final class ProjectRunTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_emptyItemsYieldEmptyProjection() {
        let p = projectRun(items: [], rate: 1.0, now: now)
        XCTAssertEqual(p.totalSecondsRemaining, 0)
        XCTAssertTrue(p.perItemRemaining.isEmpty)
        XCTAssertTrue(p.perItemDoneDate.isEmpty)
    }

    func test_allPendingQueueOrderMatchesProjectedDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(id: "a", displayName: "a.mp4", videoDurationSeconds: 10),
            VideoExportItem(id: "b", displayName: "b.mp4", videoDurationSeconds: 20),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 30),
        ]
        let p = projectRun(items: items, rate: 2.0, now: now)
        // Per-item wall time alone at rate 2.0× = duration / 2.
        XCTAssertEqual(p.perItemRemaining["a"]!, 5.0, accuracy: 0.001)
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        XCTAssertEqual(p.perItemRemaining["c"]!, 15.0, accuracy: 0.001)
        // Total = sum = 30.
        XCTAssertEqual(p.totalSecondsRemaining, 30.0, accuracy: 0.001)
        // Dates are cumulative — a finishes at +5, b at +15, c at +30.
        XCTAssertEqual(p.perItemDoneDate["a"]!, now.addingTimeInterval(5))
        XCTAssertEqual(p.perItemDoneDate["b"]!, now.addingTimeInterval(15))
        XCTAssertEqual(p.perItemDoneDate["c"]!, now.addingTimeInterval(30))
    }

    func test_oneActiveAndPendingHaveMonotonicDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(
                id: "a", displayName: "a.mp4",
                videoDurationSeconds: 10, status: .active(fractionCompleted: 0.5)
            ),
            VideoExportItem(id: "b", displayName: "b.mp4", videoDurationSeconds: 10),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 10),
        ]
        let p = projectRun(items: items, rate: 1.0, now: now)
        // Per-item wall time alone (NOT cumulative — see spec: "Sum of all
        // per-item remainings is `totalSecondsRemaining`").
        // active: (1-0.5)*10 / 1.0 = 5
        XCTAssertEqual(p.perItemRemaining["a"]!, 5.0, accuracy: 0.001)
        // b alone: 10 / 1.0 = 10
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        // c alone: 10 / 1.0 = 10
        XCTAssertEqual(p.perItemRemaining["c"]!, 10.0, accuracy: 0.001)
        // Total wall = 5 + 10 + 10 = 25
        XCTAssertEqual(p.totalSecondsRemaining, 25.0, accuracy: 0.001)
        // Dates are cumulative (a@+5, b@+15, c@+25) so they're monotonic.
        XCTAssertEqual(p.perItemDoneDate["a"]!, now.addingTimeInterval(5))
        XCTAssertEqual(p.perItemDoneDate["b"]!, now.addingTimeInterval(15))
        XCTAssertEqual(p.perItemDoneDate["c"]!, now.addingTimeInterval(25))
        XCTAssertLessThan(p.perItemDoneDate["a"]!, p.perItemDoneDate["b"]!)
        XCTAssertLessThan(p.perItemDoneDate["b"]!, p.perItemDoneDate["c"]!)
    }

    func test_doneItemsExcludedFromBothRemainingAndDoneDates() {
        let items: [VideoExportItem] = [
            VideoExportItem(
                id: "a", displayName: "a.mp4",
                videoDurationSeconds: 10,
                status: .done(encodeWallSeconds: 7, averageFps: 30)
            ),
            VideoExportItem(
                id: "b", displayName: "b.mp4",
                videoDurationSeconds: 10,
                status: .active(fractionCompleted: 0)
            ),
            VideoExportItem(id: "c", displayName: "c.mp4", videoDurationSeconds: 10),
        ]
        let p = projectRun(items: items, rate: 1.0, now: now)
        XCTAssertNil(p.perItemRemaining["a"])
        XCTAssertNil(p.perItemDoneDate["a"])
        // b active from 0 → (1-0)*10/1 = 10 alone
        XCTAssertEqual(p.perItemRemaining["b"]!, 10.0, accuracy: 0.001)
        // c pending alone = 10
        XCTAssertEqual(p.perItemRemaining["c"]!, 10.0, accuracy: 0.001)
        XCTAssertEqual(p.totalSecondsRemaining, 20.0, accuracy: 0.001)
    }

    func test_rateZeroOrNegativeFallsBackToOne() {
        let items = [VideoExportItem(id: "a", displayName: "a.mp4", videoDurationSeconds: 10)]
        // rate of 0 would divide-by-zero; the function must guard.
        let pZero = projectRun(items: items, rate: 0, now: now)
        XCTAssertEqual(pZero.perItemRemaining["a"]!, 10.0, accuracy: 0.001)
        let pNeg = projectRun(items: items, rate: -5, now: now)
        XCTAssertEqual(pNeg.perItemRemaining["a"]!, 10.0, accuracy: 0.001)
    }
}
