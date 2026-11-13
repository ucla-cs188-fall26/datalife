import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation

/// Runs in the background (even when DataLife is closed). iOS wakes it when the
/// daily usage limit for the selected apps is reached, and at the start of each day.
///
/// These keys must match TimeLimit.swift in the main app.
private enum Shared {
    static let appGroup = "group.ucla.cs188.datalife"
    static let selectionKey = "blockedSelection"
    static let reachedAtKey = "timeLimit.reachedAt"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}

class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    // The default store is shared with the main app, so either side can turn the block off.
    let store = ManagedSettingsStore()

    /// A new day started: reset the limit and lift the block.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Shared.defaults.removeObject(forKey: Shared.reachedAtKey)
        clearShield()
    }

    /// The day ended: lift the block (it starts fresh at midnight).
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        clearShield()
    }

    /// The selected apps were used for the daily limit: block them.
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let data = Shared.defaults.data(forKey: Shared.selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }

        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)

        // Lets the app show the "limit reached" screen next time it opens.
        Shared.defaults.set(Date(), forKey: Shared.reachedAtKey)
    }

    private func clearShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }
}
