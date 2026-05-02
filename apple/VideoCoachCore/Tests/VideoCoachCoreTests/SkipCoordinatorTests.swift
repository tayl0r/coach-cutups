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
        let burst2 = c.burstEnded(nowMonotonicSeconds: 100.20)
        XCTAssertNil(burst2.seek)
        XCTAssertNil(burst2.armDebounceSeconds)
    }

    func test_burstEndedDuringFlight_thenSeekCompletes_firesExactSeek() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        let mid = c.burstEnded(nowMonotonicSeconds: 100.15) // coarse seek still flying
        XCTAssertNil(mid.seek)
        let done = c.seekCompleted(nowMonotonicSeconds: 100.30)
        XCTAssertEqual(done.seek, SeekParams(targetSeconds: 13.0, exact: true))
    }

    func test_skipBeforeZero_clampsToZero() {
        let c = SkipCoordinator()
        let d = c.requestSkip(deltaSeconds: -10, currentPlayerTimeSeconds: 3,
                             clipDurationSeconds: 60, nowMonotonicSeconds: 0)
        XCTAssertEqual(d.seek?.targetSeconds, 0)
    }

    func test_skipPastDuration_clampsToDuration() {
        let c = SkipCoordinator()
        let d = c.requestSkip(deltaSeconds: 100, currentPlayerTimeSeconds: 50,
                             clipDurationSeconds: 60, nowMonotonicSeconds: 0)
        XCTAssertEqual(d.seek?.targetSeconds, 60)
    }

    func test_reset_clearsAllStateAndAllowsFreshSeek() {
        let c = SkipCoordinator()
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 0)
        c.reset()
        let after = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 20,
                                 clipDurationSeconds: 60, nowMonotonicSeconds: 0)
        XCTAssertEqual(after.seek?.targetSeconds, 23) // base = current (20), not stale 13
    }

    func test_skipDuringExactPending_cancelsPendingExactAndContinuesBurst() {
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        let mid = c.burstEnded(nowMonotonicSeconds: 100.15) // sets exactPending = true
        XCTAssertNil(mid.seek)
        let third = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                                 clipDurationSeconds: 60, nowMonotonicSeconds: 100.16)
        XCTAssertNil(third.seek) // accumulating onto target; no new seek issued
        XCTAssertEqual(third.armDebounceSeconds, 0.15)
        // First coarse seek (to 13) lands. Coordinator should refire COARSE (not
        // exact) to the new accumulated target 16, proving exactPending was cleared.
        let done = c.seekCompleted(nowMonotonicSeconds: 100.20)
        XCTAssertEqual(done.seek, SeekParams(targetSeconds: 16.0, exact: false))
    }

    func test_seekCompletedAfterReset_isSafeNoOp() {
        let c = SkipCoordinator()
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 0)
        c.reset()
        let late = c.seekCompleted(nowMonotonicSeconds: 0.10)
        XCTAssertNil(late.seek)
        XCTAssertNil(late.armDebounceSeconds)
    }
}
