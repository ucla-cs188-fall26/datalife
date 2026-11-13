import SwiftUI

/// Saved breathing-timer settings (stored on-device in UserDefaults).
enum BreathingSettings {
    static let inhaleKey = "breathing.inhaleSeconds"
    static let holdKey = "breathing.holdSeconds"
    static let exhaleKey = "breathing.exhaleSeconds"
    static let roundsKey = "breathing.rounds"

    // Prototype defaults.
    static let defaultInhale = 4
    static let defaultHold = 0
    static let defaultExhale = 4
    static let defaultRounds = 3
}

/// A short guided breathing pause: a circle grows while you breathe in, stays full while
/// you hold, and shrinks while you breathe out, with a countdown.
/// Used as friction before an emergency override. Timing comes from BreathingSettings.
struct BreathingView: View {
    /// Label for the button shown once the pause is finished. If nil, only "Done" is shown.
    var continueTitle: String? = nil
    /// Called when the user taps the continue button after finishing.
    var onContinue: () -> Void = {}

    @AppStorage(BreathingSettings.inhaleKey) private var inhale = BreathingSettings.defaultInhale
    @AppStorage(BreathingSettings.holdKey) private var hold = BreathingSettings.defaultHold
    @AppStorage(BreathingSettings.exhaleKey) private var exhale = BreathingSettings.defaultExhale
    @AppStorage(BreathingSettings.roundsKey) private var rounds = BreathingSettings.defaultRounds

    @Environment(\.dismiss) private var dismiss
    @State private var startDate = Date()

    private var breathLength: Int { inhale + hold + exhale }
    private var totalSeconds: Int { breathLength * rounds }

    /// Where we are in the current breath: the label and how full the circle is (0...1).
    private func phase(at elapsed: Double) -> (label: String, fill: Double) {
        let t = elapsed.truncatingRemainder(dividingBy: Double(max(breathLength, 1)))
        let i = Double(inhale), h = Double(hold), e = Double(max(exhale, 1))
        if t < i { return ("Breathe in", t / max(i, 1)) }
        if t < i + h { return ("Hold", 1) }
        return ("Breathe out", 1 - (t - i - h) / e)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let finished = elapsed >= Double(totalSeconds)
            let current = phase(at: elapsed)
            // Ease the size change so it feels like a breath.
            let eased = finished ? 0.5 : (1 - cos(current.fill * .pi)) / 2
            let remaining = max(0, Int((Double(totalSeconds) - elapsed).rounded(.up)))

            VStack(spacing: 32) {
                Spacer()

                Text(finished ? "Nice work" : current.label)
                    .font(.largeTitle)
                    .bold()
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: current.label)

                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 280, height: 280)
                    Circle()
                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 280, height: 280)
                        .scaleEffect(0.35 + 0.65 * eased)
                        .opacity(0.85)
                    Text(finished ? "✓" : "\(remaining)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }

                Text(finished
                     ? "Take a second. Do you still need your phone right now?"
                     : "Slow down before you decide.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                if finished {
                    VStack(spacing: 12) {
                        if let continueTitle {
                            Button {
                                onContinue()
                                dismiss()
                            } label: {
                                Text(continueTitle)
                                    .font(.title3).fontWeight(.semibold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.large)
                        }
                        Button {
                            dismiss()
                        } label: {
                            Text(continueTitle == nil ? "Done" : "Never mind")
                                .font(.title2).fontWeight(.semibold)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    Button("Cancel") { dismiss() }
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .onAppear { startDate = Date() }
    }
}

/// Lets the user change the breathing timer's timing. Changes are saved automatically.
struct BreathingSettingsView: View {
    @AppStorage(BreathingSettings.inhaleKey) private var inhale = BreathingSettings.defaultInhale
    @AppStorage(BreathingSettings.holdKey) private var hold = BreathingSettings.defaultHold
    @AppStorage(BreathingSettings.exhaleKey) private var exhale = BreathingSettings.defaultExhale
    @AppStorage(BreathingSettings.roundsKey) private var rounds = BreathingSettings.defaultRounds

    @Environment(\.dismiss) private var dismiss
    @State private var showPreview = false

    private var totalSeconds: Int { (inhale + hold + exhale) * rounds }

    var body: some View {
        NavigationStack {
            Form {
                Section("Each breath") {
                    Stepper("Breathe in: \(inhale) sec", value: $inhale, in: 2...10)
                    Stepper(hold == 0 ? "Hold: off" : "Hold: \(hold) sec", value: $hold, in: 0...10)
                    Stepper("Breathe out: \(exhale) sec", value: $exhale, in: 2...10)
                }
                .font(.title3)

                Section {
                    Stepper("Breaths: \(rounds)", value: $rounds, in: 1...10)
                        .font(.title3)
                } footer: {
                    Text("Total pause: \(LimitReachedView.format(seconds: totalSeconds))")
                        .font(.body)
                }

                Section {
                    Button("Try It") { showPreview = true }
                    Button("Reset to Default", role: .destructive) {
                        inhale = BreathingSettings.defaultInhale
                        hold = BreathingSettings.defaultHold
                        exhale = BreathingSettings.defaultExhale
                        rounds = BreathingSettings.defaultRounds
                    }
                }
                .font(.title3)
            }
            .navigationTitle("Breathing Timer")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showPreview) {
                BreathingView()
            }
        }
    }
}

#Preview {
    BreathingView(continueTitle: "Unblock for 5 min")
}

#Preview("Settings") {
    BreathingSettingsView()
}
