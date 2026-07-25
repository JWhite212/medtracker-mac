import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for the spike's scheduling.
enum NotificationManager {

    /// Ask the user for permission. The core "fires when quit" test needs at
    /// least `.alert` + `.sound`.
    static func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            spikeLog("Authorization request returned: granted=\(granted)")
        } catch {
            spikeLog("Authorization request FAILED: \(error.localizedDescription)")
        }
    }

    /// Schedule a one-shot notification `seconds` from now.
    ///
    /// `timeSensitive == true` sets `interruptionLevel = .timeSensitive`, which
    /// asks the system to break through Focus/Do-Not-Disturb. That level
    /// requires the `com.apple.developer.usernotifications.time-sensitive`
    /// entitlement (see SETUP.md, Test D) — without it the notification still
    /// delivers, just at the normal `.active` level.
    static func scheduleTest(seconds: TimeInterval, timeSensitive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "MedTracker spike"
        content.body = timeSensitive
            ? "Time-sensitive reminder scheduled \(Int(seconds))s ago — did it break through Focus?"
            : "Reminder scheduled \(Int(seconds))s ago — did it fire while the app was quit?"
        content.sound = .default
        content.categoryIdentifier = SpikeNotif.categoryID
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let id = "spike-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                spikeLog("SCHEDULE FAILED: \(error.localizedDescription)")
            } else {
                spikeLog("SCHEDULED \(id) to fire in \(Int(seconds))s\(timeSensitive ? " [time-sensitive]" : ""). Now QUIT the app (⌘Q).")
            }
        }
    }

    /// How many requests are still pending — useful to confirm one is queued
    /// before you quit.
    static func reportPending() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            spikeLog("Pending requests: \(requests.count) [\(requests.map(\.identifier).joined(separator: ", "))]")
        }
    }
}
