import Foundation

public struct MatchFormat: Codable, Hashable, Sendable {
    public var regulationPeriods: Int
    public var regulationPeriodSeconds: Int
    public var overtimePeriods: Int
    public var overtimePeriodSeconds: Int

    public init(
        regulationPeriods: Int = 2,
        regulationPeriodSeconds: Int = 45 * 60,
        overtimePeriods: Int = 0,
        overtimePeriodSeconds: Int = 15 * 60
    ) {
        self.regulationPeriods = regulationPeriods
        self.regulationPeriodSeconds = regulationPeriodSeconds
        self.overtimePeriods = overtimePeriods
        self.overtimePeriodSeconds = overtimePeriodSeconds
    }
}

public extension MatchFormat {
    var totalPeriods: Int { regulationPeriods + overtimePeriods }
    var expectedStartStopEvents: Int { 2 * totalPeriods }

    /// Convenience views over the raw `*Seconds` fields. Settings UI binds
    /// to minutes directly so Steppers don't need ad-hoc `Binding(get:set:)`
    /// minutes-to-seconds bridges.
    var regulationPeriodMinutes: Int {
        get { regulationPeriodSeconds / 60 }
        set { regulationPeriodSeconds = newValue * 60 }
    }

    var overtimePeriodMinutes: Int {
        get { overtimePeriodSeconds / 60 }
        set { overtimePeriodSeconds = newValue * 60 }
    }

    /// True when `periodIndex` falls in the overtime range.
    func isOvertime(periodIndex i: Int) -> Bool { i >= regulationPeriods }

    /// Length of one period at this index (regulation or overtime).
    func periodSeconds(_ i: Int) -> Double {
        Double(isOvertime(periodIndex: i) ? overtimePeriodSeconds : regulationPeriodSeconds)
    }

    /// User-facing label for a period index. "1H"/"2H" for the soccer
    /// special case (regulationPeriods == 2); otherwise "P1"/"P2"/…;
    /// overtime always "OT1"/"OT2"/….
    func periodName(_ i: Int) -> String {
        if isOvertime(periodIndex: i) {
            return "OT\(i - regulationPeriods + 1)"
        }
        if regulationPeriods == 2 {
            return i == 0 ? "1H" : "2H"
        }
        return "P\(i + 1)"
    }

    /// Label for the inter-period break that follows period `i`. Returns
    /// "HT" for soccer's halftime; "BREAK" for every other inter-period gap.
    func breakLabel(afterPeriodIndex i: Int) -> String {
        regulationPeriods == 2 && i == 0 ? "HT" : "BREAK"
    }
}
