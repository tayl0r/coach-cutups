import XCTest
@testable import VideoCoachCore

@MainActor
final class SkipCoordinatorTests: XCTestCase {
    func test_singleSkip_firesExactSeekDirectly_noDebounce() {
        // Single press must NOT do coarse-then-refine: that pattern lands
        // visibly at a keyframe (e.g. +2s on an HEVC source whose GOP boundary
        // sits before a +3s target), then jumps again to the exact frame ~150ms
        // later, producing a perceived double-seek for one keypress.
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        let d = c.requestSkip(
            deltaSeconds: 3.0,
            currentPlayerTimeSeconds: 10.0,
            clipDurationSeconds: 60.0,
            nowMonotonicSeconds: 100.0
        )
        XCTAssertEqual(d.seek, SeekParams(targetSeconds: 13.0, exact: true))
        XCTAssertNil(d.armDebounceSeconds)
    }

    func test_singleSkip_seekCompletes_isNoOp() {
        // Follow-up to the test above: the exact-already-landed completion
        // must not trigger a settle (there's nothing left to settle to).
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        let after = c.seekCompleted(nowMonotonicSeconds: 100.05)
        XCTAssertNil(after.seek)
        XCTAssertNil(after.armDebounceSeconds)
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

    func test_burstEnded_afterCoarseRefireLanded_firesExactSettle() {
        // Real-world burst sequence:
        //   1. Press → exact at 13 (in flight).
        //   2. Press during flight → target = 16, debounce armed.
        //   3. Exact lands → coordinator switches to burst mode, fires coarse
        //      at 16 (the new target) with a refreshed debounce.
        //   4. Coarse at 16 lands.
        //   5. Debounce fires → exact settle at 16.
        let c = SkipCoordinator(burstWindowSeconds: 0.15)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100)
        _ = c.requestSkip(deltaSeconds: 3, currentPlayerTimeSeconds: 10,
                         clipDurationSeconds: 60, nowMonotonicSeconds: 100.02)
        let switched = c.seekCompleted(nowMonotonicSeconds: 100.05)
        XCTAssertEqual(switched.seek, SeekParams(targetSeconds: 16.0, exact: false))
        XCTAssertEqual(switched.armDebounceSeconds, 0.15)
        let coarseLanded = c.seekCompleted(nowMonotonicSeconds: 100.07)
        XCTAssertNil(coarseLanded.seek)
        let burst = c.burstEnded(nowMonotonicSeconds: 100.20)
        XCTAssertEqual(burst.seek, SeekParams(targetSeconds: 16.0, exact: true))
        XCTAssertNil(burst.armDebounceSeconds)
        let burst2 = c.burstEnded(nowMonotonicSeconds: 100.25)
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
