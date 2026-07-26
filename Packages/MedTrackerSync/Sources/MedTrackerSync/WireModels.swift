import Foundation

// MARK: - Auth

/// `SessionUser`, contract §2 — returned by all three auth endpoints and as
/// `SyncResponse.profile`.
public struct SessionUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var avatarUrl: String?
    public var timezone: String
    public var twoFactorEnabled: Bool
    public var emailVerified: Bool

    public init(
        id: String,
        email: String,
        name: String,
        avatarUrl: String?,
        timezone: String,
        twoFactorEnabled: Bool,
        emailVerified: Bool
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarUrl = avatarUrl
        self.timezone = timezone
        self.twoFactorEnabled = twoFactorEnabled
        self.emailVerified = emailVerified
    }
}

/// The result of `POST /auth/login` or `POST /auth/2fa` (contract §2): either a TOTP
/// challenge (`{challenge,preAuthToken}`) or a live session (`{token,user}`). Branches on
/// presence of the `challenge` key rather than a discriminant value, matching the wire shape.
public enum LoginOutcome: Codable, Equatable, Sendable {
    case totpChallenge(preAuthToken: String)
    case session(token: String, user: SessionUser)

    private enum CodingKeys: String, CodingKey {
        case challenge, preAuthToken, token, user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.challenge) {
            let preAuthToken = try container.decode(String.self, forKey: .preAuthToken)
            self = .totpChallenge(preAuthToken: preAuthToken)
        } else {
            let token = try container.decode(String.self, forKey: .token)
            let user = try container.decode(SessionUser.self, forKey: .user)
            self = .session(token: token, user: user)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .totpChallenge(preAuthToken):
            try container.encode("totp", forKey: .challenge)
            try container.encode(preAuthToken, forKey: .preAuthToken)
        case let .session(token, user):
            try container.encode(token, forKey: .token)
            try container.encode(user, forKey: .user)
        }
    }
}

// MARK: - Sync

/// `GET /sync` response (contract §3).
public struct SyncResponse: Codable, Equatable, Sendable {
    public var epoch: Int
    public var fullResync: Bool
    public var serverTime: String
    public var cursor: String
    public var medications: [WireMedication]
    public var doseLogs: [WireDoseLog]
    public var inventoryEvents: [WireInventoryEvent]
    public var auditLogs: [WireAuditLog]
    public var tombstones: [WireTombstone]
    public var preferences: WirePreferences?
    public var profile: SessionUser?

    public init(
        epoch: Int,
        fullResync: Bool,
        serverTime: String,
        cursor: String,
        medications: [WireMedication],
        doseLogs: [WireDoseLog],
        inventoryEvents: [WireInventoryEvent],
        auditLogs: [WireAuditLog],
        tombstones: [WireTombstone],
        preferences: WirePreferences?,
        profile: SessionUser?
    ) {
        self.epoch = epoch
        self.fullResync = fullResync
        self.serverTime = serverTime
        self.cursor = cursor
        self.medications = medications
        self.doseLogs = doseLogs
        self.inventoryEvents = inventoryEvents
        self.auditLogs = auditLogs
        self.tombstones = tombstones
        self.preferences = preferences
        self.profile = profile
    }
}

/// `SerializedMedication & { schedules: SerializedSchedule[] }` (contract §3). Dates stay
/// `String` (ISO-8601); numeric-as-string columns (`dosageAmount`, `scheduleIntervalHours`)
/// stay `String`/`String?` — do not parse to a numeric type here.
public struct WireMedication: Codable, Equatable, Sendable {
    public var id: String
    public var userId: String
    public var name: String
    public var dosageAmount: String
    public var dosageUnit: String
    public var form: String
    public var category: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: String
    public var notes: String?
    public var scheduleType: String
    public var scheduleIntervalHours: String?
    public var inventoryCount: Int?
    public var inventoryAlertThreshold: Int?
    public var sortOrder: Int
    public var isArchived: Bool
    public var archivedAt: String?
    public var startedAt: String
    public var endedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var schedules: [WireSchedule]

