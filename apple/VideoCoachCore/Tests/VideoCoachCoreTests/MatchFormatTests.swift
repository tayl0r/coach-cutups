import XCTest
@testable import VideoCoachCore

final class MatchFormatTests: XCTestCase {
    func test_defaults_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.regulationPeriods, 2)
        XCTAssertEqual(f.regulationPeriodSeconds, 45 * 60)
        XCTAssertEqual(f.overtimePeriods, 0)
        XCTAssertEqual(f.totalPeriods, 2)
        XCTAssertEqual(f.expectedStartStopEvents, 4)
    }

    func test_soccer_periodSeconds() {
        let f = MatchFormat()
        XCTAssertEqual(f.periodSeconds(0), 2700)
        XCTAssertEqual(f.periodSeconds(1), 2700)
    }

    func test_quarters_basketball() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12 * 60)
        XCTAssertEqual(f.totalPeriods, 4)
        XCTAssertEqual(f.expectedStartStopEvents, 8)
        XCTAssertEqual(f.periodSeconds(2), 720)
    }

    func test_with_overtime() {
        let f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                            overtimePeriods: 1, overtimePeriodSeconds: 15*60)
        XCTAssertEqual(f.totalPeriods, 3)
        XCTAssertEqual(f.expectedStartStopEvents, 6)
        XCTAssertFalse(f.isOvertime(periodIndex: 0))
        XCTAssertFalse(f.isOvertime(periodIndex: 1))
        XCTAssertTrue(f.isOvertime(periodIndex: 2))
        XCTAssertEqual(f.periodSeconds(2), 900)
    }

    func test_periodName_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.periodName(0), "1H")
        XCTAssertEqual(f.periodName(1), "2H")
    }

    func test_periodName_quarters() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
        XCTAssertEqual(f.periodName(0), "P1")
        XCTAssertEqual(f.periodName(3), "P4")
    }

    func test_periodName_singlePeriod() {
        let f = MatchFormat(regulationPeriods: 1, regulationPeriodSeconds: 60*60)
        XCTAssertEqual(f.periodName(0), "P1")
    }

    func test_periodName_overtime() {
        let f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                            overtimePeriods: 2, overtimePeriodSeconds: 15*60)
        XCTAssertEqual(f.periodName(2), "OT1")
        XCTAssertEqual(f.periodName(3), "OT2")
    }

    func test_breakLabel_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 0), "HT")
    }

    func test_breakLabel_quarters() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 0), "BREAK")
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 1), "BREAK")
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 2), "BREAK")
    }

    func test_regulationPeriodMinutes_getterAndSetter() {
        var f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45 * 60)
        XCTAssertEqual(f.regulationPeriodMinutes, 45)
        f.regulationPeriodMinutes = 30
        XCTAssertEqual(f.regulationPeriodSeconds, 30 * 60)
        // Getter reflects the updated seconds.
        XCTAssertEqual(f.regulationPeriodMinutes, 30)
    }

    func test_overtimePeriodMinutes_getterAndSetter() {
        var f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45 * 60,
                            overtimePeriods: 2, overtimePeriodSeconds: 15 * 60)
        XCTAssertEqual(f.overtimePeriodMinutes, 15)
        f.overtimePeriodMinutes = 10
        XCTAssertEqual(f.overtimePeriodSeconds, 10 * 60)
        XCTAssertEqual(f.overtimePeriodMinutes, 10)
    }

}
