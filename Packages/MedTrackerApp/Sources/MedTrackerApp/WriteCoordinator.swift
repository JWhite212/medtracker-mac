import Foundation
import GRDB
import MedTrackerCore

// `MedicationFields`/`MedicationScheduleInput` (Task 4, `MedTrackerData`, built in Swift 5
// language mode) predate this module's Swift 6 strict-concurrency adoption and aren't marked
// `Sendable`. `@preconcurrency` downgrades their Sendable-capture checks in the `@Sendable`
// `dbWriter.write` closures below to warnings — the standard bridge for consuming a
// not-yet-concurrency-audited module, and it touches only this file (`Packages/MedTrackerApp/`).
@preconcurrency import MedTrackerData
import MedTrackerSync

/// Client-side (optimistic/local) failures that roll the write transaction back.
/// Sync failures are never thrown here — the `OutboxEntry` stays durable for the
/// next drain; the server's own validation error surfaces later via the
/// Reconciler/Drainer (Task 13/14), not through this call.
public enum WriteError: Error, Equatable {
    /// `log_dose`/`edit_dose` quantity outside `1...10`.
    case invalidQuantity
    /// `refill` amount `<= 0`.
    case invalidRefillQuantity
    /// `adjust_inventory` `newCount < 0`, or `== current count` (no-op).
    case invalidAdjustment
}

// MARK: - Payload / lookup helpers (free functions — never capture `self`, so they
// stay usable inside the `@Sendable` closures `DatabaseWriter.write` requires)

/// A fresh formatter per call — `ISO8601DateFormatter` is a mutable Foundation
/// class, so a shared instance would be a cross-closure captured reference;
/// building one locally keeps every payload-building call self-contained.
private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func sideEffectsJSON(_ list: [SideEffectEntry]) -> JSONValue {
    .array(list.map { .object(["name": .string($0.name), "severity": .string($0.severity)]) })
}

