import Foundation
import EventKit
import Combine

/// Calendar permission, simplified. Only `.fullAccess` can read events;
/// write-only access is not enough.
nonisolated enum CalendarAccess: Equatable, Sendable {
    case notDetermined, fullAccess, writeOnly, denied, restricted

    var canRead: Bool { self == .fullAccess }
}

/// A calendar the user can choose to count toward busyness.
/// The title is for display while choosing; only `id` is stored.
nonisolated struct CalendarInfo: Identifiable, Equatable, Sendable {
    /// `EKCalendar.calendarIdentifier`.
    var id: String
    var title: String
    /// The account it comes from, e.g. "iCloud" or a Google account added in iOS Settings.
    var accountTitle: String
}

/// What busy-time needs from the calendar system. EventKit in the app; a fake in tests.
@MainActor
protocol CalendarEventProviding: AnyObject {
    var access: CalendarAccess { get }
    /// Asks for full calendar access if it hasn't been decided yet. Returns the result.
    func requestAccess() async -> CalendarAccess
    /// Calendars that can hold events. Empty without access.
    func calendars() -> [CalendarInfo]
    /// Events overlapping `start..<end` in the given calendars only.
    /// An empty set returns no events (never "all calendars").
    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [CalendarEventSnapshot]
    /// Called on the main actor when the calendar database changes.
    var onChange: (() -> Void)? { get set }
}

/// Reads the calendars on the device through EventKit. This includes accounts the user has added
/// to iOS (iCloud, Google, Exchange…); DataLife never talks to those services directly.
/// Only start/end, all-day, availability, status and the user's own RSVP are read.
@MainActor
final class EventKitCalendarProvider: CalendarEventProviding {
    private let store = EKEventStore()
    private var changeSubscription: AnyCancellable?

    var onChange: (() -> Void)?

    init() {
        // EventKit posts this (from any thread, often several times in a row) when events or
        // calendars change, including changes synced from other devices.
        changeSubscription = NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: store)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.onChange?() }
    }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        if access == .notDetermined || access == .writeOnly {
            _ = try? await store.requestFullAccessToEvents()
        }
        return access
    }

    func calendars() -> [CalendarInfo] {
        guard access.canRead else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, accountTitle: $0.source?.title ?? "") }
            .sorted { ($0.accountTitle, $0.title) < ($1.accountTitle, $1.title) }
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [CalendarEventSnapshot] {
        guard access.canRead, end > start, !calendarIDs.isEmpty else { return [] }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // Passing nil to the predicate would mean every calendar, so stop here instead.
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate).compactMap(Self.snapshot(of:))
    }

    private static func snapshot(of event: EKEvent) -> CalendarEventSnapshot? {
        guard let start = event.startDate, let end = event.endDate else { return nil }

        let availability: CalendarEventSnapshot.Availability
        switch event.availability {
        case .busy: availability = .busy
        case .free: availability = .free
        case .tentative: availability = .tentative
        case .unavailable: availability = .unavailable
        default: availability = .notSupported
        }

        let status: CalendarEventSnapshot.Status
        switch event.status {
        case .confirmed: status = .confirmed
        case .tentative: status = .tentative
        case .canceled: status = .canceled
        default: status = .none
        }

        // Only the user's own response is checked; attendee details are not kept.
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false

        return CalendarEventSnapshot(
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            availability: availability,
            status: status,
            userDeclined: declined
        )
    }
}
