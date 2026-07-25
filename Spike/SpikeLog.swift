import Combine
import Foundation

/// A tiny observable event log the spike UI renders. Everything the app and the
/// notification delegate do gets appended here so you can watch the go/no-go
/// evidence accumulate — including the action-tap that relaunches the app after a
/// notification fired while the app was quit.
///
/// Events are also persisted to `UserDefaults`, so the action-handling log line
/// written on relaunch (Test C) is still there when the window reappears.
///
/// Compiles cleanly in the **default Swift 5 language mode** (what a new Xcode
/// macOS App uses). `nonisolated(unsafe)` silences the global-var diagnostic;
/// `@Published` mutations are hopped to the main queue in `log()`/`clear()`.
/// (If you ever switch the target to Swift 6 language mode, mark this class
/// `@MainActor` and drop the `DispatchQueue.main.async` wrappers.)
final class SpikeLog: ObservableObject {
    nonisolated(unsafe) static let shared = SpikeLog()

    @Published private(set) var events: [String] = []

    private let defaultsKey = "spike.events"

    private init() {
        events = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    func log(_ message: String) {
        let line = "[\(Self.stamp())] \(message)"
        NSLog("SPIKE %@", line)
        DispatchQueue.main.async {
            self.events.append(line)
            UserDefaults.standard.set(self.events, forKey: self.defaultsKey)
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.events.removeAll()
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

/// Call from anywhere (including off-main `UNUserNotificationCenter` delegate
/// callbacks); the `@Published` mutation is dispatched to main inside `log()`.
func spikeLog(_ message: String) {
    SpikeLog.shared.log(message)
}
