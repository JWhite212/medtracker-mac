import Foundation
import GRDB
import MedTrackerData
import MedTrackerSync

/// The process-wide composition root (§2.4). Plain `Sendable` infrastructure — NOT `@Observable`;
/// mutable UI/session state lives in `SessionModel`/`AppModel`. Built once at launch into `@State`.
@MainActor
public final class AppEnvironment {
    public let dbWriter: any DatabaseWriter
    public let tokenStore: any TokenStore
    public let syncEngine: SyncEngine

    private init(dbWriter: any DatabaseWriter, tokenStore: any TokenStore, syncEngine: SyncEngine) {
        self.dbWriter = dbWriter
        self.tokenStore = tokenStore
        self.syncEngine = syncEngine
    }

    /// Live wiring: on-disk GRDB in the sandbox container, the Keychain token store, and the
    /// production `/api/v1` config with the default `URLSessionTransport`. Never used in CI.
    public static func live() throws -> AppEnvironment {
        let dbWriter = try MedTrackerDatabase.open(path: databaseURL().path)
        let tokenStore = KeychainTokenStore()
        let engine = SyncEngine(config: .production, dbWriter: dbWriter, tokenStore: tokenStore)
        return AppEnvironment(dbWriter: dbWriter, tokenStore: tokenStore, syncEngine: engine)
    }

    /// Hermetic wiring for `swift test`: in-memory GRDB, an injectable transport + token store,
    /// no network, no Keychain. Same `.production` config so URL-building parity is preserved.
    public static func testing(transport: HTTPTransport,
                               tokenStore: any TokenStore = InMemoryTokenStore()) throws -> AppEnvironment {
        let dbWriter = try MedTrackerDatabase.open(path: nil)
        let engine = SyncEngine(config: .production, dbWriter: dbWriter,
                                tokenStore: tokenStore, transport: transport)
        return AppEnvironment(dbWriter: dbWriter, tokenStore: tokenStore, syncEngine: engine)
    }

    /// `~/Library/Containers/site.jamiewhite.medtracker/Data/Library/Application Support/MedTracker/medtracker.sqlite`
    /// under App Sandbox — FileVault-covered, Time-Machine-backed (§12). Creates the directory if absent.
    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("MedTracker", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("medtracker.sqlite")
    }
}
