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
/// `drain(token:)` reads every `"pending"` row, submits them as a single
/// wire batch (chunked to respect the server's per-request command limit),
/// then walks the results:
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
/// A transport/401/429 error from `runCommands` aborts the whole drain by
/// rethrowing — whatever chunks already committed stay durable, and the
/// remaining pending rows are picked up by the next drain.
public struct OutboxDrainer: Sendable {
    /// The server's per-request command limit (contract §4).
    private static let chunkSize = 200

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
        let entries = try outbox.pending()
        guard !entries.isEmpty else { return DrainResult(sent: 0, failed: 0, inProgress: 0) }

        let decoder = JSONDecoder()
        let commands = try entries.map { entry -> WireCommand in
            let payload = try decoder.decode(JSONValue.self, from: Data(entry.payload.utf8))
            return WireCommand(id: entry.idempotencyKey, type: entry.commandType, payload: payload)
        }

        var resultsById: [String: CommandResultDTO] = [:]
        for chunk in commands.chunked(into: Self.chunkSize) {
            let response = try await apiClient.runCommands(chunk, token: token)
            for result in response.results {
                resultsById[result.id] = result
            }
        }

        var tally = DrainResult(sent: 0, failed: 0, inProgress: 0)
        for entry in entries {
            guard let result = resultsById[entry.idempotencyKey] else {
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

    /// Reconciles the entry's local id to the server-assigned id (if any)
    /// and flips its status to `"sent"` inside one write transaction, so
    /// the two changes are atomic — see the type doc for why.
    private func applySent(entry: OutboxEntry, result: CommandResultDTO) throws {
        try dbWriter.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            if let localEntityId = entry.localEntityId,
               let localEntityKindRaw = entry.localEntityKind,
               let kind = EntityKind(rawValue: localEntityKindRaw),
               let serverId = result.result?["id"]?.stringValue
            {
                try reconciler.reconcile(localId: localEntityId, serverId: serverId, kind: kind, in: db)
            }

            guard var row = try OutboxEntry.fetchOne(db, key: entry.id) else { return }
            row.status = "sent"
            try row.update(db)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