private func encodeSideEffects(_ list: [SideEffectEntry]?) -> String? {
    guard let list, let data = try? JSONEncoder().encode(list) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Mirrors `MedicationQueries.swift`'s (internal, `MedTrackerData`-only)
/// `Medication.fetchOwned` load-and-guard predicate — re-implemented here
/// rather than exposed publicly, since Task 10's brief is scoped to
/// `Packages/MedTrackerApp/` only.
private func fetchOwnedMedication(_ db: Database, userId: String, id: String) throws -> Medication? {
    try Medication.filter(key: id).filter(Column("user_id") == userId).fetchOne(db)
}

private func medicationPayload(_ f: MedicationFields) -> JSONValue {
    var o: [String: JSONValue] = [
        "name": .string(f.name),
        "dosageAmount": .string(f.dosageAmount),
        "dosageUnit": .string(f.dosageUnit),
        "form": .string(f.form),
        "category": .string(f.category),
        "colour": .string(f.colour),
        "pattern": .string(f.pattern),
        "scheduleType": .string(f.scheduleType),
    ]
    if let cs = f.colourSecondary { o["colourSecondary"] = .string(cs) }
    if let n = f.notes { o["notes"] = .string(n) }
    if let sih = f.scheduleIntervalHours { o["scheduleIntervalHours"] = .string(sih) }
    if let ic = f.inventoryCount { o["inventoryCount"] = .number(Double(ic)) }
    if let at = f.inventoryAlertThreshold { o["inventoryAlertThreshold"] = .number(Double(at)) }
    return .object(o)
}

private func schedulePayload(_ s: MedicationScheduleInput) -> JSONValue {
    switch s.scheduleKind {
    case "interval":
        return .object([
            "scheduleKind": .string("interval"),
            "intervalHours": .number(Double(s.intervalHours ?? "0") ?? 0),
        ])
    case "fixed_time":
        var o: [String: JSONValue] = [
            "scheduleKind": .string("fixed_time"),
            "timeOfDay": .string(s.timeOfDay ?? ""),
        ]
        if let days = s.daysOfWeek { o["daysOfWeek"] = .array(days.map { .number(Double($0)) }) }
        return .object(o)
    default:
        return .object(["scheduleKind": .string("prn")])
    }
}

/// The optimistic-write layer (contract §4). Every method applies the minimal
/// STATE-only effect (`medication`/`dose_log`/`medication_schedule`) and enqueues
/// one `OutboxEntry` in the SAME GRDB transaction; a later `sync()` drains the
/// outbox and re-pulls canonical rows. Never writes `inventory_event`/`audit_log`
/// locally — those are server-owned and arrive via delta pull.
@MainActor public final class WriteCoordinator {
    private let dbWriter: any DatabaseWriter
    private let outbox: OutboxStore
    private let userId: String

    public init(dbWriter: any DatabaseWriter, outbox: OutboxStore, userId: String) {
        self.dbWriter = dbWriter
        self.outbox = outbox
        self.userId = userId
    }

    // MARK: - dose commands

    public func logDose(medicationId: String, quantity: Int, takenAt: Date?,
                        notes: String?, sideEffects: [SideEffectEntry]?) async throws
    {
        guard (1 ... 10).contains(quantity) else { throw WriteError.invalidQuantity }
        let now = Date()
        let nowEpoch = now.timeIntervalSince1970
        let takenDate = takenAt ?? now
        let doseId = createId()

        var payloadDict: [String: JSONValue] = [
            "medicationId": .string(medicationId),
            "quantity": .number(Double(quantity)),
        ]
        if takenAt != nil { payloadDict["takenAt"] = .string(isoString(takenDate)) }
        if let notes { payloadDict["notes"] = .string(notes) }
        if let sideEffects { payloadDict["sideEffects"] = sideEffectsJSON(sideEffects) }
        let payload = JSONValue.object(payloadDict)

        try await dbWriter.write { [userId, outbox, payload] db in
            try DoseLog(id: doseId, userId: userId, medicationId: medicationId, quantity: quantity,
                        takenAt: takenDate.timeIntervalSince1970, loggedAt: nowEpoch,
                        notes: notes, sideEffects: sideEffects, status: "taken",
                        updatedAt: nowEpoch).insert(db)
            if var med = try fetchOwnedMedication(db, userId: userId, id: medicationId),
               let prev = med.inventoryCount
            {
                med.inventoryCount = max(0, prev - quantity)
                med.updatedAt = nowEpoch
                try med.update(db)
            }
            try outbox.enqueue(db, type: "log_dose", payload: payload,
                               localEntityId: doseId, localEntityKind: .doseLog)
        }
    }

    public func skipDose(medicationId: String, slotExpectedTime: Date) async throws {
        let nowEpoch = Date().timeIntervalSince1970
        let doseId = createId()

        try await dbWriter.write { [userId, outbox] db in
            // No inventory change. The optimistic `takenAt` is provisional — the
            // server stamps its own skip time via `logSkippedDose`, and the
            // canonical row replaces this one on the next delta pull. The
            // command payload never carries `slotExpectedTime` (contract §4:
            // `skipDosePayload` is `{ medicationId }` only).
            try DoseLog(id: doseId, userId: userId, medicationId: medicationId, quantity: 1,
                        takenAt: slotExpectedTime.timeIntervalSince1970, loggedAt: nowEpoch,
                        status: "skipped", updatedAt: nowEpoch).insert(db)
            try outbox.enqueue(db, type: "skip_dose",
                               payload: .object(["medicationId": .string(medicationId)]),
                               localEntityId: doseId, localEntityKind: .doseLog)
        }
    }

    public func editDose(doseId: String, takenAt: Date?, quantity: Int?,
                         notes: String??, sideEffects: [SideEffectEntry]??) async throws
    {
        if let quantity, !(1 ... 10).contains(quantity) { throw WriteError.invalidQuantity }
        let nowEpoch = Date().timeIntervalSince1970

        var payloadDict: [String: JSONValue] = ["doseId": .string(doseId)]
        if let takenAt { payloadDict["takenAt"] = .string(isoString(takenAt)) }
        if let quantity { payloadDict["quantity"] = .number(Double(quantity)) }
        // Double-optional: `.some(nil)` ⇒ explicit `null` (clear); `.none` ⇒ omit (untouched).
        if case let .some(newNotes) = notes { payloadDict["notes"] = newNotes.map(JSONValue.string) ?? .null }
        if case let .some(newSE) = sideEffects { payloadDict["sideEffects"] = newSE.map(sideEffectsJSON) ?? .null }
        let payload = JSONValue.object(payloadDict)

        try await dbWriter.write { [userId, outbox, payload] db in
            guard var dose = try DoseLog.fetchOne(db, key: doseId) else { return }
            let oldQty = dose.quantity
            let wasTaken = dose.status == "taken"
            if let takenAt { dose.takenAt = takenAt.timeIntervalSince1970 }
            if let quantity { dose.quantity = quantity }
            if case let .some(newNotes) = notes { dose.notes = newNotes }
            if case let .some(newSE) = sideEffects { dose.sideEffects = encodeSideEffects(newSE) }
            dose.updatedAt = nowEpoch
            try dose.update(db)

            if wasTaken, let quantity, quantity != oldQty,
               var med = try fetchOwnedMedication(db, userId: userId, id: dose.medicationId),
               let prev = med.inventoryCount
            {
                med.inventoryCount = max(0, prev - (quantity - oldQty))
                med.updatedAt = nowEpoch
                try med.update(db)
            }
            try outbox.enqueue(db, type: "edit_dose", payload: payload)
        }
    }

    public func deleteDose(doseId: String) async throws {
        let nowEpoch = Date().timeIntervalSince1970

        try await dbWriter.write { [userId, outbox] db in
            guard let dose = try DoseLog.fetchOne(db, key: doseId) else { return }
            try dose.delete(db)
            if dose.status == "taken",
               var med = try fetchOwnedMedication(db, userId: userId, id: dose.medicationId),
               let prev = med.inventoryCount
            {
                med.inventoryCount = prev + dose.quantity // unclamped restore (intentionally asymmetric)
                med.updatedAt = nowEpoch
                try med.update(db)
            }
            try outbox.enqueue(db, type: "delete_dose", payload: .object(["doseId": .string(doseId)]))
        }
    }

    // MARK: - inventory commands

    public func refill(medicationId: String, amount: Int, note: String?) async throws {
        guard amount > 0 else { throw WriteError.invalidRefillQuantity }
        let nowEpoch = Date().timeIntervalSince1970

        var payloadDict: [String: JSONValue] = [
            "medicationId": .string(medicationId),
            "quantity": .number(Double(amount)), // `amount` → payload key `quantity` (contract §4)
        ]
        if let note { payloadDict["note"] = .string(note) }
        let payload = JSONValue.object(payloadDict)

        try await dbWriter.write { [userId, outbox, payload] db in
            guard var med = try fetchOwnedMedication(db, userId: userId, id: medicationId) else { return }
            med.inventoryCount = (med.inventoryCount ?? 0) + amount // seeds tracking when nil
            med.updatedAt = nowEpoch
            try med.update(db)
            try outbox.enqueue(db, type: "refill", payload: payload)
        }
    }

    public func adjustInventory(medicationId: String, newCount: Int, note: String?) async throws {
        guard newCount >= 0 else { throw WriteError.invalidAdjustment }
        let nowEpoch = Date().timeIntervalSince1970

        var payloadDict: [String: JSONValue] = [
            "medicationId": .string(medicationId),
            "newCount": .number(Double(newCount)),
        ]
        if let note { payloadDict["note"] = .string(note) }
        let payload = JSONValue.object(payloadDict)

        try await dbWriter.write { [userId, outbox, payload] db in
            guard var med = try fetchOwnedMedication(db, userId: userId, id: medicationId) else { return }
            guard med.inventoryCount != newCount else { throw WriteError.invalidAdjustment }
            med.inventoryCount = newCount
            med.updatedAt = nowEpoch
            try med.update(db)
            try outbox.enqueue(db, type: "adjust_inventory", payload: payload)
        }
    }

    // MARK: - medication commands

    @discardableResult
    public func upsertMedication(id existing: String?, fields: MedicationFields,
                                 schedules: [MedicationScheduleInput]) async throws -> String
    {
        let isCreate = existing == nil
        let medId = existing ?? createId()
        let now = Date()

        var payloadDict: [String: JSONValue] = [
            "medication": medicationPayload(fields),
            "schedules": .array(schedules.map(schedulePayload)),
        ]
        if let existing { payloadDict["id"] = .string(existing) } // present ⇒ update
        let payload = JSONValue.object(payloadDict)

        try await dbWriter.write { [userId, outbox, payload] db in
            // State-only upsert (delete-then-insert schedules, NO audit); trips the
            // 3-way discriminated-union CHECK on a malformed schedule row, rolling
            // this whole transaction (state effect + enqueue) back together.
            guard try StateMedicationWriter.upsert(db, userId: userId, id: medId, isCreate: isCreate,
                                                   fields: fields, schedules: schedules, now: now) != nil
            else { return } // update whose id isn't found/owned → no side effect, no enqueue
            try outbox.enqueue(db, type: "upsert_medication_with_schedules", payload: payload,
                               localEntityId: isCreate ? medId : nil,
                               localEntityKind: isCreate ? .medication : nil)
        }
        return medId
    }

    public func archive(medicationId: String) async throws {
        try await setArchived(medicationId, true)
    }

    public func unarchive(medicationId: String) async throws {
        try await setArchived(medicationId, false)
    }

    private func setArchived(_ medicationId: String, _ archived: Bool) async throws {
        let nowEpoch = Date().timeIntervalSince1970
        let type = archived ? "archive" : "unarchive"

        try await dbWriter.write { [userId, outbox] db in
            guard var med = try fetchOwnedMedication(db, userId: userId, id: medicationId) else { return }
            med.isArchived = archived
            med.archivedAt = archived ? nowEpoch : nil
            med.updatedAt = nowEpoch
            try med.update(db)
            try outbox.enqueue(db, type: type, payload: .object(["medicationId": .string(medicationId)]))
        }
    }

    public func reorder(orderedMedicationIds: [String]) async throws {
        let nowEpoch = Date().timeIntervalSince1970

        try await dbWriter.write { [userId, outbox] db in
            let meds = try Medication.fetchActive(db, userId: userId) // ordered by sort_order
            var byId = Dictionary(uniqueKeysWithValues: meds.map { ($0.id, $0) })
            var current = meds.map(\.id)

            func swap(_ a: String, _ b: String) throws {
                guard var ma = byId[a], var mb = byId[b] else { return }
                Swift.swap(&ma.sortOrder, &mb.sortOrder)
                ma.updatedAt = nowEpoch
                mb.updatedAt = nowEpoch
                try ma.update(db)
                try mb.update(db)
                byId[a] = ma
                byId[b] = mb
                // reorder is a PAIRWISE swap {medId1, medId2} (contract §4), never an ordered list
                try outbox.enqueue(db, type: "reorder",
                                   payload: .object(["medId1": .string(a), "medId2": .string(b)]))
            }

            // Bubble each wanted id to its target index via adjacent swaps.
            for targetIndex in orderedMedicationIds.indices {
                let wanted = orderedMedicationIds[targetIndex]
                guard let pos = current.firstIndex(of: wanted), pos > targetIndex else { continue }
                var i = pos
                while i > targetIndex {
                    try swap(current[i], current[i - 1])
                    current.swapAt(i, i - 1)
                    i -= 1
                }
            }
        }
    }
}
