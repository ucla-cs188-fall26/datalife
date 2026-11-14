import Foundation
import Combine
import UIKit

/// Everything the user can set for busy time and the allowance. Stored on-device.
nonisolated struct BusyTimeSettings: Equatable, Codable, Sendable {
    /// Calendar integration is optional; when off (or not permitted), only manual periods count.
    var useCalendars: Bool = true
    /// `EKCalendar.calendarIdentifier`s the user chose. Empty means no calendar counts yet.
    var selectedCalendarIDs: Set<String> = []
    var planningWindow: PlanningWindow = .prototypeDefault
    var rules: BusyRules = .prototypeDefault
    var manualPeriods: [ManualBusyPeriod] = []
    var allowance: AllowancePolicy = .prototypeDefault
}

extension BusyTimeSettings {
    // Missing keys fall back to defaults, so adding a setting later doesn't wipe saved ones.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BusyTimeSettings()
        useCalendars = try c.decodeIfPresent(Bool.self, forKey: .useCalendars) ?? d.useCalendars
        selectedCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedCalendarIDs) ?? d.selectedCalendarIDs
        planningWindow = try c.decodeIfPresent(PlanningWindow.self, forKey: .planningWindow) ?? d.planningWindow
        rules = try c.decodeIfPresent(BusyRules.self, forKey: .rules) ?? d.rules
        manualPeriods = try c.decodeIfPresent([ManualBusyPeriod].self, forKey: .manualPeriods) ?? d.manualPeriods
        allowance = try c.decodeIfPresent(AllowancePolicy.self, forKey: .allowance) ?? d.allowance
    }
}

/// Today's result, saved where the restrictions code and the monitor extension can read it.
/// Contains numbers only, no event details.
nonisolated struct AllowanceRecord: Equatable, Codable, Sendable {
    var dayStart: Date
    var busyMinutes: Double
    var allowanceMinutes: Int
    var calculatedAt: Date
    /// False when calendars were off, not permitted, or none were selected (manual periods only).
    var usedCalendars: Bool
}

@MainActor
protocol BusyTimeSettingsStoring {
    func load() -> BusyTimeSettings
    func save(_ settings: BusyTimeSettings)
}

@MainActor
protocol AllowanceRecordStoring {
    func save(_ record: AllowanceRecord)
}

struct UserDefaultsBusyTimeSettingsStore: BusyTimeSettingsStoring {
    static let key = "busyTime.settings"
    var defaults: UserDefaults

    func load() -> BusyTimeSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(BusyTimeSettings.self, from: data)
        else { return BusyTimeSettings() }
        return settings
    }

    func save(_ settings: BusyTimeSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

struct UserDefaultsAllowanceRecordStore: AllowanceRecordStoring {
    /// Key in the App Group, readable by the monitor extension.
    static let key = "allowance.today"
    var defaults: UserDefaults

    func save(_ record: AllowanceRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func load() -> AllowanceRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AllowanceRecord.self, from: data)
    }
}

