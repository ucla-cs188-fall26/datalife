import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Daily time limit (fixed number of minutes, no allowance algorithm yet).
/// The app starts Screen Time monitoring with a usage threshold; when the selected apps
/// reach the limit, iOS wakes the DataLifeMonitor extension, which turns the block on.
///
/// The extension has its own copy of these keys (see DataLifeMonitor/DeviceActivityMonitorExtension.swift).
/// Keep the two in sync.
enum TimeLimit {
    /// Shared storage between the app and the monitor extension.
    static let appGroup = "group.ucla.cs188.datalife"
    static var shared: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static let selectionKey = "blockedSelection"
    static let limitMinutesKey = "timeLimit.minutes"
    static let enabledKey = "timeLimit.enabled"
    static let reachedAtKey = "timeLimit.reachedAt"

    static let defaultMinutes = 30

    static let activity = DeviceActivityName("datalife.daily")
    static let limitEvent = DeviceActivityEvent.Name("datalife.limitReached")

    /// When today's limit was reached, or nil if it hasn't been reached today.
    static var reachedToday: Date? {
        guard let date = shared.object(forKey: reachedAtKey) as? Date,
              Calendar.current.isDateInToday(date) else { return nil }
        return date
    }

    /// Start (or restart) counting today's usage of the selected apps.
    static func startMonitoring(selection: FamilyActivitySelection, minutes: Int) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([activity])

        // Repeats every day from midnight to 11:59 PM, so the count resets each day.
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: minutes)
        )
        try center.startMonitoring(activity, during: schedule, events: [limitEvent: event])
    }

    static func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring([activity])
    }
}
