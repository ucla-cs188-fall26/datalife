import Foundation

/// The daily recreational allowance rule:
/// allowance = max(min_minutes, base_minutes - busy_hours * minutes_reduced_per_busy_hour)
/// capped at base_minutes and rounded to a whole minute.
/// The defaults are prototype values.
nonisolated struct AllowancePolicy: Equatable, Codable, Sendable {
    /// Allowance on a completely free day.
    var baseMinutes: Int = 120
    /// Allowance never goes below this, however busy the day.
    var minMinutes: Int = 30
    /// Minutes of allowance lost per busy hour.
    var minutesReducedPerBusyHour: Double = 15

    static let prototypeDefault = AllowancePolicy()

    /// Today's allowance for `busyMinutes` of busy time. Always between the minimum and the base;
    /// more busy time never gives a larger allowance. Bad inputs are handled safely: negative or
    /// NaN busy time counts as zero, a negative rate counts as zero, and a minimum above the base
    /// is lowered to the base.
    func allowanceMinutes(busyMinutes: Double) -> Int {
        let base = max(0, baseMinutes)
        let floor = min(max(0, minMinutes), base)
        let rate = minutesReducedPerBusyHour.isNaN ? 0 : max(0, minutesReducedPerBusyHour)
        let busy = busyMinutes.isNaN ? 0 : max(0, busyMinutes)
        guard rate > 0, busy > 0 else { return base }

        let raw = Double(base) - (busy / 60) * rate
        let clamped = min(Double(base), max(Double(floor), raw))
        return Int(clamped.rounded())
    }
}
