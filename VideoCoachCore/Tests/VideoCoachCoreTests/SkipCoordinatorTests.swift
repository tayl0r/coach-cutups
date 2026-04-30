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
}
