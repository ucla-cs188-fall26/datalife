import SwiftUI
import FamilyControls
import ManagedSettings
import DeviceActivity

struct ContentView: View {
    @State private var selection = ContentView.loadSelection()
    @State private var isPickerPresented = false
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var statusMessage = ""
    @State private var showLimitScreen = false
    @State private var showBreathing = false
    @State private var showBreathingSettings = false
    @State private var limitReachedAt: Date? = TimeLimit.reachedToday
    @State private var shownLimitFor: Date?

    // Daily time limit: a fixed number of minutes for now (no allowance algorithm yet).
    @AppStorage(TimeLimit.enabledKey, store: TimeLimit.shared) private var timeLimitOn = false
    @AppStorage(TimeLimit.limitMinutesKey, store: TimeLimit.shared) private var limitMinutes = TimeLimit.defaultMinutes
    // When on, the daily limit follows today's schedule-based allowance instead of the stepper.
    @AppStorage(TimeLimit.useScheduleKey, store: TimeLimit.shared) private var useSchedule = false

    @EnvironmentObject private var busyTime: BusyTimeModel

    @State private var overrideUntil: Date? = UserDefaults.standard.object(forKey: ContentView.overrideKey) as? Date

    @Environment(\.scenePhase) private var scenePhase

    private let store = ManagedSettingsStore()
    private static let selectionKey = "blockedSelection"
    private static let overrideKey = "overrideUntil"
    /// How long an emergency override lifts the block (prototype default).
    static let overrideMinutes = 5
    /// Placeholder daily limit for the limit screen until the allowance formula is built.
    static let demoLimitMinutes = 120

    /// True when the block should be on right now.
    private var shouldBlockNow: Bool {
        !timeLimitOn || limitReachedAt != nil
    }

    private var hasSelection: Bool {
        !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
    }

    /// Shown until Screen Time is approved and calendar access has been asked for (e.g. first launch).
    private var needsPermissions: Bool {
        authStatus != .approved || busyTime.access == .notDetermined
    }