    public init(
        id: String,
        userId: String,
        name: String,
        dosageAmount: String,
        dosageUnit: String,
        form: String,
        category: String,
        colour: String,
        colourSecondary: String?,
        pattern: String,
        notes: String?,
        scheduleType: String,
        scheduleIntervalHours: String?,
        inventoryCount: Int?,
        inventoryAlertThreshold: Int?,
        sortOrder: Int,
        isArchived: Bool,
        archivedAt: String?,
        startedAt: String,
        endedAt: String?,
        createdAt: String,
        updatedAt: String,
        schedules: [WireSchedule]
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.dosageAmount = dosageAmount
        self.dosageUnit = dosageUnit
        self.form = form
        self.category = category
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.notes = notes
        self.scheduleType = scheduleType
        self.scheduleIntervalHours = scheduleIntervalHours
        self.inventoryCount = inventoryCount
        self.inventoryAlertThreshold = inventoryAlertThreshold
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schedules = schedules
    }
}

/// `SerializedSchedule` (contract §3). `intervalHours` is numeric-as-string, stays `String?`.
public struct WireSchedule: Codable, Equatable, Sendable {
    public var id: String
    public var medicationId: String
    public var userId: String
    public var scheduleKind: String
    public var timeOfDay: String?
    public var intervalHours: String?
    public var daysOfWeek: [Int]?
    public var sortOrder: Int
    public var effectiveFrom: String
    public var effectiveTo: String?
    public var createdAt: String

    public init(
        id: String,
        medicationId: String,
        userId: String,
        scheduleKind: String,
        timeOfDay: String?,
        intervalHours: String?,
        daysOfWeek: [Int]?,
        sortOrder: Int,
        effectiveFrom: String,
        effectiveTo: String?,
        createdAt: String
    ) {
        self.id = id
        self.medicationId = medicationId
        self.userId = userId
        self.scheduleKind = scheduleKind
        self.timeOfDay = timeOfDay
        self.intervalHours = intervalHours
        self.daysOfWeek = daysOfWeek
        self.sortOrder = sortOrder
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.createdAt = createdAt
    }
}

/// `SerializedDoseLog` (contract §3).
public struct WireDoseLog: Codable, Equatable, Sendable {
    public var id: String
    public var userId: String
    public var medicationId: String
    public var quantity: Int
    public var takenAt: String
    public var loggedAt: String
    public var notes: String?
    public var sideEffects: [WireSideEffect]?
    public var status: String
    public var updatedAt: String

    public init(
        id: String,
        userId: String,
        medicationId: String,
        quantity: Int,
        takenAt: String,
        loggedAt: String,
        notes: String?,
        sideEffects: [WireSideEffect]?,
        status: String,
        updatedAt: String
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.quantity = quantity
        self.takenAt = takenAt
        self.loggedAt = loggedAt
        self.notes = notes
        self.sideEffects = sideEffects
        self.status = status
        self.updatedAt = updatedAt
    }
}

/// Element of `SerializedDoseLog.sideEffects` (contract §3).
public struct WireSideEffect: Codable, Equatable, Sendable {
    public var name: String
    public var severity: String

    public init(name: String, severity: String) {
        self.name = name
        self.severity = severity
    }
}

/// `SerializedInventoryEvent` (contract §3).
public struct WireInventoryEvent: Codable, Equatable, Sendable {
    public var id: String
    public var userId: String
    public var medicationId: String
    public var eventType: String
    public var quantityChange: Int
    public var previousCount: Int?
    public var newCount: Int?
    public var note: String?
    public var createdAt: String

