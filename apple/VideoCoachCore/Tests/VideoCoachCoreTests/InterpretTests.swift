import XCTest
@testable import VideoCoachCore

final class InterpretTests: XCTestCase {
    private func startStop(_ s: Double) -> AbsoluteMatchEvent {
        AbsoluteMatchEvent(absSeconds: s, kind: .startStop)
    }
    func test_empty_input() {
        XCTAssertEqual(interpret([], format: MatchFormat()), [])
    }
    func test_one_event_soccer() {
        let result = interpret([startStop(10)], format: MatchFormat())
        XCTAssertEqual(result, [InterpretedEvent(absSeconds: 10, role: .start(periodIndex: 0), originalIndex: 0)])
    }
    func test_alternating_soccer() {
        let events = [10, 100, 200, 300].map { startStop(Double($0)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result, [
            .init(absSeconds: 10,  role: .start(periodIndex: 0), originalIndex: 0),
            .init(absSeconds: 100, role: .end(periodIndex: 0),   originalIndex: 1),
            .init(absSeconds: 200, role: .start(periodIndex: 1), originalIndex: 2),
            .init(absSeconds: 300, role: .end(periodIndex: 1),   originalIndex: 3),
        ])
    }
    func test_out_of_order_input_sorts_by_abs_time() {
        let events = [300, 10, 200, 100].map { startStop(Double($0)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.map { $0.absSeconds }, [10, 100, 200, 300])
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0),
            .start(periodIndex: 1), .end(periodIndex: 1),
        ])
        // originalIndex reports input-array position, NOT sorted position —
        // callers use it to map a role back to the originating record.
        XCTAssertEqual(result.map { $0.originalIndex }, [1, 3, 2, 0])
    }
    func test_over_cap_events_dropped() {
        let events = (1...5).map { startStop(Double($0 * 10)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.last?.absSeconds, 40)
    }
    func test_format_with_overtime() {
        let format = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                                 overtimePeriods: 1, overtimePeriodSeconds: 15*60)
        let events = (1...6).map { startStop(Double($0 * 100)) }
        let result = interpret(events, format: format)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0),
            .start(periodIndex: 1), .end(periodIndex: 1),
            .start(periodIndex: 2), .end(periodIndex: 2),
        ])
        XCTAssertTrue(format.isOvertime(periodIndex: 2))
    }
    func test_singlePeriod_format() {
        let format = MatchFormat(regulationPeriods: 1, regulationPeriodSeconds: 60*60)
        let events = [startStop(10), startStop(100)]
        let result = interpret(events, format: format)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, .start(periodIndex: 0))
        XCTAssertEqual(result[1].role, .end(periodIndex: 0))
    }
    func test_identical_timestamps_stable_order() {
        let events = [startStop(50), startStop(50), startStop(100)]
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.map { $0.absSeconds }, [50, 50, 100])
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0), .start(periodIndex: 1),
        ])
    }
}
