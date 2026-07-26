import Foundation
import GRDB
import MedTrackerData

/// Tallies from one `SyncEngine.sync()` call: what got pushed (the outbox drain) and what got
/// pulled (the `GET /sync` response applied to the local replica).
public struct SyncOutcome: Equatable, Sendable {
    public var fullResync: Bool
    public var pushed: DrainResult
    public var pulledMedications: Int
    public var pulledDoseLogs: Int

    public init(fullResync: Bool, pushed: DrainResult, pulledMedications: Int, pulledDoseLogs: Int) {
        self.fullResync = fullResync
        self.pushed = pushed
        self.pulledMedications = pulledMedications
        self.pulledDoseLogs = pulledDoseLogs
    }
}

/// The actor orchestrator that ties the whole `/api/v1` sync engine together: it composes an
/// `APIClient` (Task 5/6), `OutboxStore` (Task 12), `SyncApplier` (Task 10/11), `OutboxDrainer`
/// (Task 14), and `SyncStateStore` (Task 8) from its dependencies, and exposes the small surface
/// (`login`/`verifyTOTP`/`signInWithApple`/`enqueue`/`sync`) that callers outside this package
/// need. Being an `actor` does **not** mean two overlapping `sync()` calls can't interleave —
/// Swift actors are reentrant, so a second caller's `sync()` can start running while the first is
/// suspended at an `await` (e.g. mid-network-request) partway through its own drain/pull/apply/
/// persist sequence. Overlapping syncs are safe anyway, because every step in that sequence is
/// idempotent: outbox commands are deduped server-side on their idempotency key (contract §4),
/// every local write goes through GRDB's serialized `dbWriter` (no two writes race at the SQLite
/// level), and applying a `/sync` response is a server-authoritative upsert — replaying the same
/// (or a newer) response twice converges on the same state rather than corrupting it.
public actor SyncEngine {
    private let apiClient: APIClient
    private let tokenStore: any TokenStore
    private let outbox: OutboxStore
    private let drainer: OutboxDrainer
    private let applier: SyncApplier
    private let stateStore: SyncStateStore

    public init(
        config: SyncConfig,
        dbWriter: any DatabaseWriter,
        tokenStore: any TokenStore,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        let apiClient = APIClient(config: config, transport: transport)
        let outbox = OutboxStore(dbWriter: dbWriter)
        self.apiClient = apiClient
        self.tokenStore = tokenStore
        self.outbox = outbox
        drainer = OutboxDrainer(apiClient: apiClient, dbWriter: dbWriter, outbox: outbox)
        applier = SyncApplier(dbWriter: dbWriter)
        stateStore = SyncStateStore(dbWriter: dbWriter)
    }

    /// `POST /auth/login` (contract §2). Persists `StoredSession` when the response is a live
    /// session; leaves the token store untouched for a TOTP challenge.
    @discardableResult
    public func login(email: String, password: String) async throws -> LoginOutcome {
        let outcome = try await apiClient.login(email: email, password: password)
        if case let .session(token, user) = outcome {
            try tokenStore.save(StoredSession(token: token, userId: user.id))
        }
        return outcome
    }

    /// `POST /auth/2fa` (contract §2) — completes a TOTP challenge into a live session and
    /// persists it.
    @discardableResult
    public func verifyTOTP(preAuthToken: String, code: String) async throws -> SessionUser {
        let (token, user) = try await apiClient.verifyTOTP(preAuthToken: preAuthToken, code: code)
        try tokenStore.save(StoredSession(token: token, userId: user.id))
        return user
    }

    /// `POST /auth/apple` (contract §2) — Sign in with Apple; persists the resulting session.
    @discardableResult
    public func signInWithApple(identityToken: String, fullName: String?) async throws -> SessionUser {
        let (token, user) = try await apiClient.signInWithApple(identityToken: identityToken, fullName: fullName)
        try tokenStore.save(StoredSession(token: token, userId: user.id))
        return user
    }

    /// Delegates to `OutboxStore.enqueue` — see its doc comment for the write semantics.
    @discardableResult
    public func enqueue(
        type: String,
        payload: JSONValue,
        localEntityId: String? = nil,
        localEntityKind: EntityKind? = nil
    ) throws -> OutboxEntry {
        try outbox.enqueue(
            type: type, payload: payload, localEntityId: localEntityId, localEntityKind: localEntityKind
        )
    }

    /// Tx-joining passthrough to `OutboxStore.enqueue(_ db:…)`. Marked `nonisolated`
    /// so it is callable from inside a synchronous `dbWriter.write { db in … }` block
    /// (an actor-isolated `async` method could not be — the write closure cannot
    /// `await`). Reads only the immutable, Sendable `outbox`, so this is concurrency-safe.
    @discardableResult
    nonisolated public func enqueue(
        _ db: Database, type: String, payload: JSONValue,
        localEntityId: String? = nil, localEntityKind: EntityKind? = nil
    ) throws -> OutboxEntry {
        try outbox.enqueue(db, type: type, payload: payload,
                           localEntityId: localEntityId, localEntityKind: localEntityKind)
    }

    /// Runs one full sync cycle: push, then pull, then apply, then persist. Each step commits its
    /// own durable state before the next begins (the drainer commits one command at a time,
    /// `SyncApplier` commits its whole apply in one transaction, and the cursor+epoch write is
    /// last, committed together in one transaction via `saveCursorAndEpoch`), so a crash
    /// mid-`sync()` never loses already-durable progress — the next call resumes from whatever
    /// was last persisted.
    ///
    /// Throws `APIError.unauthorized` when no session is stored, and otherwise surfaces whatever
    /// `APIError` the drain or pull steps raise (notably `.unauthorized`/`.rateLimited`) rather
    /// than swallowing it — callers decide how to react (re-auth, backoff, ...).
    public func sync() async throws -> SyncOutcome {
        guard let session = try tokenStore.load() else { throw APIError.unauthorized }

        let pushed = try await drainer.drain(token: session.token)

        let response = try await apiClient.sync(
            since: try stateStore.loadCursor(), epoch: try stateStore.loadEpoch(), token: session.token
        )
        try applier.apply(response)

        try stateStore.saveCursorAndEpoch(cursor: response.cursor, epoch: response.epoch)

        return SyncOutcome(
            fullResync: response.fullResync,
            pushed: pushed,
            pulledMedications: response.medications.count,
            pulledDoseLogs: response.doseLogs.count
        )
    }
}
