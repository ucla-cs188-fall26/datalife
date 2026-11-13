import SwiftUI
import EventKit
import Combine

/// Screen shown when today's screen time limit has been reached.
/// Shows what's left on today's calendar, how long the phone has been used today,
/// an emergency override (top left) and a close button (bottom).
struct LimitReachedView: View {
    /// The daily limit that was reached, in minutes.
    let limitMinutes: Int
    /// When the limit was reached. Usage keeps counting up from the limit after this.
    let limitReachedAt: Date
    /// Called after the user confirms an emergency override.
    var onEmergencyOverride: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var calendar = TodayCalendar()
    @State private var showBreathing = false
    @State private var overrideConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Emergency Override") {
                    showBreathing = true
                }
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.red)
                Spacer()
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.system(size: 72))
                    .foregroundColor(.orange)
                Text("You've reached your limit")
                    .font(.largeTitle)
                    .bold()
                    .multilineTextAlignment(.center)
                // Re-render every minute so the usage time stays current.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Used today: \(Self.format(minutes: usedMinutes(at: context.date)))")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 12) {
                Text("Upcoming Tasks")
                    .font(.title)
                    .bold()
                calendarSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .task { await calendar.load() }
        // Friction before overriding: finish a short breathing pause first.
        .fullScreenCover(isPresented: $showBreathing, onDismiss: {
            if overrideConfirmed {
                overrideConfirmed = false
                onEmergencyOverride()
                dismiss()
            }
        }) {
            BreathingView(continueTitle: "Unblock for \(ContentView.overrideMinutes) min") {
                overrideConfirmed = true
            }
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        switch calendar.state {
        case .loading:
            ProgressView()
        case .noAccess:
            Text("Calendar access is off. Turn it on in Settings › Privacy › Calendars.")
                .font(.title3)
                .foregroundColor(.secondary)
        case .loaded(let events) where events.isEmpty:
            Text("Nothing else on your calendar today.")
                .font(.title3)
                .foregroundColor(.secondary)
        case .loaded(let events):
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 14) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(event.color)
                                .frame(width: 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                Text(event.timeText)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func usedMinutes(at now: Date) -> Int {
        let extra = max(0, Int(now.timeIntervalSince(limitReachedAt) / 60))
        return limitMinutes + extra
    }

    static func format(seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m == 0 { return "\(s) sec" }
        return s == 0 ? "\(m) min" : "\(m) min \(s) sec"
    }

    static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }
}

/// Reads the rest of today's events from the calendars on the device (EventKit).
/// Nothing is stored; events are only read for display.
@MainActor
final class TodayCalendar: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let timeText: String
        let color: Color
    }

    enum State {
        case loading, noAccess, loaded([Item])
    }

    @Published var state: State = .loading
    private let store = EKEventStore()

    func load() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            state = .noAccess
            return
        }
        state = .loaded(fetchRestOfToday())
    }

    private func fetchRestOfToday() -> [Item] {
        let now = Date()
        let cal = Calendar.current
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)

        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let time = event.isAllDay
                    ? "All day"
                    : "\(event.startDate.formatted(timeFormat)) – \(event.endDate.formatted(timeFormat))"
                return Item(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    timeText: time,
                    color: Color(cgColor: event.calendar.cgColor)
                )
            }
    }
}

#Preview {
    LimitReachedView(limitMinutes: 120, limitReachedAt: .now)
}
