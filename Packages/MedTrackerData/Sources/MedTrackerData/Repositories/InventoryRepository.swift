import Foundation
import GRDB
import MedTrackerCore

/// Errors surfaced by `InventoryRepository`. Ports the three error classes
/// from `inventory-events.ts:72-93`. Swift's `Int` has no fractional state,
/// so the TS `Number.isInteger(...)` half of each guard collapses away —
/// only the sign/zero checks remain meaningful here.
public enum InventoryRepositoryError: Error, Equatable {
    case medicationNotFound
    case invalidRefillQuantity
    case invalidAdjustment
}

/// Transactional inventory mutations + the `inventory_event` ledger. Ports
/// `src/lib/server/inventory-events.ts` (web app `medication-tracker`).
/// Each mutation is one `dbWriter.write { }` transaction: the medication's
/// `inventory_count` update and its `inventory_event` row commit or roll
/// back together.
public struct InventoryRepository {
    private let dbWriter: any DatabaseWriter

    #if DEBUG
        /// Test-only fault injection — see `DoseRepository.testFaultAfterMutation`
        /// for the contract. Never set outside `RepositoryTests.swift`.
        var testFaultAfterMutation: (() throws -> Void)?
    #endif

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public struct RefillResult: Equatable {
        public let previousCount: Int?
        public let newCount: Int
    }

    public struct AdjustResult: Equatable {
        public let previousCount: Int?
        public let newCount: Int
        public let quantityChange: Int
    }

    // MARK: - refillMedication

    /// Ports `refillMedication` (`inventory-events.ts:103-142`). `quantity`
    /// must be a positive integer or this throws
    /// `.invalidRefillQuantity` — validated up front, before the
    /// transaction opens, matching the TS ordering. `newCount = (previousCount
    /// ?? 0) + quantity`, so a refill on a medication with no inventory
    /// tracking (`inventoryCount == nil`) **seeds** tracking rather than
    /// erroring. Appends a `refill` event and bumps `updatedAt`. One
    /// transaction.
    @discardableResult
    public func refillMedication(
        userId: String,
        medicationId: String,
        quantity: Int,
        note: String? = nil,
        now: Date = Date()
    ) throws -> RefillResult {
        guard quantity > 0 else { throw InventoryRepositoryError.invalidRefillQuantity }

        return try dbWriter.write { db in
            guard var med = try Medication.fetchOwned(db, userId: userId, id: medicationId) else {
                throw InventoryRepositoryError.medicationNotFound
            }

            let previousCount = med.inventoryCount
            let newCount = (previousCount ?? 0) + quantity
            med.inventoryCount = newCount
            med.updatedAt = now.timeIntervalSince1970
            try med.update(db)

            try InventoryEvent(
                id: createId(),
                userId: userId,
                medicationId: medicationId,
                eventType: "refill",
                quantityChange: quantity,
                previousCount: previousCount,
                newCount: newCount,
                note: note,
                createdAt: now.timeIntervalSince1970
            ).insert(db)

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return RefillResult(previousCount: previousCount, newCount: newCount)
        }
    }

    // MARK: - adjustInventory

    /// Ports `adjustInventory` (`inventory-events.ts:156-198`). `newCount`
    /// must be a non-negative integer or this throws `.invalidAdjustment`
    /// — validated up front, before the transaction opens. A zero-change
    /// adjustment (`newCount == previousCount ?? 0`) is rejected as a
    /// no-op, also with `.invalidAdjustment`, but that check can only
    /// happen once the current count is known, so it happens inside the
    /// transaction after the medication is fetched (matching the TS, which
    /// also checks this post-fetch). The signed delta
    /// (`newCount - (previousCount ?? 0)`) is recorded so history reflects
    /// increase vs. decrease. One transaction.
    @discardableResult
    public func adjustInventory(
        userId: String,
        medicationId: String,
        newCount: Int,
        note: String? = nil,
        now: Date = Date()
    ) throws -> AdjustResult {
        guard newCount >= 0 else { throw InventoryRepositoryError.invalidAdjustment }

        return try dbWriter.write { db in
            guard var med = try Medication.fetchOwned(db, userId: userId, id: medicationId) else {
                throw InventoryRepositoryError.medicationNotFound
            }

            let previousCount = med.inventoryCount
            let quantityChange = newCount - (previousCount ?? 0)
            guard quantityChange != 0 else { throw InventoryRepositoryError.invalidAdjustment }

            med.inventoryCount = newCount
            med.updatedAt = now.timeIntervalSince1970
            try med.update(db)

            try InventoryEvent(
                id: createId(),
                userId: userId,
                medicationId: medicationId,
                eventType: "manual_adjustment",
                quantityChange: quantityChange,
                previousCount: previousCount,
                newCount: newCount,
                note: note,
                createdAt: now.timeIntervalSince1970
            ).insert(db)

            #if DEBUG
                try testFaultAfterMutation?()
            #endif

            return AdjustResult(previousCount: previousCount, newCount: newCount, quantityChange: quantityChange)
        }
    }
}
