import Foundation

// Busy-time engine: turns calendar events and manual busy periods into one number,
// the busy minutes for a day.
// Everything here is `nonisolated` because the app target defaults to MainActor isolation;
// these are plain values and pure functions that are safe to use from anywhere.


/// A span of time when the user is occupied. Only start and end are kept:
/// no titles, notes, attendees or locations.
nonisolated struct BusyInterval: Equatable, Hashable, Codable, Sendable {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Length in seconds (0 for an empty or backwards interval).
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// The part of this interval inside `window`, or nil if they don't overlap.
    func clipped(to window: BusyInterval) -> BusyInterval? {
        let s = max(start, window.start)
        let e = min(end, window.end)
        return e > s ? BusyInterval(start: s, end: e) : nil
    }
}

nonisolated enum BusyIntervals {
    /// Union of `intervals`, clipped to `window`: sorted, non-overlapping and non-empty.
    /// Overlapping or touching intervals are joined, so no time is counted twice.
    /// Backwards intervals (end before start) are dropped.
    static func merged(_ intervals: [BusyInterval], clippedTo window: BusyInterval) -> [BusyInterval] {
        let clipped = intervals
            .compactMap { $0.clipped(to: window) }
            .sorted { $0.start < $1.start }
        var result: [BusyInterval] = []
        for interval in clipped {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1].end = max(last.end, interval.end)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Total busy minutes inside `window`, counting overlaps once. Real elapsed time,
    /// so an event across a daylight-saving change counts the hours that actually passed.
    static func totalMinutes(_ intervals: [BusyInterval], within window: BusyInterval) -> Double {
        merged(intervals, clippedTo: window).reduce(0) { $0 + $1.duration } / 60
    }
}

/// The part of each day that counts toward busyness, as wall-clock minutes after local midnight.
/// Example: 8:00–22:00 is `PlanningWindow(startMinute: 480, endMinute: 1320)`.
/// The window does not cross midnight; `endMinute` may be 1440 (the next midnight).
nonisolated struct PlanningWindow: Equatable, Codable, Sendable {
    var startMinute: Int
    var endMinute: Int

    static let minutesPerDay = 24 * 60
    static let wholeDay = PlanningWindow(startMinute: 0, endMinute: minutesPerDay)
    /// Prototype default (8 AM to 10 PM).
    static let prototypeDefault = PlanningWindow(startMinute: 8 * 60, endMinute: 22 * 60)

    var isValid: Bool {
        0 <= startMinute && startMinute < endMinute && endMinute <= Self.minutesPerDay
    }

    /// The concrete window for the local day containing `date`, in `calendar`'s time zone.
    /// An invalid window falls back to the whole day rather than producing nothing.
    func interval(onDayContaining date: Date, calendar: Calendar) -> BusyInterval {
        let window = isValid ? self : .wholeDay
        let dayStart = calendar.startOfDay(for: date)
        return BusyInterval(
            start: DayClock.time(minute: window.startMinute, onDayStarting: dayStart, calendar: calendar),
            end: DayClock.time(minute: window.endMinute, onDayStarting: dayStart, calendar: calendar)
        )
    }
}

nonisolated enum DayClock {
    /// The wall-clock time `minute` minutes after midnight on the day that starts at `dayStart`,
    /// in `calendar`'s time zone. 1440 means the next midnight. On a daylight-saving day this is
    /// the wall-clock time, not midnight plus a fixed number of seconds. A wall time that doesn't
    /// exist (skipped by spring-forward) moves to the next valid time.
    static func time(minute: Int, onDayStarting dayStart: Date, calendar: Calendar) -> Date {
        if minute <= 0 { return dayStart }
        if minute >= PlanningWindow.minutesPerDay {
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(86_400)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart)
            ?? dayStart.addingTimeInterval(TimeInterval(minute * 60))
    }
}

/// The few facts about a calendar event that busy-time needs. Built from an EKEvent by
/// the EventKit adapter; titles and other details are never copied in.
nonisolated struct CalendarEventSnapshot: Equatable, Sendable {
    enum Availability: Equatable, Sendable { case busy, free, tentative, unavailable, notSupported }
    enum Status: Equatable, Sendable { case none, confirmed, tentative, canceled }

    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var availability: Availability = .notSupported
    var status: Status = .none
    /// The user declined this invitation.
    var userDeclined: Bool = false
}

/// Which events count as busy. Kept separate so the team can change a rule in one place.
nonisolated struct BusyRules: Equatable, Codable, Sendable {
    enum AllDayPolicy: String, Codable, Sendable {
        /// Prototype default: all-day events (holidays, "Study Day", birthdays) add no busy time.
        case ignore
        /// Count an all-day event as busy for the whole planning window.
        case countAsBusy
    }

    var allDayPolicy: AllDayPolicy = .ignore
    /// Whether tentative events ("maybe") count as busy.
    var countTentative: Bool = true

    static let prototypeDefault = BusyRules()

    func countsAsBusy(_ event: CalendarEventSnapshot) -> Bool {
        if event.status == .canceled || event.userDeclined { return false }
        if event.availability == .free { return false }
        if event.isAllDay && allDayPolicy == .ignore { return false }
        if !countTentative && (event.status == .tentative || event.availability == .tentative) { return false }
        return true
    }

    func busyIntervals(from events: [CalendarEventSnapshot]) -> [BusyInterval] {
        events.filter(countsAsBusy).map { BusyInterval(start: $0.start, end: $0.end) }
    }
}

/// Busy time the user enters by hand. Used alongside calendars, or alone when calendar
/// access is off or the user doesn't keep a calendar.
nonisolated struct ManualBusyPeriod: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
        /// A one-off period with exact start and end. May cross midnight.
        case once(start: Date, end: Date)
        /// Every week on `weekday` (1 = Sunday … 7 = Saturday, as in `Calendar`), between
        /// wall-clock minutes after midnight. Does not cross midnight; `endMinute` may be 1440.
        case weekly(weekday: Int, startMinute: Int, endMinute: Int)
    }

    var id: UUID = UUID()
    var kind: Kind

    /// The busy intervals this period adds on the day starting at `dayStart`
    /// (before clipping to the planning window).
    func intervals(onDayStarting dayStart: Date, calendar: Calendar) -> [BusyInterval] {
        switch kind {
        case let .once(start, end):
            return [BusyInterval(start: start, end: end)]
        case let .weekly(weekday, startMinute, endMinute):
            guard (1...7).contains(weekday),
                  calendar.component(.weekday, from: dayStart) == weekday,
                  PlanningWindow(startMinute: startMinute, endMinute: endMinute).isValid
            else { return [] }
            return [BusyInterval(
                start: DayClock.time(minute: startMinute, onDayStarting: dayStart, calendar: calendar),
                end: DayClock.time(minute: endMinute, onDayStarting: dayStart, calendar: calendar)
            )]
        }
    }
}

