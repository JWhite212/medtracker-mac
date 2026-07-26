import Foundation
import GRDB
import MedTrackerData

/// Tallies from one `OutboxDrainer.drain(token:)` call.
public struct DrainResult: Equatable, Sendable {
    public var sent: Int
    public var failed: Int
    public var inProgress: Int

    public init(sent: Int, failed: Int, inProgress: Int) {
        self.sent = sent
        self.failed = failed
        self.inProgress = inProgress
    }
}

/// Drains the local `OutboxStore` via `POST /commands` (contract §4) and
/// reconciles any locally-generated ids the server assigned canonical
/// values to.
///
/// `drain(token:)` snapshots every `"pending"` row's id in FIFO order, then
/// submits them **one command per request**, re-reading each entry fresh
/// from the DB immediately before sending it. This one-at-a-time shape is
/// deliberate, not an efficiency oversight: an offline-created medication
/// (still keyed by its local id) and a dependent command enqueued after it
/// (e.g. "log a dose against the medication I just created") can both be
/// `"pending"` at the same time. If they were batched into the same
/// request, the dependent command's payload would still reference the
/// *local* id — the create's server-assigned id doesn't exist yet at
/// request-build time, so the server would reject the dependent command.
/// By sending one command at a time and re-reading the next entry right
/// before building its `WireCommand`, any reconciliation the previous
/// entry's create triggered (`Reconciler` rewrites `localId → serverId`
/// through every other still-`"pending"` outbox payload — Task 13) is
/// already reflected, so the dependent command reaches the server with the
/// correct, reconciled id.
///
/// For each entry:
/// - a successful create both rewrites the local id (via `Reconciler`, Task
///   13) and flips the outbox row to `"sent"` inside **one** write
///   transaction, so the two changes commit or roll back together — a
///   crash between them would otherwise leave a `"sent"` row still
///   pointing at a local id no other table has, or a reconciled row that
///   never got marked delivered and would be resubmitted next drain.
/// - `"in_progress"` (the server is still working an earlier attempt at
///   this idempotency key) and a missing result (shouldn't happen, but the
///   server dropping a row is not this client's failure) both leave the
///   row `"pending"` for the next drain to retry.
/// - any other failure is terminal for this attempt: `markFailed` records
///   it and the row stays `"failed"` until something re-enqueues it.
///
/// A transport/401/429/5xx error from `runCommands` aborts the whole drain
/// by rethrowing. Because each entry is fully applied to the DB before the
/// next entry's request goes out, an error on entry N does not undo entries
/// 1..N-1 — they're already `"sent"`/`"failed"` and durable. Only the entry
/// that threw (and any entries after it) remain `"pending"` for the next
/// drain to retry.
public struct OutboxDrainer: Sendable {
    private let apiClient: APIClient
    private let dbWriter: any DatabaseWriter
    private let outbox: OutboxStore
    private let reconciler: Reconciler

    public init(
        apiClient: APIClient, dbWriter: any DatabaseWriter, outbox: OutboxStore, reconciler: Reconciler = Reconciler()
    ) {
        self.apiClient = apiClient
        self.dbWriter = dbWriter
        self.outbox = outbox
        self.reconciler = reconciler
    }

    public func drain(token: String) async throws -> DrainResult {
        var tally = DrainResult(sent: 0, failed: 0, inProgress: 0)

        let ids = try outbox.pending().map(\.id) // FIFO snapshot of ids; guarantees loop termination
        guard !ids.isEmpty else { return tally }

        let decoder = JSONDecoder()

        for id in ids {
            // Re-read FRESH: an earlier iteration's reconcile may have remapped this entry's
            // payload (a dependent command referencing a just-created local id — see the type
            // doc), and it may no longer be "pending" at all; skip it if so.
            guard let entry = try fetchPendingEntry(id: id) else { continue }

            let payload = try decoder.decode(JSONValue.self, from: Data(entry.payload.utf8))
            let command = WireCommand(id: entry.idempotencyKey, type: entry.commandType, payload: payload)

            // Throwing here (transport/401/429/5xx) aborts the drain, but every earlier entry in
            // this loop has already been applied to the DB below — it stays durable and is not
            // resubmitted.
            let response = try await apiClient.runCommands([command], token: token)

            guard let result = response.results.first(where: { $0.id == entry.idempotencyKey }) else {
                // No result for this entry (shouldn't happen): treat as in_progress.
                tally.inProgress += 1
                continue
            }

            if result.ok {
                try applySent(entry: entry, result: result)
                tally.sent += 1
            } else if result.error == "in_progress" {
                tally.inProgress += 1
            } else {
                try outbox.markFailed(entry.id, error: result.error ?? "")
                tally.failed += 1
            }
        }

        return tally
    }

    /// Fetches an entry fresh from the DB, returning `nil` if it's gone or no longer `"pending"`.
    /// A private, non-`async` wrapper so `dbWriter.read`'s closure-based overload resolves
    /// correctly when called from `drain`'s `async` context — on this beta toolchain, a bare
    /// `dbWriter.read { ... }` lexically inside an `async` function resolves to GRDB's `async`
    /// overload instead, even though the closure itself is synchronous (see the identical
    /// `read`/`write` wrapper pattern used throughout the test suite).
    private func fetchPendingEntry(id: String) throws -> OutboxEntry? {
        try dbWriter.read { db in
            guard let entry = try OutboxEntry.fetchOne(db, key: id), entry.status == "pending" else {
                return nil
            }
            return entry
        }
    }

    /// Reconciles the entry's local id to the server-assigned id (if any)
    /// and flips its status to `"sent"` inside one write transaction, so
    /// the two changes are atomic — see the type doc for why.
    private func applySent(entry: OutboxEntry, result: CommandResultDTO) throws {
        try dbWriter.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            if let localEntityId = entry.localEntityId,
               let localEntityKindRaw = entry.localEntityKind,
               let kind = EntityKind(rawValue: localEntityKindRaw),
               let serverId = Self.serverId(for: kind, in: result)
            {
                try reconciler.reconcile(localId: localEntityId, serverId: serverId, kind: kind, in: db)
            }

            guard var row = try OutboxEntry.fetchOne(db, key: entry.id) else { return }
            row.status = "sent"
            try row.update(db)
        }
    }

    /// Extracts the server-assigned id from a command result. The result shape differs by
    /// command kind (contract §4):
    /// - `.doseLog` (`log_dose` / `skip_dose`) → `{ "id": "<doseId>" }`.
    /// - `.medication` (`upsert_medication_with_schedules` create) →
    ///   `{ "medication": { ...row incl "id"... } }` — the id lives one level deeper, nested
    ///   under `"medication"`.
    private static func serverId(for kind: EntityKind, in result: CommandResultDTO) -> String? {
        switch kind {
        case .medication:
            result.result?["medication"]?["id"]?.stringValue
        case .doseLog:
            result.result?["id"]?.stringValue
        }
    }
}
