import SwiftUI

struct BlockedAppItem: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let isShielded: Bool
}

struct ContentView: View {
    // Skeletal placeholder state for usage
    @State private var usedMinutes: Int = 45
    @State private var allowanceMinutes: Int = 90
    @State private var busyMinutes: Int = 120

    // Skeletal list of blocked/restricted apps
    @State private var blockedApps: [BlockedAppItem] = [
        BlockedAppItem(name: "Instagram", category: "Social", isShielded: true),
        BlockedAppItem(name: "TikTok", category: "Entertainment", isShielded: true),
        BlockedAppItem(name: "YouTube", category: "Entertainment", isShielded: true),
        BlockedAppItem(name: "X (Twitter)", category: "Social", isShielded: false)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Usage") {
                    HStack {
                        Text("Recreational Usage")
                        Spacer()
                        Text("\(usedMinutes)m / \(allowanceMinutes)m")
                            .foregroundColor(.secondary)
                    }

                    ProgressView(value: Double(usedMinutes), total: Double(max(allowanceMinutes, 1)))

                    HStack {
                        Text("Busy Time")
                        Spacer()
                        Text("\(busyMinutes / 60)h \(busyMinutes % 60)m")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Remaining Allowance")
                        Spacer()
                        Text("\(max(0, allowanceMinutes - usedMinutes))m")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Blocked Apps") {
                    if blockedApps.isEmpty {
                        Text("No apps currently restricted")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(blockedApps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.category)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(app.isShielded ? "Blocked" : "Monitored")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(app.isShielded ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                                    .foregroundColor(app.isShielded ? .red : .orange)
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
            }
            .navigationTitle("DataLife")
        }
    }
}

#Preview {
    ContentView()
}