/// Keeps today's busy time and allowance up to date.
/// Recalculates when it starts, when the app comes to the foreground, when EventKit reports a
/// change, when the day changes, and when the time zone or clock changes, all while the app is
/// running. iOS doesn't let it run continuously in the background, so after the app has been
/// suspended the numbers catch up the next time it is opened.
/// It has no UI. Screens read its published values and call its methods.
@MainActor
final class BusyTimeModel: ObservableObject {
    @Published private(set) var access: CalendarAccess
    /// Calendars available to choose from (empty without access).
    @Published private(set) var availableCalendars: [CalendarInfo] = []
    @Published var settings: BusyTimeSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            recalculate()
        }
    }
    @Published private(set) var today: BusyDay? = nil
    @Published private(set) var allowanceMinutes: Int

    /// Called whenever today's allowance changes, including at a new day.
    /// The restrictions code hooks in here to restart monitoring with the new limit.
    var onAllowanceChange: ((Int) -> Void)?

    private let provider: CalendarEventProviding
    private let settingsStore: BusyTimeSettingsStoring
    private let recordStore: AllowanceRecordStoring?
    private let calendar: Calendar
    private let now: () -> Date
    private let observesSystemEvents: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var started = false

    init(
        provider: CalendarEventProviding,
        settingsStore: BusyTimeSettingsStoring,
        recordStore: AllowanceRecordStoring?,
        calendar: Calendar,
        now: @escaping () -> Date,
        observesSystemEvents: Bool
    ) {
        self.provider = provider
        self.settingsStore = settingsStore
        self.recordStore = recordStore
        self.calendar = calendar
        self.now = now
        self.observesSystemEvents = observesSystemEvents
        let settings = settingsStore.load()
        self.settings = settings
        self.access = provider.access
        self.allowanceMinutes = settings.allowance.baseMinutes
    }

    /// The live app setup: EventKit, settings in standard defaults, today's result in the App Group.
    convenience init() {
        self.init(
            provider: EventKitCalendarProvider(),
            settingsStore: UserDefaultsBusyTimeSettingsStore(defaults: .standard),
            recordStore: UserDefaultsAllowanceRecordStore(defaults: TimeLimit.shared),
            calendar: .autoupdatingCurrent,
            now: Date.init,
            observesSystemEvents: true
        )
    }

    /// Starts listening for changes and calculates today. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true

        provider.onChange = { [weak self] in self?.refresh() }

        if observesSystemEvents {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                UIApplication.willEnterForegroundNotification,
                .NSCalendarDayChanged,                       // midnight passed
                .NSSystemTimeZoneDidChange,                  // travel
                UIApplication.significantTimeChangeNotification, // clock or DST change
            ]
            for name in names {
                center.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.refresh() }
                    .store(in: &subscriptions)
            }
        }
        refresh()
    }

    /// Asks for calendar access. Call this from a screen that explains why, separately from
    /// the Screen Time request. Busy time works without it (manual periods only).
    @discardableResult
    func requestCalendarAccess() async -> CalendarAccess {
        _ = await provider.requestAccess()
        refresh()
        return access
    }

    /// Re-reads permission and calendars, then recalculates.
    func refresh() {
        access = provider.access
        availableCalendars = access.canRead ? provider.calendars() : []
        recalculate()
    }

    /// Selected calendars that no longer exist on the device (deleted, account removed, or the
    /// identifier changed after a sync). They are skipped; the selection is kept in case they return.
    var missingSelectedCalendarIDs: Set<String> {
        guard access.canRead else { return [] }
        return settings.selectedCalendarIDs.subtracting(availableCalendars.map(\.id))
    }

    func setCalendar(_ id: String, selected: Bool) {
        if selected {
            settings.selectedCalendarIDs.insert(id)
        } else {
            settings.selectedCalendarIDs.remove(id)
        }
    }

    private func recalculate() {
        let date = now()
        let liveIDs = settings.selectedCalendarIDs.intersection(availableCalendars.map(\.id))
        let usesCalendars = settings.useCalendars && access.canRead && !liveIDs.isEmpty

        let window = settings.planningWindow.interval(onDayContaining: date, calendar: calendar)
        let events = usesCalendars
            ? provider.events(from: window.start, to: window.end, calendarIDs: liveIDs)
            : []

        let day = BusyDayCalculator.compute(
            dayContaining: date,
            calendarEvents: events,
            manualPeriods: settings.manualPeriods,
            window: settings.planningWindow,
            rules: settings.rules,
            calendar: calendar
        )
        let allowance = settings.allowance.allowanceMinutes(busyMinutes: day.busyMinutes)

        let changed = allowance != allowanceMinutes || day.dayStart != today?.dayStart
        today = day
        allowanceMinutes = allowance
        recordStore?.save(AllowanceRecord(
            dayStart: day.dayStart,
            busyMinutes: day.busyMinutes,
            allowanceMinutes: allowance,
            calculatedAt: date,
            usedCalendars: usesCalendars
        ))
        if changed { onAllowanceChange?(allowance) }
    }
}