    var body: some View {
        Group {
            if needsPermissions {
                permissionsScreen
            } else {
                home
            }
        }
        .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)
        .onChange(of: selection) { _, newSelection in
            ContentView.saveSelection(newSelection)
            updateBlocking()
        }
        .onChange(of: timeLimitOn) { _, isOn in
            if !isOn { TimeLimit.stopMonitoring() }
            applyScheduleLimit()
            updateBlocking()
        }
        .onChange(of: useSchedule) { _, _ in applyScheduleLimit() }
        .onChange(of: busyTime.allowanceMinutes) { _, _ in applyScheduleLimit() }
        .onChange(of: limitMinutes) { _, _ in
            updateBlocking()
        }
        .onChange(of: busyTime.availableCalendars) { _, _ in useOwnCalendars() }
        .onAppear {
            useOwnCalendars()
            applyScheduleLimit()
            checkLimitReached()
        }
        .onReceive(AuthorizationCenter.shared.$authorizationStatus) { status in
            authStatus = status
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                authStatus = AuthorizationCenter.shared.authorizationStatus
                checkLimitReached()
                endOverrideIfExpired()
            }
        }
        .fullScreenCover(isPresented: $showLimitScreen) {
            LimitReachedView(
                limitMinutes: timeLimitOn ? limitMinutes : ContentView.demoLimitMinutes,
                limitReachedAt: limitReachedAt ?? .now,
                onEmergencyOverride: startOverride
            )
        }
        .fullScreenCover(isPresented: $showBreathing) {
            BreathingView()
        }
        .sheet(isPresented: $showBreathingSettings) {
            BreathingSettingsView()
        }
    }

    // MARK: Permissions (first launch)

    private var permissionsScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Welcome to DataLife")
                .font(.largeTitle)
                .bold()
                .multilineTextAlignment(.center)
            Text("DataLife needs two permissions to set your daily limit and block apps.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            permissionRow(
                icon: "hourglass",
                title: "Screen Time",
                detail: "Lets DataLife block the apps you choose.",
                granted: authStatus == .approved,
                action: requestScreenTime
            )
            permissionRow(
                icon: "calendar",
                title: "Calendar",
                detail: "Sets your limit from how busy your day is. Only event times are read.",
                granted: busyTime.access != .notDetermined,
                action: { Task { await busyTime.requestCalendarAccess() } }
            )

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func permissionRow(icon: String, title: String, detail: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func requestScreenTime() {
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                statusMessage = ""
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            authStatus = AuthorizationCenter.shared.authorizationStatus
        }
    }

    // MARK: Home

    private var home: some View {
        List {
            Section { summary }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            blockingSection

            BusyTimeSections()

            dailyLimitSection

            Section {
                if let overrideUntil, overrideUntil > .now {
                    Text("Override active until \(overrideUntil.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                // Preview of the screen shown when the daily limit is reached.
                Button("Show Limit Reached Screen") { showLimitScreen = true }
                Button("Take a Breather") { showBreathing = true }
                Button("Breathing Timer Settings") { showBreathingSettings = true }
            }

            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Today's limit and busy time: the biggest numbers on the screen.
    private var summary: some View {
        HStack(spacing: 12) {
            summaryTile(
                title: "Today's limit",
                value: LimitReachedView.format(minutes: timeLimitOn ? limitMinutes : busyTime.allowanceMinutes),
                caption: timeLimitOn
                    ? (useSchedule ? "From your schedule" : "Set manually")
                    : "Allowance · limit off"
            )
            summaryTile(
                title: "Busy today",
                value: LimitReachedView.format(minutes: Int((busyTime.today?.busyMinutes ?? 0).rounded())),
                caption: "Calendar + manual"
            )
        }
        .padding(.vertical, 8)
    }

    private func summaryTile(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var blockingSection: some View {
        Section {
            Button {
                isPickerPresented = true
            } label: {
                Label(hasSelection ? "Change Blocked Apps" : "Select Apps to Block", systemImage: "apps.iphone")
            }

            if !hasSelection {
                Text("No app selected")
                    .foregroundStyle(.secondary)
            } else if !shouldBlockNow {
                Text("Selected apps will be blocked after \(limitMinutes) min of use today")
                    .foregroundStyle(.orange)
                    .fontWeight(.bold)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeLimitOn ? "Daily limit reached: apps blocked" : "Shield active on selected app(s)")
                        .foregroundStyle(.red)
                        .fontWeight(.bold)
                    // Read back what iOS actually saved, as proof the block was applied.
                    Text(savedShieldSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if hasSelection {
                Button("Unblock", role: .destructive) {
                    selection = FamilyActivitySelection()
                    clearShield()
                }
            }
        } header: {
            Text("Blocked apps")
        }
    }

    private var dailyLimitSection: some View {
        Section {
            Toggle("Block only after a daily time limit", isOn: $timeLimitOn)
            if timeLimitOn {
                Toggle("Set limit from my schedule", isOn: $useSchedule)
                if !useSchedule {
                    Stepper("Daily limit: \(limitMinutes) min", value: $limitMinutes, in: 1...240)
                }
                if let limitReachedAt {
                    Text("Limit reached at \(limitReachedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                #if DEBUG
                // Test helper: does exactly what the monitor extension does when the limit is hit,
                // so the flow can be shown where usage tracking doesn't run (the Simulator).
                Button("Simulate Reaching Limit (test)") {
                    markLimitReached()
                }
                .font(.footnote)
                .disabled(!hasSelection)
                #endif
            }
        } header: {
            Text("Daily limit")
        }
    }

    /// Counts the user's own calendars automatically (skips Birthdays, holidays and other
    /// subscriptions), so there's nothing to choose.
    private func useOwnCalendars() {
        guard busyTime.access.canRead else { return }
        let ids = Set(busyTime.availableCalendars.filter(\.isPersonal).map(\.id))
        if !busyTime.settings.useCalendars { busyTime.settings.useCalendars = true }
        if busyTime.settings.selectedCalendarIDs != ids { busyTime.settings.selectedCalendarIDs = ids }
    }

    private var savedShieldSummary: String {
        let apps = store.shield.applications?.count ?? 0
        let categories = store.shield.applicationCategories == nil ? 0 : selection.categoryTokens.count
        let sites = store.shield.webDomains?.count ?? 0
        return "Saved in Screen Time: \(apps) apps, \(categories) categories, \(sites) websites"
    }

    private func applyShield(_ newSelection: FamilyActivitySelection) {
        store.shield.applications = newSelection.applicationTokens.isEmpty ? nil : newSelection.applicationTokens
        store.shield.applicationCategories = newSelection.categoryTokens.isEmpty ? nil : .specific(newSelection.categoryTokens)
        store.shield.webDomains = newSelection.webDomainTokens.isEmpty ? nil : newSelection.webDomainTokens
        store.shield.webDomainCategories = newSelection.categoryTokens.isEmpty ? nil : .specific(newSelection.categoryTokens)
    }

    /// Turns the block on now, or (with a time limit) starts counting usage instead.
    private func updateBlocking() {
        guard timeLimitOn else {
            applyShield(selection)
            return
        }
        if limitReachedAt == nil {
            clearShield()
        } else {
            applyShield(selection)
        }
        guard hasSelection else {
            TimeLimit.stopMonitoring()
            return
        }
        do {
            try TimeLimit.startMonitoring(selection: selection, minutes: limitMinutes)
            statusMessage = ""
        } catch {
            statusMessage = "Couldn't start the time limit: \(error.localizedDescription)"
        }
    }

    /// With "Set limit from my schedule" on, copies today's allowance into the daily limit.
    /// Changing `limitMinutes` triggers its onChange, which restarts monitoring via updateBlocking().
    private func applyScheduleLimit() {
        guard timeLimitOn, useSchedule else { return }
        let minutes = min(240, max(1, busyTime.allowanceMinutes))
        if limitMinutes != minutes { limitMinutes = minutes }
    }

    /// Picks up a limit that the monitor extension reached while the app was closed,
    /// and shows the limit screen once.
    private func checkLimitReached() {
        limitReachedAt = timeLimitOn ? TimeLimit.reachedToday : nil
        if let reached = limitReachedAt, shownLimitFor != reached {
            shownLimitFor = reached
            showLimitScreen = true
        }
    }

    #if DEBUG
    private func markLimitReached() {
        TimeLimit.shared.set(Date(), forKey: TimeLimit.reachedAtKey)
        applyShield(selection)
        checkLimitReached()
    }
    #endif

    private func clearShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }

    // Emergency override: lift the shield for a few minutes, then put it back.
    // The blocking itself (applyShield) is unchanged; this only pauses it.
    private func startOverride() {
        let until = Date.now.addingTimeInterval(TimeInterval(ContentView.overrideMinutes * 60))
        overrideUntil = until
        UserDefaults.standard.set(until, forKey: ContentView.overrideKey)
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        Task {
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            endOverrideIfExpired()
        }
    }

    // Note: this only runs while the app is open or when it's reopened. Re-blocking
    // while the app is closed needs a DeviceActivity monitor extension (later step).
    private func endOverrideIfExpired() {
        guard let until = overrideUntil, until <= .now else { return }
        overrideUntil = nil
        UserDefaults.standard.removeObject(forKey: ContentView.overrideKey)
        if shouldBlockNow { applyShield(selection) }
    }

    // Persist the picker selection so the UI matches the saved shield after a relaunch.
    private static func loadSelection() -> FamilyActivitySelection {
        // Stored in the shared App Group so the monitor extension can read it.
        guard let data = TimeLimit.shared.data(forKey: selectionKey)
                ?? UserDefaults.standard.data(forKey: selectionKey),
              let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return saved
    }

    private static func saveSelection(_ selection: FamilyActivitySelection) {
        if let data = try? JSONEncoder().encode(selection) {
            TimeLimit.shared.set(data, forKey: selectionKey)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BusyTimeModel())
}
