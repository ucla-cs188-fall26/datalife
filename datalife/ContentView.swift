import SwiftUI
import FamilyControls
import ManagedSettings

struct ContentView: View {
    @State private var selection = FamilyActivitySelection()
    @State private var isPickerPresented = false
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var statusMessage = ""

    private let store = ManagedSettingsStore()

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
                            statusMessage = "Error: \(error.localizedDescription)\n\nNote: Screen Time requires running on a physical iPhone with a Developer Team selected in Xcode (FamilyControls is not supported on the Simulator)."
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
            .familyActivityPicker(isPresented: $isPickerPresented, selection: $selection)
            .onChange(of: selection) { _, newSelection in
                applyShield(newSelection)
            }

            // 3. Shield Status
            if selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty {
                Text("No app selected")
                    .foregroundColor(.secondary)
            } else {
                Text("Shield active on selected app(s)")
                    .foregroundColor(.red)
                    .fontWeight(.bold)

                Button("Unblock") {
                    selection = FamilyActivitySelection()
                    store.shield.applications = nil
                    store.shield.applicationCategories = nil
                }
                .foregroundColor(.secondary)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .padding()
        .onAppear {
            authStatus = AuthorizationCenter.shared.authorizationStatus
        }
    }

    private func applyShield(_ newSelection: FamilyActivitySelection) {
        store.shield.applications = newSelection.applicationTokens.isEmpty ? nil : newSelection.applicationTokens
        store.shield.applicationCategories = newSelection.categoryTokens.isEmpty ? nil : .specific(newSelection.categoryTokens)
    }
}

#Preview {
    ContentView()
}

