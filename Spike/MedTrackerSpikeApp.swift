import SwiftUI

@main
struct MedTrackerSpikeApp: App {
    // Registers AppDelegate as both the NSApplication delegate AND (inside it)
    // the UNUserNotificationCenter delegate, at launch — see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("MedTracker Notification Spike") {
            SpikeView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}
