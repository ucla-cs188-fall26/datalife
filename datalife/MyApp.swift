import SwiftUI

@main struct MyApp: App {
    /// Today's busy time and allowance, kept for the app's lifetime. No UI of its own;
    /// screens can read it with `@EnvironmentObject var busyTime: BusyTimeModel`.
    @StateObject private var busyTime = BusyTimeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(busyTime)
                .task { busyTime.start() }
                #if DEBUG
                .task { await DebugTestEvents.seedIfRequested() }
                #endif
        }
    }
}
