import SwiftUI

struct SpikeView: View {
    @ObservedObject private var log = SpikeLog.shared

    // API round-trip inputs (secondary leg). Prefilled with the demo account
    // shape from the web app's landing page — change to your real deployment.
    @State private var baseURL = "https://YOUR-APP.vercel.app"
    @State private var email = "demo@medtracker.app"
    @State private var password = "demo-medtracker-2026"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MedTracker — Notification Go/No-Go Spike")
                .font(.title2).bold()
            Text("Goal: prove a scheduled notification fires while this app is **fully quit**, and that tapping its action relaunches + reaches the app. See SETUP.md for the exact procedure.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("1 · Permission") {
                HStack {
                    Button("Request notification permission") {
                        Task { await NotificationManager.requestAuthorization() }
                    }
                    Button("Check pending") { NotificationManager.reportPending() }
                }.padding(6)
            }

            GroupBox("2 · Schedule, then QUIT the app (⌘Q)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Fire in 15s") { NotificationManager.scheduleTest(seconds: 15, timeSensitive: false) }
                        Button("Fire in 60s") { NotificationManager.scheduleTest(seconds: 60, timeSensitive: false) }
                        Button("Fire in 5 min") { NotificationManager.scheduleTest(seconds: 300, timeSensitive: false) }
                    }
                    Divider()
                    Button("Fire in 60s — TIME-SENSITIVE (Test D)") {
                        NotificationManager.scheduleTest(seconds: 60, timeSensitive: true)
                    }
                    Text("After scheduling, press ⌘Q to quit and watch for the banner while the app is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }

            GroupBox("3 · Backend round-trip (secondary)") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    }
                    Button("Test /api/v1 login + sync") {
                        Task { await SpikeAPIClient.testRoundTrip(baseURL: baseURL, email: email, password: password) }
                    }
                }.padding(6)
            }

            GroupBox("Event log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.events.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Spacer()
                    Button("Clear log") { log.clear() }
                }.padding(.top, 4)
            }
        }
        .padding(18)
    }
}
