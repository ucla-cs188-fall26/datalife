import SwiftUI
import UIKit

extension TimeLimit {
    /// When on (and the daily time limit is on), the limit follows today's calendar-based allowance.
    static let useScheduleKey = "timeLimit.useSchedule"
}

/// Calendar and busy-time settings shown inline on the home screen (inside a List):
/// today's busy times, manual busy times, the allowance formula and what counts as busy.
/// Calendars aren't listed; the home screen uses the user's own calendars automatically.
struct BusyTimeSections: View {
    @EnvironmentObject private var busyTime: BusyTimeModel
    @Environment(\.openURL) private var openURL
    @State private var showAddPeriod = false

    var body: some View {
        todaySection
        manualSection
        allowanceSection
        rulesSection
    }

    private var todaySection: some View {
        Section {
            if let day = busyTime.today, !day.busyIntervals.isEmpty {
                ForEach(day.busyIntervals, id: \.self) { interval in
                    Text(Self.timeRange(interval.start, interval.end))
                }
            } else {
                Text("Nothing busy today")
                    .foregroundStyle(.secondary)
            }
            calendarAccessRows
        } header: {
            Text("Calendar & busy time")
        } footer: {
            Text(sourceDescription + " DataLife only reads when events start and end. Nothing leaves your phone.")
        }
    }

    private var usingCalendars: Bool {
        busyTime.settings.useCalendars && busyTime.access.canRead
            && !busyTime.settings.selectedCalendarIDs.isDisjoint(with: busyTime.availableCalendars.map(\.id))
    }

    private var sourceDescription: String {
        let source = usingCalendars
            ? "From your calendar and manual busy times"
            : "From your manual busy times only"
        guard let window = busyTime.today?.window else { return source + "." }
        return "\(source), between \(Self.timeRange(window.start, window.end))."
    }

