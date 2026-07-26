import Foundation
import GRDB
import MedTrackerCore

/// Errors surfaced by `DoseRepository`. Mirrors the web's
/// `MedicationNotFoundError` (`src/lib/server/doses.ts:10-15`) — the other
/// TS "not found" cases (`deleteDose`/`updateDose` returning `false`/`null`)
/// are ported as `Bool`/optional returns rather than throws, matching the
/// TS control flow exactly.
public enum DoseRepositoryError: Error, Equatable {
    case medicationNotFound
}

/// Transactional operations on `dose_log` rows, including the load-bearing
/// inventory decrement/restore/diff side effects and the audit trail. Ports
/// `src/lib/server/doses.ts` (web app `medication-tracker`) — see that file
/// for the exact semantics reproduced here.
///
/// Every mutation below is **one** `dbWriter.write { }` call. GRDB wraps the
/// closure in a SQLite transaction and rolls back automatically the moment
/// anything inside throws, so the dose row, its inventory side effect, and
/// its audit row commit or roll back together as a single unit — this is
/// the property that retires the web's "Neon HTTP best-effort atomic"
/// caveat (see `doses.ts:75-79`).
public struct DoseRepository {
    private let dbWriter: any DatabaseWriter

    #if DEBUG
        /// Test-only fault injection. When set, invoked as the very last step
        /// inside the transaction body (after every production mutation has
        /// been applied, immediately before the closure returns) so that a
        /// thrown error demonstrates nothing committed. Never set outside
        /// `RepositoryTests.swift` — production callers never touch this.
        var testFaultAfterMutation: (() throws -> Void)?
    #endif

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - logDose

    /// Ports `logDose` (`doses.ts:63-138`). Inserts a `taken` dose_log row;
    /// if the medication tracks inventory (`inventoryCount != nil`),
    /// decrements it clamped at 0 and appends a `dose_taken` inventory_event
    /// whose `quantityChange` is the **actual clamped delta**
    /// (`newCount - previousCount`), not `-quantity`. Untracked medications
    /// record no event. Always appends a `create` audit row. One transaction.
    @discardableResult
    public func logDose(
        userId: String,
        medicationId: String,
        quantity: Int,
        takenAt: Date? = nil,
        notes: String? = nil,
        sideEffects: [SideEffectEntry]? = nil,
        now: Date = Date()
    ) throws -> DoseLog {
        try dbWriter.write { db in
            guard var med = try Medication.fetchOwned(db, userId: userId, id: medicationId) else {
                throw DoseRepositoryError.medicationNotFound
            }

            let id = createId()
            let nowEpoch = now.timeIntervalSince1970
            let dose = DoseLog(
                id: id,
                userId: userId,
                medicationId: medicationId,
                quantity: quantity,
                takenAt: (takenAt ?? now).timeIntervalSince1970,
                loggedAt: nowEpoch,
                notes: notes,
                sideEffects: sideEffects,
                status: "taken",
                updatedAt: nowEpoch
            )
            try dose.insert(db)

            // Snapshot the count BEFORE the update so the inventory event
            // can record both ends of the change. Only recorded when
            // inventory is actually tracked (previousCount != nil).
            if let previousCount = med.inventoryCount {
                let newCount = max(0, previousCount - quantity)
                med.inventoryCount = newCount
                try med.update(db)

                try InventoryEvent(
                    id: createId(),
                    userId: userId,
                    medicationId: medicationId,
                    eventType: "dose_taken",
                    quantityChange: newCount - previousCount,
                    previousCount: previousCount,
                    newCount: newCount,
                    createdAt: nowEpoch
                ).insert(db)
            }

            try AuditLog(
                id: createId(),
                userId: userId,
                entityType: "dose_log",
                entityId: id,
                action: "create",
                createdAt: nowEpoch
            ).insert(db)

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return dose
        }
    }

    // MARK: - logSkippedDose