    public init(
        id: String,
        userId: String,
        medicationId: String,
        eventType: String,
        quantityChange: Int,
        previousCount: Int?,
        newCount: Int?,
        note: String?,
        createdAt: String
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.eventType = eventType
        self.quantityChange = quantityChange
        self.previousCount = previousCount
        self.newCount = newCount
        self.note = note
        self.createdAt = createdAt
    }
}

/// `SerializedAuditLog` (contract §3). `changes` is `unknown` on the wire — modeled as
/// arbitrary `JSONValue`.
public struct WireAuditLog: Codable, Equatable, Sendable {
    public var id: String
    public var userId: String
    public var entityType: String
    public var entityId: String
    public var action: String
    public var changes: JSONValue?
    public var createdAt: String

    public init(
        id: String,
        userId: String,
        entityType: String,
        entityId: String,
        action: String,
        changes: JSONValue?,
        createdAt: String
    ) {
        self.id = id
        self.userId = userId
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.changes = changes
        self.createdAt = createdAt
    }
}

/// `SerializedTombstone` (contract §3).
public struct WireTombstone: Codable, Equatable, Sendable {
    public var id: String
    public var userId: String
    public var entityType: String
    public var entityId: String
    public var deletedAt: String

    public init(
        id: String,
        userId: String,
        entityType: String,
        entityId: String,
        deletedAt: String
    ) {
        self.id = id
        self.userId = userId
        self.entityType = entityType
        self.entityId = entityId
        self.deletedAt = deletedAt
    }
}

/// `SerializedPreferences` (contract §3).
public struct WirePreferences: Codable, Equatable, Sendable {
    public var userId: String
    public var accentColor: String
    public var dateFormat: String
    public var timeFormat: String
    public var uiDensity: String
    public var reducedMotion: Bool
    public var overdueEmailReminders: Bool
    public var overduePushReminders: Bool
    public var lowInventoryEmailAlerts: Bool
    public var lowInventoryPushAlerts: Bool
    public var doseLogPageSize: Int
    public var heatmapPeriod: Int
    public var exportFormat: String
    public var updatedAt: String

    public init(
        userId: String,
        accentColor: String,
        dateFormat: String,
        timeFormat: String,
        uiDensity: String,
        reducedMotion: Bool,
        overdueEmailReminders: Bool,
        overduePushReminders: Bool,
        lowInventoryEmailAlerts: Bool,
        lowInventoryPushAlerts: Bool,
        doseLogPageSize: Int,
        heatmapPeriod: Int,
        exportFormat: String,
        updatedAt: String
    ) {
        self.userId = userId
        self.accentColor = accentColor
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.uiDensity = uiDensity
        self.reducedMotion = reducedMotion
        self.overdueEmailReminders = overdueEmailReminders
        self.overduePushReminders = overduePushReminders
        self.lowInventoryEmailAlerts = lowInventoryEmailAlerts
        self.lowInventoryPushAlerts = lowInventoryPushAlerts
        self.doseLogPageSize = doseLogPageSize
        self.heatmapPeriod = heatmapPeriod
        self.exportFormat = exportFormat
        self.updatedAt = updatedAt
    }
}

// MARK: - Commands

/// One entry of `POST /commands`'s `commands` array (contract §4).
public struct WireCommand: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var payload: JSONValue

    public init(id: String, type: String, payload: JSONValue) {
        self.id = id
        self.type = type
        self.payload = payload
    }
}

/// `POST /commands` request body (contract §4).
public struct CommandEnvelope: Codable, Equatable, Sendable {
    public var commands: [WireCommand]

    public init(commands: [WireCommand]) {
        self.commands = commands
    }
}

/// One entry of `POST /commands`'s response `results` array (contract §4).
public struct CommandResultDTO: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?

    public init(id: String, ok: Bool, result: JSONValue?, error: String?) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

/// `POST /commands` response body (contract §4).
public struct CommandsResponse: Codable, Equatable, Sendable {
    public var results: [CommandResultDTO]

    public init(results: [CommandResultDTO]) {
        self.results = results
    }
}
