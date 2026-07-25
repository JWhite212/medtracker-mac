import AppKit
import UserNotifications

/// The notification identifiers/actions the spike uses.
enum SpikeNotif {
    static let categoryID = "DOSE_REMINDER"
    static let logAction = "LOG_DOSE"
    static let skipAction = "SKIP_DOSE"
}

/// We use an AppDelegate (via `@NSApplicationDelegateAdaptor`) rather than
/// setting the delegate inside the SwiftUI `App` initializer for one reason
/// that matters to this spike: when a notification fires *while the app is
/// quit* and the user taps one of its action buttons, the system LAUNCHES the
/// app and delivers the response to `userNotificationCenter(_:didReceive:)`.
/// For that delivery to be received, the `UNUserNotificationCenter` delegate
/// must already be set by the time launching finishes — `applicationDidFinishLaunching`
/// is the correct, earliest reliable place.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register the category so notifications can carry "Log dose" / "Skip"
        // action buttons — the same shape the real app will use.
        let log = UNNotificationAction(
            identifier: SpikeNotif.logAction,
            title: "Log dose",
            options: [.foreground]
        )
        let skip = UNNotificationAction(
            identifier: SpikeNotif.skipAction,
            title: "Skip",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: SpikeNotif.categoryID,
            actions: [log, skip],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        spikeLog("App launched. Notification delegate registered.")

        // Report whether this launch was triggered by a notification (i.e. the
        // app had been quit and the notification fired anyway — the money shot).
        center.getNotificationSettings { settings in
            spikeLog("Authorization status at launch: \(Self.describe(settings.authorizationStatus))")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification is delivered while the app is in the
    /// FOREGROUND. Returning `.banner`/`.sound` makes it visible even then, so
    /// you can also sanity-check delivery without quitting.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        spikeLog("DELIVERED (app in foreground): \(notification.request.identifier)")
        completionHandler([.banner, .sound, .list])
    }

    /// Called when the user interacts with a delivered notification — including
    /// the case where the app was QUIT, the notification fired, and tapping an
    /// action button relaunched the app. This is the "action round-trips into
    /// the app" leg of the spike.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        switch action {
        case SpikeNotif.logAction:
            spikeLog("ACTION 'Log dose' tapped for \(id) — app relaunched/handled ✅")
        case SpikeNotif.skipAction:
            spikeLog("ACTION 'Skip' tapped for \(id)")
        case UNNotificationDefaultActionIdentifier:
            spikeLog("Notification body tapped for \(id) — app relaunched/handled ✅")
        case UNNotificationDismissActionIdentifier:
            spikeLog("Notification dismissed for \(id)")
        default:
            spikeLog("Unknown action '\(action)' for \(id)")
        }
        completionHandler()
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