    /// Ports `logSkippedDose` (`doses.ts:140-162`). Inserts a `skipped`
    /// dose_log row with `quantity = 1`. No inventory change, no
    /// inventory_event — skipped doses never decremented inventory. Appends
    /// a `create` audit row. One transaction.
    ///
    /// Returns the inserted row (the TS returns only the generated id; the
    /// full row is more useful to Swift callers and carries strictly more
    /// information, so this is an intentional, behavior-preserving
    /// divergence in return shape only).
    @discardableResult
    public func logSkippedDose(
        userId: String,
        medicationId: String,
        now: Date = Date()
    ) throws -> DoseLog {
        try dbWriter.write { db in
            guard try Medication.fetchOwned(db, userId: userId, id: medicationId) != nil else {
                throw DoseRepositoryError.medicationNotFound
            }

            let id = createId()
            let nowEpoch = now.timeIntervalSince1970
            let dose = DoseLog(
                id: id,
                userId: userId,
                medicationId: medicationId,
                quantity: 1,
                takenAt: nowEpoch,
                loggedAt: nowEpoch,
                notes: nil,
                sideEffects: nil,
                status: "skipped",
                updatedAt: nowEpoch
            )
            try dose.insert(db)

            try AuditLog(
                id: createId(),
                userId: userId,
                entityType: "dose_log",
                entityId: id,
                action: "create",
                createdAt: nowEpoch
            ).insert(db)

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return dose
        }
    }

    // MARK: - deleteDose

    /// Ports `deleteDose` (`doses.ts:164-223`). Returns `false` without any
    /// side effect when the dose doesn't exist (or isn't owned by
    /// `userId`). Restores inventory **only** when the deleted dose's
    /// `status == "taken"` — skipped/missed doses never decremented
    /// inventory, so nothing is restored for them. The restore is
    /// **unclamped** (`count + quantity`, no upper bound), intentionally
    /// asymmetric with the clamped-at-0 decrement in `logDose`. Appends a
    /// `dose_deleted` event (`quantityChange = +quantity`) only when
    /// inventory was tracked, and a `delete` audit row unconditionally when
    /// the dose existed. One transaction.
    ///
    /// Divergence: the web's `deleteDose` also inserts a `sync_tombstones`
    /// row for the future delta-sync engine. That table isn't part of the
    /// Phase 1a schema (sync/outbox draining is explicitly deferred to
    /// Phase 1b — see the plan's "Not in Phase 1a" section), so it's
    /// correctly omitted here.
    @discardableResult
    public func deleteDose(userId: String, doseId: String, now: Date = Date()) throws -> Bool {
        try dbWriter.write { db in
            guard let dose = try DoseLog.filter(key: doseId).filter(Column("user_id") == userId).fetchOne(db) else {
                return false
            }

            try dose.delete(db)

            if dose.status == "taken",
               var med = try Medication.fetchOwned(db, userId: userId, id: dose.medicationId),
               let previousCount = med.inventoryCount
            {
                let newCount = previousCount + dose.quantity
                med.inventoryCount = newCount
                try med.update(db)

                try InventoryEvent(
                    id: createId(),
                    userId: userId,
                    medicationId: dose.medicationId,
                    eventType: "dose_deleted",
                    quantityChange: dose.quantity,
                    previousCount: previousCount,
                    newCount: newCount,
                    createdAt: now.timeIntervalSince1970
                ).insert(db)
            }

            try AuditLog(
                id: createId(),
                userId: userId,
                entityType: "dose_log",
                entityId: doseId,
                action: "delete",
                createdAt: now.timeIntervalSince1970
            ).insert(db)

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return true
        }
    }

    // MARK: - updateDose

