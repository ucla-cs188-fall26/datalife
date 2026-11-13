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

    var body: some View {
        VStack(spacing: 24) {
            Text("App Blocker")
                .font(.largeTitle)
                .bold()

            // 1. Authorization
            if authStatus != .approved {
                Button("1. Grant Screen Time Permission") {
                    Task {
                        do {
                            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                            authStatus = AuthorizationCenter.shared.authorizationStatus
                            statusMessage = "Permission granted!"
                        } catch {
                            authStatus = AuthorizationCenter.shared.authorizationStatus
                            statusMessage = "Error: \(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("✓ Permission Granted")
                    .foregroundColor(.green)
            }

            // 2. Select & Block App
            Button("2. Select App to Block") {
                isPickerPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(authStatus != .approved)

            // 3. Shield Status
            if !hasSelection {
                Text("No app selected")
                    .foregroundColor(.secondary)
            } else if !shouldBlockNow {
                Text("Selected apps will be blocked after \(limitMinutes) min of use today")
                    .foregroundColor(.orange)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Button("Unblock") {
                    selection = FamilyActivitySelection()
                }
                .foregroundColor(.secondary)
            } else {
                Text(timeLimitOn ? "Daily limit reached: apps blocked" : "Shield active on selected app(s)")
                    .foregroundColor(.red)
                    .fontWeight(.bold)

                // Read back what iOS actually saved, as proof the block was applied.
                Text(savedShieldSummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button("Unblock") {
                    selection = FamilyActivitySelection()
                    store.shield.applications = nil
                    store.shield.applicationCategories = nil
                    store.shield.webDomains = nil
                    store.shield.webDomainCategories = nil
                }
                .foregroundColor(.secondary)
            }

            // 4. Daily time limit
            VStack(spacing: 8) {
                Toggle("Block only after a daily time limit", isOn: $timeLimitOn)
                if timeLimitOn {
                    Stepper("Daily limit: \(limitMinutes) min", value: $limitMinutes, in: 1...240)
                    if let limitReachedAt {
                        Text("Limit reached at \(limitReachedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundColor(.red)
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
            }
            .disabled(authStatus != .approved)

            if let overrideUntil, overrideUntil > .now {
                Text("Override active until \(overrideUntil.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            // Preview of the screen shown when the daily limit is reached.
            Button("Show Limit Reached Screen") {
                showLimitScreen = true
            }
            .buttonStyle(.bordered)

            Button("Take a Breather") {
                showBreathing = true
            }
            .buttonStyle(.bordered)

            Button("Breathing Timer Settings") {
                showBreathingSettings = true
            }
            .font(.footnote)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .padding()
        .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)
        .onChange(of: selection) { _, newSelection in
            ContentView.saveSelection(newSelection)
            updateBlocking()
        }
        .onChange(of: timeLimitOn) { _, isOn in
            if !isOn { TimeLimit.stopMonitoring() }
            updateBlocking()
        }
        .onChange(of: limitMinutes) { _, _ in
            updateBlocking()
        }
        .onAppear { checkLimitReached() }
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
}