    @ViewBuilder
    private var calendarAccessRows: some View {
        switch busyTime.access {
        case .fullAccess:
            EmptyView()
        case .notDetermined:
            Button("Allow Calendar Access") {
                Task { await busyTime.requestCalendarAccess() }
            }
        case .denied, .restricted, .writeOnly:
            Text(accessProblem)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
    }

    private var accessProblem: String {
        switch busyTime.access {
        case .writeOnly:
            return "DataLife can add events but not read them. Choose Full Access for Calendars in Settings."
        case .restricted:
            return "Calendar access is restricted on this device."
        default:
            return "Calendar access is off. Turn it on in Settings to count your events. Manual busy times still work."
        }
    }

    private var manualSection: some View {
        Section {
            ForEach(busyTime.settings.manualPeriods) { period in
                Text(Self.describe(period))
                    .foregroundStyle(Self.isPast(period) ? .secondary : .primary)
            }
            .onDelete { offsets in
                busyTime.settings.manualPeriods.remove(atOffsets: offsets)
            }
            Button("Add Busy Time") { showAddPeriod = true }
                .sheet(isPresented: $showAddPeriod) {
                    AddBusyPeriodView { period in
                        busyTime.settings.manualPeriods.append(period)
                    }
                }
        } header: {
            Text("Manual busy times")
        } footer: {
            Text("For classes, work or anything that isn't on your calendar. Swipe left to delete.")
        }
    }

    private var allowanceSection: some View {
        Section {
            Stepper("Free day: \(LimitReachedView.format(minutes: busyTime.settings.allowance.baseMinutes))",
                    value: $busyTime.settings.allowance.baseMinutes, in: 15...240, step: 5)
                .onChange(of: busyTime.settings.allowance.baseMinutes) { _, base in
                    if busyTime.settings.allowance.minMinutes > base {
                        busyTime.settings.allowance.minMinutes = base
                    }
                }
            Stepper("Minimum: \(LimitReachedView.format(minutes: busyTime.settings.allowance.minMinutes))",
                    value: $busyTime.settings.allowance.minMinutes,
                    in: 0...max(0, busyTime.settings.allowance.baseMinutes), step: 5)
            Stepper("Less per busy hour: \(Int(busyTime.settings.allowance.minutesReducedPerBusyHour)) min",
                    value: $busyTime.settings.allowance.minutesReducedPerBusyHour, in: 0...60, step: 5)
        } header: {
            Text("Daily allowance")
        } footer: {
            Text("Allowance = free-day amount − busy hours × less per busy hour, never below the minimum.")
        }
    }

    private var rulesSection: some View {
        Section {
            DatePicker("Day starts", selection: windowBinding(\.startMinute), displayedComponents: .hourAndMinute)
            DatePicker("Day ends", selection: windowBinding(\.endMinute), displayedComponents: .hourAndMinute)
            Toggle("Count tentative events", isOn: $busyTime.settings.rules.countTentative)
            Toggle("Count all-day events", isOn: Binding(
                get: { busyTime.settings.rules.allDayPolicy == .countAsBusy },
                set: { busyTime.settings.rules.allDayPolicy = $0 ? .countAsBusy : .ignore }
            ))
            Button("Reset to Defaults", role: .destructive) {
                busyTime.settings.allowance = .prototypeDefault
                busyTime.settings.planningWindow = .prototypeDefault
                busyTime.settings.rules = .prototypeDefault
            }
        } header: {
            Text("What counts as busy")
        } footer: {
            if busyTime.settings.planningWindow.isValid {
                Text("Only busy time between these hours counts. An all-day event counts as the whole day when turned on.")
            } else {
                Text("The end must be after the start. Until then the whole day counts.")
                    .foregroundStyle(.red)
            }
        }
    }

    /// Edits a planning-window minute through a time picker.
    private func windowBinding(_ keyPath: WritableKeyPath<PlanningWindow, Int>) -> Binding<Date> {
        Binding(
            get: { Self.clockTime(busyTime.settings.planningWindow[keyPath: keyPath]) },
            set: { busyTime.settings.planningWindow[keyPath: keyPath] = Self.minuteOfDay($0) }
        )
    }

    static func clockTime(_ minute: Int) -> Date {
        let cal = Calendar.current
        return DayClock.time(minute: minute, onDayStarting: cal.startOfDay(for: .now), calendar: cal)
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(start.formatted(time)) – \(end.formatted(time))"
    }

    static func describe(_ period: ManualBusyPeriod) -> String {
        switch period.kind {
        case let .weekly(weekday, startMinute, endMinute):
            let symbols = Calendar.current.weekdaySymbols
            let day = (1...7).contains(weekday) ? symbols[weekday - 1] : "?"
            return "Every \(day), \(timeRange(clockTime(startMinute), clockTime(endMinute)))"
        case let .once(start, end):
            let date = start.formatted(date: .abbreviated, time: .omitted)
            return "\(date), \(timeRange(start, end))"
        }
    }

    static func isPast(_ period: ManualBusyPeriod) -> Bool {
        if case let .once(_, end) = period.kind { return end < .now }
        return false
    }
}

/// Adds one manual busy time: weekly on a weekday, or once on a date.
struct AddBusyPeriodView: View {
    var onAdd: (ManualBusyPeriod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repeatsWeekly = true
    @State private var weekday = Calendar.current.component(.weekday, from: .now)
    @State private var day = Date.now
    @State private var start = BusyTimeSections.clockTime(9 * 60)
    @State private var end = BusyTimeSections.clockTime(10 * 60)

    private var startMinute: Int { BusyTimeSections.minuteOfDay(start) }
    private var endMinute: Int { BusyTimeSections.minuteOfDay(end) }
    private var isValid: Bool { endMinute > startMinute }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repeats", selection: $repeatsWeekly) {
                    Text("Every week").tag(true)
                    Text("One time").tag(false)
                }
                if repeatsWeekly {
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in
                            Text(Calendar.current.weekdaySymbols[d - 1]).tag(d)
                        }
                    }
                } else {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                }
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                if !isValid {
                    Text("The end time must be after the start time.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Busy Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(makePeriod())
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func makePeriod() -> ManualBusyPeriod {
        if repeatsWeekly {
            return ManualBusyPeriod(kind: .weekly(weekday: weekday, startMinute: startMinute, endMinute: endMinute))
        }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        return ManualBusyPeriod(kind: .once(
            start: DayClock.time(minute: startMinute, onDayStarting: dayStart, calendar: cal),
            end: DayClock.time(minute: endMinute, onDayStarting: dayStart, calendar: cal)
        ))
    }
}

#Preview {
    List { BusyTimeSections() }
        .environmentObject(BusyTimeModel())
}