    /// Ports `updateDose` (`doses.ts:225-313`). Returns `nil` without any
    /// side effect when the dose doesn't exist. Adjusts inventory **only**
    /// when `status == "taken" && quantity` was supplied and differs from
    /// the existing quantity: `diff = newQuantity - oldQuantity`,
    /// `newCount = max(0, count - diff)`, and the recorded event delta is
    /// the clamped `newCount - previousCount` (not `-diff`). Diffs over the
    /// user-facing dose fields (deliberately **excluding** `updatedAt`) and
    /// appends an `update` audit row only when one of them actually changed —
    /// an INTENTIONAL divergence from the web's always-write behavior (see
    /// `docs/PARITY-DIVERGENCES.md` entry #2). One transaction.
    ///
    /// `notes`/`sideEffects` use Swift's `T??` "present vs. absent"
    /// convention to mirror the TS `updates.field !== undefined` check:
    /// omit the argument (defaults to `nil`, the outer `.none`) to leave
    /// the field untouched; pass `.some(nil)` to clear it; pass
    /// `.some(value)` to set it. `takenAt`/`quantity` use a plain optional
    /// (TS's truthy check has no meaningful "clear" case for either).
    @discardableResult
    public func updateDose(
        userId: String,
        doseId: String,
        takenAt: Date? = nil,
        quantity: Int? = nil,
        notes: String?? = nil,
        sideEffects: [SideEffectEntry]?? = nil,
        now: Date = Date()
    ) throws -> DoseLog? {
        try dbWriter.write { db in
            guard let existing = try DoseLog.filter(key: doseId).filter(Column("user_id") == userId).fetchOne(db)
            else {
                return nil
            }

            let inventoryAffectingChange = existing.status == "taken"
                && quantity != nil
                && quantity != existing.quantity

            var updated = existing
            if let takenAt {
                updated.takenAt = takenAt.timeIntervalSince1970
            }
            if let quantity {
                updated.quantity = quantity
            }
            if let notesUpdate = notes {
                updated.notes = (notesUpdate?.isEmpty ?? true) ? nil : notesUpdate
            }
            if let sideEffectsUpdate = sideEffects {
                updated.sideEffects = Self.encodeSideEffects(sideEffectsUpdate)
            }
            updated.updatedAt = now.timeIntervalSince1970

            try updated.update(db)

            if inventoryAffectingChange, let newQuantity = quantity {
                let diff = newQuantity - existing.quantity
                if var med = try Medication.fetchOwned(db, userId: userId, id: existing.medicationId),
                   let previousCount = med.inventoryCount
                {
                    // diff > 0 (quantity went up) drops inventory; diff < 0
                    // raises it. The clamp at 0 only bites when diff is
                    // positive and exceeds previousCount.
                    let newCount = max(0, previousCount - diff)
                    med.inventoryCount = newCount
                    try med.update(db)

                    try InventoryEvent(
                        id: createId(),
                        userId: userId,
                        medicationId: existing.medicationId,
                        eventType: "dose_quantity_updated",
                        quantityChange: newCount - previousCount,
                        previousCount: previousCount,
                        newCount: newCount,
                        createdAt: now.timeIntervalSince1970
                    ).insert(db)
                }
            }

            if let changes = Self.computeChanges(before: existing, after: updated) {
                try AuditLog(
                    id: createId(),
                    userId: userId,
                    entityType: "dose_log",
                    entityId: doseId,
                    action: "update",
                    changes: changes,
                    createdAt: now.timeIntervalSince1970
                ).insert(db)
            }

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return updated
        }
    }

    // MARK: - Helpers

    private static func encodeSideEffects(_ value: [SideEffectEntry]?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Minimal JSON-diff over the user-facing fields `updateDose` can change
    /// (deliberately **excluding** `updatedAt`) — a plain key -> {from, to}
    /// object, `nil` when nothing changed, so the `update` audit row is gated
    /// on a real change. This is an INTENTIONAL divergence from the web's
    /// `computeChanges` (`audit.ts:19-28`), whose `Object.keys(after)` loop
    /// always sees the freshly-bumped `updatedAt` and therefore always writes
    /// an audit row. See `docs/PARITY-DIVERGENCES.md` entry #2.
    private static func computeChanges(before: DoseLog, after: DoseLog) -> String? {
        var changed: [String: [String: Any]] = [:]

        if before.quantity != after.quantity {
            changed["quantity"] = ["from": before.quantity, "to": after.quantity]
        }
        if before.takenAt != after.takenAt {
            changed["takenAt"] = ["from": before.takenAt, "to": after.takenAt]
        }
        if before.notes != after.notes {
            changed["notes"] = ["from": before.notes ?? NSNull(), "to": after.notes ?? NSNull()]
        }
        if before.sideEffects != after.sideEffects {
            changed["sideEffects"] = ["from": before.sideEffects ?? NSNull(), "to": after.sideEffects ?? NSNull()]
        }
        if before.status != after.status {
            changed["status"] = ["from": before.status, "to": after.status]
        }

        guard !changed.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
