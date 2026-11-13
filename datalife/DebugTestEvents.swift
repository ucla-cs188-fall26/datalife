#if DEBUG
import EventKit

/// Debug-only helper: adds sample calendar events so the limit screen can be tested.
/// Runs only when the app is launched with the `-seedTestEvents` argument, e.g.
///   xcrun simctl launch booted com.owenjohnsonpersonalteam.datalife -seedTestEvents
/// Re-running replaces the previous test events instead of duplicating them.
enum DebugTestEvents {
    private static let marker = "datalife-test-event"

    static func seedIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedTestEvents") else { return }
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true,
              let calendar = store.defaultCalendarForNewEvents else {
            print("[DebugTestEvents] No calendar access; nothing added.")
            return
        }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let rangeEnd = cal.date(byAdding: .day, value: 3, to: startOfToday)!

        // Remove earlier test events.
        let old = store.events(matching: store.predicateForEvents(withStart: startOfToday.addingTimeInterval(-86400), end: rangeEnd, calendars: nil))
            .filter { $0.notes == marker }
        for event in old { try? store.remove(event, span: .thisEvent, commit: false) }

        // (title, start offset from now in minutes, length in minutes)
        let samples: [(String, Double, Double)] = [
            ("CS 188 Project Meeting", 30, 60),
            ("Finish Problem Set 4", 120, 90),
            ("Read Chapter 7 for Lecture", 240, 45),
            ("Already Finished Event (should NOT show)", -180, 60),
            ("Tomorrow's Midterm (should NOT show)", 26 * 60, 120),
        ]
        for (title, offset, length) in samples {
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = now.addingTimeInterval(offset * 60)
            event.endDate = event.startDate.addingTimeInterval(length * 60)
            event.notes = marker
            event.calendar = calendar
            try? store.save(event, span: .thisEvent, commit: false)
        }

        let allDay = EKEvent(eventStore: store)
        allDay.title = "Study Day"
        allDay.isAllDay = true
        allDay.startDate = startOfToday
        allDay.endDate = startOfToday
        allDay.notes = marker
        allDay.calendar = calendar
        try? store.save(allDay, span: .thisEvent, commit: false)

        do {
            try store.commit()
            print("[DebugTestEvents] Added \(samples.count + 1) test events.")
        } catch {
            print("[DebugTestEvents] Failed: \(error)")
        }
    }
}
#endif
