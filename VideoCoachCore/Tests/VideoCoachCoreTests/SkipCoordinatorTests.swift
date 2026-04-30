import XCTest
@testable import VideoCoachCore

@MainActor
final class SkipCoordinatorTests: XCTestCase {
    func test_singleSkip_firesCoarseSeekAndArmsDebounce() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        let d = c.requestSkip(
            deltaSeconds: 3.0,
            currentPlayerTimeSeconds: 10.0,
            clipDurationSeconds: 60.0,
            nowMonotonicSeconds: 100.0
        )
        XCTAssertEqual(d.seek, SeekParams(targetSeconds: 13.0, exact: false))
        XCTAssertEqual(d.armDebounceSeconds, 0.15)
    }

    func test_secondSkipDuringFlight_accumulatesAndArmsOnly() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        let d2 = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                              clipDurationSeconds: 60, nowMonotonicSeconds: 100.05)
        XCTAssertNil(d2.seek)                          // no new seek issued
        XCTAssertEqual(d2.armDebounceSeconds, 0.15)    // debounce re-armed
    }

    func test_secondSkipDuringFlight_targetAccumulatesNotResetsToCurrent() {
        let c = SkipCoordinator()
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100.05)
        // Now in-flight seek lands; coordinator should refire to t=16, not t=13.
        let after = c.seekCompleted(nowMonotonicSeconds: 100.10)
        XCTAssertEqual(after.seek, SeekParams(targetSeconds: 16.0, exact: false))
    }

    func test_burstEnded_afterSeekLanded_firesExactSeek() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        _ = c.seekCompleted(nowMonotonicSeconds: 100.05) // coarse landed quickly
        let burst = c.burstEnded(nowMonotonicSeconds: 100.15)
        XCTAssertEqual(burst.seek, SeekParams(targetSeconds: 13.0, exact: true))
        XCTAssertNil(burst.armDebounceSeconds)
    }
}
