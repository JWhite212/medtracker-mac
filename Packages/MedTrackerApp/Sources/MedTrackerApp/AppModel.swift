import Foundation
import GRDB
import MedTrackerData

/// The three 1c sidebar destinations (Analytics/Settings omitted entirely, §2.5).
public enum SidebarItem: Hashable, CaseIterable {
    case dashboard, medications, history
}

/// App-wide model: sidebar selection, the injected write/sync infrastructure, and the
/// synced `Profile`/`Settings` singletons that supply the timezone for ALL date bucketing
/// (§2.5, §3.3) and the read-only display preferences (§8-#13/14/15).
@MainActor @Observable public final class AppModel {
    public var selection: SidebarItem?
    public let dbWriter: any DatabaseWriter
    public let userId: String
    public let writeCoordinator: WriteCoordinator
    public let syncScheduler: SyncScheduler
    public private(set) var profile: Profile?
    public private(set) var settings: Settings?

    /// Timezone from the synced `Profile` (`TimeZone(identifier:)`), never `TimeZone.current`;
    /// UTC fallback covers the offline-relaunch-before-first-Profile edge (§3.3, §8-#16).
    public var timeZone: TimeZone {
        profile.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone(identifier: "UTC")!
    }

    public init(dbWriter: any DatabaseWriter, userId: String,
                writeCoordinator: WriteCoordinator, syncScheduler: SyncScheduler,
                selection: SidebarItem? = .dashboard)
    {
        self.dbWriter = dbWriter
        self.userId = userId
        self.writeCoordinator = writeCoordinator
        self.syncScheduler = syncScheduler
        self.selection = selection
    }

    /// View-driven observation of the singleton `Profile(id == 1)`; SwiftUI owns the lifetime
    /// via `.task { await model.observeProfile() }` and cancels on disappear (A1). No stored Task.
    public func observeProfile() async {
        do {
            let observation = ValueObservation.tracking { db in
                try Profile.fetchOne(db, key: 1)
            }
            for try await profile in observation.values(in: dbWriter) {
                self.profile = profile
            }
        } catch is CancellationError {
            // view disappeared — not an error
        } catch {
            // leave `profile` as-is; `timeZone` falls back to UTC until a Profile lands
        }
    }

    /// View-driven observation of the singleton `Settings(id == 1)`; same lifecycle rules as
    /// `observeProfile()` — SwiftUI owns it via `.task { await model.observeSettings() }` and
    /// cancels on disappear. Screens read `dateFormat`/`timeFormat`/`doseLogPageSize`/
    /// `reducedMotion` from this, read-only in 1c.
    public func observeSettings() async {
        do {
            let observation = ValueObservation.tracking { db in
                try Settings.fetchOne(db, key: 1)
            }
            for try await settings in observation.values(in: dbWriter) {
                self.settings = settings
            }
        } catch is CancellationError {
            // view disappeared — not an error
        } catch {
            // leave `settings` as-is; screens fall back to Settings' own defaults until it lands
        }
    }
}
