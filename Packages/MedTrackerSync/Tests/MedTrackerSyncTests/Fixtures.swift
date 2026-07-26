import Foundation

enum Fixtures {
    // contract §2 — session login success
    static let loginSession = """
    {"token":"sess_abc","user":{"id":"u1","email":"a@b.com","name":"A","avatarUrl":null,
    "timezone":"Europe/London","twoFactorEnabled":false,"emailVerified":true}}
    """
    static let loginTotp = """
    {"challenge":"totp","preAuthToken":"pre_xyz"}
    """
    // contract §3 — a minimal delta sync response with one med (+schedule), one dose, one tombstone
    static let syncDelta = """
    {"epoch":2,"fullResync":false,"serverTime":"2026-07-26T10:00:00.000Z",
    "cursor":"2026-07-26T10:00:00.000Z",
    "medications":[{"id":"m1","userId":"u1","name":"Med","dosageAmount":"50","dosageUnit":"mg",
    "form":"tablet","category":"prescription","colour":"#112233","colourSecondary":null,
    "pattern":"solid","notes":null,"scheduleType":"scheduled","scheduleIntervalHours":null,
    "inventoryCount":30,"inventoryAlertThreshold":5,"sortOrder":0,"isArchived":false,
    "archivedAt":null,"startedAt":"2026-07-01T00:00:00.000Z","endedAt":null,
    "createdAt":"2026-07-01T00:00:00.000Z","updatedAt":"2026-07-26T09:00:00.000Z",
    "schedules":[{"id":"s1","medicationId":"m1","userId":"u1","scheduleKind":"interval",
    "timeOfDay":null,"intervalHours":"8","daysOfWeek":null,"sortOrder":0,
    "effectiveFrom":"2026-07-01T00:00:00.000Z","effectiveTo":null,
    "createdAt":"2026-07-01T00:00:00.000Z"}]}],
    "doseLogs":[{"id":"d1","userId":"u1","medicationId":"m1","quantity":1,
    "takenAt":"2026-07-26T08:00:00.000Z","loggedAt":"2026-07-26T08:00:00.000Z","notes":null,
    "sideEffects":null,"status":"taken","updatedAt":"2026-07-26T08:00:00.000Z"}],
    "inventoryEvents":[],"auditLogs":[],
    "tombstones":[{"id":"t1","userId":"u1","entityType":"dose_log","entityId":"dOld",
    "deletedAt":"2026-07-26T09:30:00.000Z"}],
    "preferences":null,"profile":null}
    """
}