nonisolated struct BusyDay: Equatable, Sendable {
    /// Start of the local day this was computed for.
    var dayStart: Date
    /// The planning window on that day.
    var window: BusyInterval
    /// Merged, clipped busy intervals.
    var busyIntervals: [BusyInterval]
    var busyMinutes: Double
}

nonisolated enum BusyDayCalculator {
    /// Busy time for the local day containing `date`: the union of busy calendar events and
    /// manual periods, clipped to the planning window. Same inputs always give the same result.
    static func compute(
        dayContaining date: Date,
        calendarEvents: [CalendarEventSnapshot],
        manualPeriods: [ManualBusyPeriod],
        window: PlanningWindow,
        rules: BusyRules,
        calendar: Calendar
    ) -> BusyDay {
        let dayStart = calendar.startOfDay(for: date)
        let windowInterval = window.interval(onDayContaining: date, calendar: calendar)

        var intervals = rules.busyIntervals(from: calendarEvents.filter { !$0.isAllDay })
        // All-day events: their EventKit dates don't line up with the planning window in a
        // useful way, so an all-day event that counts is treated as the whole window.
        if rules.allDayPolicy == .countAsBusy {
            let allDayOverlapsToday = calendarEvents.contains { event in
                event.isAllDay && rules.countsAsBusy(event)
                    && event.start < windowInterval.end && event.end > windowInterval.start
            }
            if allDayOverlapsToday { intervals.append(windowInterval) }
        }
        intervals += manualPeriods.flatMap { $0.intervals(onDayStarting: dayStart, calendar: calendar) }

        let merged = BusyIntervals.merged(intervals, clippedTo: windowInterval)
        let minutes = merged.reduce(0) { $0 + $1.duration } / 60
        return BusyDay(dayStart: dayStart, window: windowInterval, busyIntervals: merged, busyMinutes: minutes)
    }
}
