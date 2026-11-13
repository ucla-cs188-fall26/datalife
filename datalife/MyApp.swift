import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                .task { await DebugTestEvents.seedIfRequested() }
                #endif
        }
    }
}
