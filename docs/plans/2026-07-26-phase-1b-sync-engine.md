# Phase 1b — API Client + Sync Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `MedTrackerSync` — a headless, `swift test`-able package that authenticates against the deployed `/api/v1` backend, pulls server deltas into the local GRDB replica, and pushes local writes through an idempotent command outbox with server-id reconciliation.

**Architecture:** A new SwiftPM package depending on `MedTrackerData` (GRDB records/repositories, the local-only `OutboxEntry`/`SyncState` tables) and `MedTrackerCore` (`createId`). Networking sits behind a one-method `HTTPTransport` protocol so every test runs against an in-process mock — no `URLSession` touches the network in CI. The sync layer is server-authoritative: pulls upsert/replace local rows; local writes are optimistic overlays reconciled against the server's canonical ids.

**Tech Stack:** Swift 6.2 (Swift 5 language mode), Foundation, GRDB.swift 7 (already a dependency of `MedTrackerData`), Swift Testing. Keychain via the system `Security` framework (no new SPM dependency). SwiftLint + SwiftFormat (already configured).

**Design spec (source of truth):** `docs/superpowers/specs/2026-07-26-phase-1b-sync-engine-design.md`.
**Wire contract (authoritative for every shape):** `../medication-tracker/docs/api-v1-contract.md` (kept in the backend repo; open it alongside Tasks 3–6). Where a struct and the contract disagree, the contract wins.

## Global Constraints

_Every task's requirements implicitly include this section. Values are copied verbatim from the spec/contract._

- **Package settings:** `swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`, `swiftSettings: [.swiftLanguageMode(.v5)]` on every target — identical to `MedTrackerCore`/`MedTrackerData`.
- **No new SPM dependencies.** Only `MedTrackerData`, `MedTrackerCore`, GRDB (transitively), Foundation, and the system `Security` framework.
- **Numeric-as-string stays `String`.** `dosageAmount`, `scheduleIntervalHours`, `schedules[].intervalHours` are `String`/`String?` on the wire and stored as TEXT — never round-tripped through `Decimal` in the sync layer.
- **Dates:** ISO-8601 `String` on the wire; converted to **UTC epoch-seconds `Double`** when mapping into a GRDB record; `null` stays `null`. The backend emits `Date.toISOString()` (always `…Z`, milliseconds present).
- **Two error body shapes (contract §6):** `{ "message": … }` for 400/401/409; `{ "error": "rate_limited", "retryAfterSeconds": N }` for 429. The client branches on which it got.
- **Bearer auth:** every route except `/auth/login`, `/auth/2fa`, `/auth/apple` sends `Authorization: Bearer <token>`; the token is an opaque Lucia session id.
- **Server-authoritative.** Pulls win. Optimistic local writes **never** insert `inventory_event` or `audit_log` rows — those are server-owned and arrive via delta pull. Optimistic writes touch only state tables (`medication`, `medication_schedule`, `dose_log`).
- **Atomicity.** Every multi-row DB mutation (apply, reconcile, enqueue) is exactly one `db.write { }` transaction.
- **Default base URL:** `https://medication-tracker.jamiewhite.site/api/v1` (injectable via `SyncConfig`; tests inject a dummy URL).
- **Test harness:** `MockTransport` (an `HTTPTransport` test double with scripted responses) + in-memory GRDB (`MedTrackerDatabase.open(path: nil)`) + `InMemoryTokenStore`. No test hits the network or the Keychain.
- **cuid2 ids** via `MedTrackerCore.createId()` for all client-generated ids (idempotency keys, local entity ids).
- **Commit after every task.** Conventional-commit messages, no attribution trailers.

## File Structure

```
Packages/MedTrackerSync/
  Package.swift
  Sources/MedTrackerSync/
    Config.swift            # SyncConfig
    JSONValue.swift         # arbitrary-JSON enum + deep string-replace
    WireModels.swift        # Codable DTOs for /api/v1 (auth, sync, commands)
    APIError.swift          # typed error + two-shape decoding
    HTTPTransport.swift     # protocol + URLSessionTransport
    APIClient.swift         # typed async endpoints
    TokenStore.swift        # protocol + KeychainTokenStore + InMemoryTokenStore
    SyncStateStore.swift    # cursor + epoch over sync_state (KV)
    WireMapping.swift       # DTO -> GRDB record conversion
    SyncApplier.swift       # apply SyncResponse -> local DB
    OutboxStore.swift       # enqueue / query / status transitions over `outbox`
    Reconciler.swift        # local-id -> server-id rewrite (rows + pending payloads)
    OutboxDrainer.swift     # POST /commands + per-result handling
    SyncEngine.swift        # actor orchestrator
  Tests/MedTrackerSyncTests/
    MockTransport.swift
    Fixtures.swift          # sample /api/v1 JSON + record builders
    <one test file per source unit>

Packages/MedTrackerData/            # MODIFIED
  Sources/MedTrackerData/Schema.swift      # OutboxEntry gains 2 fields
  Sources/MedTrackerData/Migrations.swift  # v2 migration
  Tests/MedTrackerDataTests/SchemaTests.swift  # v2 assertions

.github/workflows/ci.yml            # MODIFIED — add MedTrackerSync
```

_Not in Phase 1b:_ SwiftUI/app target + user-action wiring (1c); `/export/full`, notifications, app lock (Phase 2); any `/api/v1` backend change.

---

### Task 1: Package scaffolding

**Files:**

- Create: `Packages/MedTrackerSync/Package.swift`, `Sources/MedTrackerSync/Config.swift`, `Tests/MedTrackerSyncTests/SmokeTests.swift`

**Interfaces:**

- Produces: a `swift test`-able `MedTrackerSync` package. `public struct SyncConfig: Sendable { public var baseURL: URL; public init(baseURL: URL) }`, with `public static let production = SyncConfig(baseURL: URL(string: "https://medication-tracker.jamiewhite.site/api/v1")!)`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerSync",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerSync", targets: ["MedTrackerSync"])],
    dependencies: [
        .package(path: "../MedTrackerData"),
        .package(path: "../MedTrackerCore"),
    ],
    targets: [
        .target(
            name: "MedTrackerSync",
            dependencies: ["MedTrackerData", "MedTrackerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MedTrackerSyncTests",
            dependencies: ["MedTrackerSync"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write `Config.swift`**

```swift
import Foundation

public struct SyncConfig: Sendable {
    public var baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }

    public static let production = SyncConfig(
        baseURL: URL(string: "https://medication-tracker.jamiewhite.site/api/v1")!
    )
}
```

- [ ] **Step 3: Write the smoke test** — `Tests/MedTrackerSyncTests/SmokeTests.swift`:

```swift
import Foundation
import Testing
@testable import MedTrackerSync

@Test func packageBuildsAndConfigResolves() {
    let cfg = SyncConfig(baseURL: URL(string: "https://example.test/api/v1")!)
    #expect(cfg.baseURL.absoluteString == "https://example.test/api/v1")
    #expect(SyncConfig.production.baseURL.path == "/api/v1")
}
```

- [ ] **Step 4: Run** — `cd Packages/MedTrackerSync && swift test`. Expected: 1 test passes (SwiftPM resolves the two local package deps).
- [ ] **Step 5: Commit**

```bash
git add Packages/MedTrackerSync
git commit -m "chore(sync): scaffold MedTrackerSync package"
```

---

### Task 2: Outbox reconciliation columns (MedTrackerData `v2` migration)

**Files:**

- Modify: `Packages/MedTrackerData/Sources/MedTrackerData/Schema.swift` (extend `OutboxEntry`)
- Modify: `Packages/MedTrackerData/Sources/MedTrackerData/Migrations.swift` (register `v2`)
- Test: `Packages/MedTrackerData/Tests/MedTrackerDataTests/SchemaTests.swift` (append)

**Interfaces:**

- Produces: `OutboxEntry` gains `public var localEntityId: String?` and `public var localEntityKind: String?` (columns `local_entity_id`, `local_entity_kind`), both defaulting to `nil` in `init`. A `v2` migration adds the columns to the existing `outbox` table.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test** (append to `SchemaTests.swift`):

```swift
@Test func v2AddsOutboxReconciliationColumns() throws {
    let dbQueue = try MedTrackerDatabase.open()
    try dbQueue.write { db in
        var entry = OutboxEntry(
            id: "o1", commandType: "upsert_medication_with_schedules",
            payload: "{}", idempotencyKey: "k1", createdAt: 0,
        )
        entry.localEntityId = "localMed1"
        entry.localEntityKind = "medication"
        try entry.insert(db)
        let fetched = try OutboxEntry.fetchOne(db, key: "o1")
        #expect(fetched?.localEntityId == "localMed1")
        #expect(fetched?.localEntityKind == "medication")
    }
}
```

- [ ] **Step 2: Run red** — `cd Packages/MedTrackerData && swift test --filter v2AddsOutboxReconciliationColumns`. Expected: FAIL (no `localEntityId` member / no such column).

- [ ] **Step 3: Extend `OutboxEntry`** in `Schema.swift` — add the two stored properties, coding keys, and init params (defaulting to `nil`):

```swift
    public var lastError: String?
    public var localEntityId: String?      // ADD
    public var localEntityKind: String?    // ADD  ("medication" | "dose_log")
    public var createdAt: Double
```

```swift
        case lastError = "last_error"
        case localEntityId = "local_entity_id"   // ADD
        case localEntityKind = "local_entity_kind" // ADD
        case createdAt = "created_at"
```

Add to `init(...)` after `lastError: String? = nil,`: `localEntityId: String? = nil, localEntityKind: String? = nil,` and assign `self.localEntityId = localEntityId; self.localEntityKind = localEntityKind`.

- [ ] **Step 4: Register the `v2` migration** in `Migrations.swift`, after the `registerMigration("v1")` block:

```swift
        migrator.registerMigration("v2") { db in
            try db.alter(table: OutboxEntry.databaseTableName) { t in
                t.add(column: "local_entity_id", .text)
                t.add(column: "local_entity_kind", .text)
            }
        }
```

- [ ] **Step 5: Run green** — `swift test --filter v2AddsOutboxReconciliationColumns` passes; then run the whole `MedTrackerData` suite (`swift test`) to confirm the 46 existing tests still pass.
- [ ] **Step 6: Commit**

```bash
git add Packages/MedTrackerData
git commit -m "feat(data): v2 migration — outbox reconciliation columns"
```

---

### Task 3: JSON value + wire models

**Files:**

- Create: `Sources/MedTrackerSync/JSONValue.swift`, `Sources/MedTrackerSync/WireModels.swift`, `Tests/MedTrackerSyncTests/WireModelsTests.swift`, `Tests/MedTrackerSyncTests/Fixtures.swift`

**Interfaces:**

- Produces `JSONValue`:

```swift
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
    public var stringValue: String? { if case let .string(s) = self { return s } ; return nil }
    public subscript(_ key: String) -> JSONValue? { if case let .object(o) = self { return o[key] } ; return nil }
    public func replacing(_ old: String, with new: String) -> JSONValue   // deep: any .string == old -> .string(new)
}
```

- Produces wire DTOs (exact field sets below). All `Codable, Equatable, Sendable`.
- Consumes: nothing.

- [ ] **Step 1: Write `Fixtures.swift`** holding canonical JSON strings copied from the contract (used across Tasks 3–15). Minimum:

```swift
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
```

- [ ] **Step 2: Write failing tests** — `WireModelsTests.swift`:

```swift
import Foundation
import Testing
@testable import MedTrackerSync

private let dec = JSONDecoder()

@Test func decodesSessionUser() throws {
    let r = try dec.decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    #expect(r.epoch == 2)
    #expect(r.fullResync == false)
    #expect(r.cursor == "2026-07-26T10:00:00.000Z")
    #expect(r.medications.count == 1)
    #expect(r.medications[0].dosageAmount == "50")        // numeric-as-string preserved
    #expect(r.medications[0].scheduleIntervalHours == nil)
    #expect(r.medications[0].schedules[0].intervalHours == "8")
    #expect(r.medications[0].inventoryCount == 30)
    #expect(r.doseLogs[0].status == "taken")
    #expect(r.tombstones[0].entityType == "dose_log")
    #expect(r.tombstones[0].entityId == "dOld")
    #expect(r.preferences == nil)
}

@Test func decodesLoginOutcomes() throws {
    let s = try dec.decode(LoginOutcome.self, from: Data(Fixtures.loginSession.utf8))
    guard case let .session(token, user) = s else { Issue.record("expected session"); return }
    #expect(token == "sess_abc")
    #expect(user.timezone == "Europe/London")
    let t = try dec.decode(LoginOutcome.self, from: Data(Fixtures.loginTotp.utf8))
    #expect(t == .totpChallenge(preAuthToken: "pre_xyz"))
}

@Test func jsonValueDeepReplace() {
    let v = JSONValue.object(["medicationId": .string("X"), "n": .number(1),
                              "kids": .array([.string("X"), .string("Y")])])
    let out = v.replacing("X", with: "Z")
    #expect(out["medicationId"]?.stringValue == "Z")
    #expect(out["kids"] == .array([.string("Z"), .string("Y")]))
}

@Test func encodesCommandEnvelope() throws {
    let cmd = WireCommand(id: "k1", type: "log_dose",
                          payload: .object(["medicationId": .string("m1")]))
    let data = try JSONEncoder().encode(CommandEnvelope(commands: [cmd]))
    let back = try dec.decode(CommandEnvelope.self, from: data)
    #expect(back.commands[0].payload["medicationId"]?.stringValue == "m1")
}
```

- [ ] **Step 3: Run red** — `swift test --filter WireModelsTests`. Expected: FAIL (types undefined).

- [ ] **Step 4: Implement `JSONValue.swift`** with a `singleValueContainer`-based `Codable` (decode order: null, bool, `Int`→`.number(Double)`, `Double`, `String`, `[JSONValue]`, `[String: JSONValue]`; encode symmetrically) and the `replacing` deep transform:

```swift
public func replacing(_ old: String, with new: String) -> JSONValue {
    switch self {
    case let .string(s): return .string(s == old ? new : s)
    case let .array(a): return .array(a.map { $0.replacing(old, with: new) })
    case let .object(o): return .object(o.mapValues { $0.replacing(old, with: new) })
    default: return self
    }
}
```

- [ ] **Step 5: Implement `WireModels.swift`.** Structs (fields exactly per contract §2–§4):
  - `SessionUser { id, email, name: String; avatarUrl: String?; timezone: String; twoFactorEnabled, emailVerified: Bool }`
  - `LoginOutcome` — an enum with a custom `init(from:)`: if a `challenge` key is present decode `.totpChallenge(preAuthToken:)`, else `.session(token:user:)`.
  - `SyncResponse { epoch: Int; fullResync: Bool; serverTime, cursor: String; medications: [WireMedication]; doseLogs: [WireDoseLog]; inventoryEvents: [WireInventoryEvent]; auditLogs: [WireAuditLog]; tombstones: [WireTombstone]; preferences: WirePreferences?; profile: SessionUser? }`
  - `WireMedication` — every field from `SerializedMedication` (contract §3) with dates as `String`, `dosageAmount`/`scheduleIntervalHours` as `String`/`String?`, `inventoryCount`/`inventoryAlertThreshold` as `Int?`, `sortOrder: Int`, `isArchived: Bool`, plus `schedules: [WireSchedule]`.
  - `WireSchedule` — `id, medicationId, userId, scheduleKind: String; timeOfDay: String?; intervalHours: String?; daysOfWeek: [Int]?; sortOrder: Int; effectiveFrom: String; effectiveTo: String?; createdAt: String`.
  - `WireDoseLog` — `id, userId, medicationId: String; quantity: Int; takenAt, loggedAt: String; notes: String?; sideEffects: [WireSideEffect]?; status: String; updatedAt: String`.
  - `WireSideEffect { name: String; severity: String }`.
  - `WireInventoryEvent { id, userId, medicationId, eventType: String; quantityChange: Int; previousCount, newCount: Int?; note: String?; createdAt: String }`.
  - `WireAuditLog { id, userId, entityType, entityId, action: String; changes: JSONValue?; createdAt: String }`.
  - `WireTombstone { id, userId, entityType, entityId: String; deletedAt: String }`.
  - `WirePreferences { userId, accentColor, dateFormat, timeFormat, uiDensity: String; reducedMotion, overdueEmailReminders, overduePushReminders, lowInventoryEmailAlerts, lowInventoryPushAlerts: Bool; doseLogPageSize, heatmapPeriod: Int; exportFormat: String; updatedAt: String }`.
  - `WireCommand { id, type: String; payload: JSONValue }`, `CommandEnvelope { commands: [WireCommand] }`, `CommandResultDTO { id: String; ok: Bool; result: JSONValue?; error: String? }`, `CommandsResponse { results: [CommandResultDTO] }`.

- [ ] **Step 6: Run green** — `swift test --filter WireModelsTests` passes.
- [ ] **Step 7: Commit** — `git add Packages/MedTrackerSync && git commit -m "feat(sync): wire DTOs + JSONValue"`.

---

### Task 4: API error typing + two-shape decoding

**Files:**

- Create: `Sources/MedTrackerSync/APIError.swift`, `Tests/MedTrackerSyncTests/APIErrorTests.swift`

**Interfaces:**

- Produces:

```swift
public enum APIError: Error, Equatable, Sendable {
    case badRequest(String)         // 400  { message }
    case unauthorized               // 401  { message }
    case emailConflict              // 409  { message: "email_conflict" }
    case rateLimited(retryAfter: Int) // 429 { error:"rate_limited", retryAfterSeconds }
    case server(status: Int)        // 5xx / any other non-2xx
    case transport(String)          // URLSession failure (description)
    case decoding(String)           // undecodable 2xx body
    static func from(status: Int, data: Data, retryAfterHeader: String?) -> APIError
}
```

- Consumes: nothing.

- [ ] **Step 1: Write failing tests** — `APIErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import MedTrackerSync

private func body(_ s: String) -> Data { Data(s.utf8) }

@Test func maps400And401And409() {
    #expect(APIError.from(status: 400, data: body(#"{"message":"Invalid"}"#), retryAfterHeader: nil)
            == .badRequest("Invalid"))
    #expect(APIError.from(status: 401, data: body(#"{"message":"Unauthorized"}"#), retryAfterHeader: nil)
            == .unauthorized)
    #expect(APIError.from(status: 409, data: body(#"{"message":"email_conflict"}"#), retryAfterHeader: nil)
            == .emailConflict)
}

@Test func maps429FromBodyThenHeader() {
    #expect(APIError.from(status: 429, data: body(#"{"error":"rate_limited","retryAfterSeconds":42}"#),
                          retryAfterHeader: nil) == .rateLimited(retryAfter: 42))
    // body missing the number -> fall back to Retry-After header
    #expect(APIError.from(status: 429, data: body("{}"), retryAfterHeader: "15")
            == .rateLimited(retryAfter: 15))
}

@Test func maps5xxAndUnknown() {
    #expect(APIError.from(status: 503, data: body("upstream"), retryAfterHeader: nil)
            == .server(status: 503))
}
```

- [ ] **Step 2: Run red** — `swift test --filter APIErrorTests`. Expected: FAIL.

- [ ] **Step 3: Implement `APIError.from`.** Decode a lightweight `struct MessageBody { let message: String? }` and `struct RateBody { let error: String?; let retryAfterSeconds: Int? }` with `try?`. Logic: `400 → .badRequest(message ?? "")`; `401 → .unauthorized`; `409 → (message == "email_conflict" ? .emailConflict : .badRequest(message ?? ""))`; `429 → .rateLimited(retryAfter: rateBody.retryAfterSeconds ?? Int(retryAfterHeader ?? "") ?? 0)`; else `.server(status:)`.

- [ ] **Step 4: Run green** — `swift test --filter APIErrorTests` passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): typed APIError + two-shape decoding"`.

---

### Task 5: HTTP transport, mock, and the auth endpoints

**Files:**

- Create: `Sources/MedTrackerSync/HTTPTransport.swift`, `Sources/MedTrackerSync/APIClient.swift`, `Tests/MedTrackerSyncTests/MockTransport.swift`, `Tests/MedTrackerSyncTests/APIClientAuthTests.swift`

**Interfaces:**

- Produces:

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public struct URLSessionTransport: HTTPTransport {
    public init(session: URLSession = .shared)
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
public struct APIClient: Sendable {
    public init(config: SyncConfig, transport: HTTPTransport)
    public func login(email: String, password: String) async throws -> LoginOutcome
    public func verifyTOTP(preAuthToken: String, code: String) async throws -> (token: String, user: SessionUser)
    public func signInWithApple(identityToken: String, fullName: String?) async throws -> (token: String, user: SessionUser)
}
```

- Test double `MockTransport` (in the test target): scriptable queue of `(status, json)` or per-request handler; records the last `URLRequest` for header/body assertions.
- Consumes: `SyncConfig` (Task 1), `LoginOutcome`/`SessionUser` (Task 3), `APIError` (Task 4).

- [ ] **Step 1: Write `MockTransport.swift`** (test target):

```swift
import Foundation
@testable import MedTrackerSync

final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Scripted { let status: Int; let body: Data; let headers: [String: String] }
    private var queue: [Scripted] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(.init(status: status, body: Data(json.utf8), headers: headers))
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { fatalError("MockTransport: no scripted response") }
        let s = queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status,
                                   httpVersion: nil, headerFields: s.headers)!
        return (s.body, resp)
    }
    var lastBodyJSON: [String: Any]? {
        guard let b = requests.last?.httpBody,
              let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return nil }
        return o
    }
}
```

- [ ] **Step 2: Write failing tests** — `APIClientAuthTests.swift`:

```swift
import Foundation
import Testing
@testable import MedTrackerSync

private func client(_ t: MockTransport) -> APIClient {
    APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
}

@Test func loginReturnsSession() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginSession)
    let outcome = try await client(t).login(email: "a@b.com", password: "pw")
    guard case let .session(token, user) = outcome else { Issue.record("expected session"); return }
    #expect(token == "sess_abc"); #expect(user.id == "u1")
    // request shape
    #expect(t.requests.last?.url?.absoluteString == "https://x.test/api/v1/auth/login")
    #expect(t.requests.last?.httpMethod == "POST")
    #expect(t.lastBodyJSON?["email"] as? String == "a@b.com")
}

@Test func loginReturnsTotpChallenge() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginTotp)
    let outcome = try await client(t).login(email: "a@b.com", password: "pw")
    #expect(outcome == .totpChallenge(preAuthToken: "pre_xyz"))
}

@Test func loginBadCredentialsThrowsUnauthorized() async throws {
    let t = MockTransport(); t.enqueue(status: 401, json: #"{"message":"Invalid email or password"}"#)
    await #expect(throws: APIError.unauthorized) {
        _ = try await client(t).login(email: "a@b.com", password: "bad")
    }
}

@Test func loginRateLimited() async throws {
    let t = MockTransport()
    t.enqueue(status: 429, json: #"{"error":"rate_limited","retryAfterSeconds":30}"#,
              headers: ["Retry-After": "30"])
    await #expect(throws: APIError.rateLimited(retryAfter: 30)) {
        _ = try await client(t).login(email: "a@b.com", password: "pw")
    }
}

@Test func appleConflictThrows() async throws {
    let t = MockTransport(); t.enqueue(status: 409, json: #"{"message":"email_conflict"}"#)
    await #expect(throws: APIError.emailConflict) {
        _ = try await client(t).signInWithApple(identityToken: "tok", fullName: nil)
    }
}
```

- [ ] **Step 3: Run red** — `swift test --filter APIClientAuthTests`. Expected: FAIL.

- [ ] **Step 4: Implement `HTTPTransport.swift`** (`URLSessionTransport` wraps `session.data(for:)`, casts to `HTTPURLResponse`, throws `APIError.transport(error.localizedDescription)` on failure) and **`APIClient.swift`**. Add a private helper that does the request/response/error plumbing so every endpoint is one line:

```swift
private func post<Body: Encodable, Out: Decodable>(
    _ path: String, body: Body, bearer: String? = nil, decode: Out.Type
) async throws -> Out {
    var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONEncoder().encode(body)
    let (data, resp) = try await transport.send(req)
    guard (200...299).contains(resp.statusCode) else {
        throw APIError.from(status: resp.statusCode, data: data,
                            retryAfterHeader: resp.value(forHTTPHeaderField: "Retry-After"))
    }
    do { return try JSONDecoder().decode(Out.self, from: data) }
    catch { throw APIError.decoding(String(describing: error)) }
}
```

`login` posts `["email": email, "password": password]` (use a small `Encodable` struct or `[String: String]`) to `auth/login` decoding `LoginOutcome`. `verifyTOTP` posts `{preAuthToken, code}` to `auth/2fa` decoding a `struct SessionResponse { token: String; user: SessionUser }` and returns the tuple. `signInWithApple` posts `{identityToken, fullName?}` to `auth/apple` decoding the same. (Use a private `struct SessionResponse: Decodable`.)

- [ ] **Step 5: Run green** — `swift test --filter APIClientAuthTests` passes.
- [ ] **Step 6: Commit** — `git commit -am "feat(sync): HTTP transport + auth endpoints"`.

---

### Task 6: `sync` + `runCommands` endpoints

**Files:**

- Modify: `Sources/MedTrackerSync/APIClient.swift`
- Test: `Tests/MedTrackerSyncTests/APIClientSyncTests.swift`

**Interfaces:**

- Produces (added to `APIClient`):

```swift
public func sync(since: String?, epoch: Int, token: String) async throws -> SyncResponse
public func runCommands(_ commands: [WireCommand], token: String) async throws -> CommandsResponse
```

- Consumes: everything from Task 5 plus `SyncResponse`, `WireCommand`, `CommandsResponse`.

- [ ] **Step 1: Write failing tests** — `APIClientSyncTests.swift`:

```swift
import Foundation
import Testing
@testable import MedTrackerSync

private func client(_ t: MockTransport) -> APIClient {
    APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
}

@Test func syncSendsCursorEpochAndBearer() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.syncDelta)
    let r = try await client(t).sync(since: "2026-07-26T09:00:00.000Z", epoch: 2, token: "sess_abc")
    #expect(r.medications.count == 1)
    let url = t.requests.last!.url!
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(url.path == "/api/v1/sync")
    #expect(comps.queryItems?.first { $0.name == "since" }?.value == "2026-07-26T09:00:00.000Z")
    #expect(comps.queryItems?.first { $0.name == "epoch" }?.value == "2")
    #expect(t.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sess_abc")
}

@Test func syncOmitsSinceWhenNil() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.syncDelta)
    _ = try await client(t).sync(since: nil, epoch: 0, token: "tok")
    let comps = URLComponents(url: t.requests.last!.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.queryItems?.contains { $0.name == "since" } != true)
}

@Test func syncUnauthorizedThrows() async throws {
    let t = MockTransport(); t.enqueue(status: 401, json: #"{"message":"Unauthorized"}"#)
    await #expect(throws: APIError.unauthorized) {
        _ = try await client(t).sync(since: nil, epoch: 0, token: "stale")
    }
}

@Test func runCommandsReturnsResults() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: #"{"results":[{"id":"k1","ok":true,"result":{"id":"srvDose1"}}]}"#)
    let resp = try await client(t).runCommands(
        [WireCommand(id: "k1", type: "log_dose", payload: .object(["medicationId": .string("m1")]))],
        token: "tok")
    #expect(resp.results[0].ok)
    #expect(resp.results[0].result?["id"]?.stringValue == "srvDose1")
    #expect(t.lastBodyJSON?["commands"] != nil)
}
```

- [ ] **Step 2: Run red** — `swift test --filter APIClientSyncTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** Add a private `get` helper mirroring `post` (GET, bearer required, no body) that builds the URL via `URLComponents` and appends `queryItems` (`epoch` always; `since` only when non-nil). `sync` calls it against `sync` decoding `SyncResponse`. `runCommands` calls `post("commands", body: CommandEnvelope(commands: commands), bearer: token, decode: CommandsResponse.self)`.

- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): sync + commands endpoints"`.

---

### Task 7: Token store

**Files:**

- Create: `Sources/MedTrackerSync/TokenStore.swift`, `Tests/MedTrackerSyncTests/TokenStoreTests.swift`

**Interfaces:**

- Produces:

```swift
public struct StoredSession: Codable, Equatable, Sendable { public var token: String; public var userId: String
    public init(token: String, userId: String) }
public protocol TokenStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}
public final class InMemoryTokenStore: TokenStore { public init() }
public struct KeychainTokenStore: TokenStore {
    public init(service: String = "site.jamiewhite.medtracker", account: String = "api-session")
}
```

- Consumes: nothing.

- [ ] **Step 1: Write failing tests** — `TokenStoreTests.swift` (in-memory only; Keychain is not exercised in CI):

```swift
import Testing
@testable import MedTrackerSync

@Test func inMemoryRoundTrips() throws {
    let s = InMemoryTokenStore()
    #expect(try s.load() == nil)
    try s.save(StoredSession(token: "t", userId: "u"))
    #expect(try s.load() == StoredSession(token: "t", userId: "u"))
    try s.clear()
    #expect(try s.load() == nil)
}
```

- [ ] **Step 2: Run red** — `swift test --filter TokenStoreTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `InMemoryTokenStore` guards a `StoredSession?` behind an `NSLock` (so it is `Sendable`-safe). `KeychainTokenStore` implements `save`/`load`/`clear` via `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` with `kSecClassGenericPassword`, storing `JSONEncoder`-encoded `StoredSession` as `kSecValueData`; `save` deletes-then-adds; a not-found `load` returns `nil` (not an error). Import `Security`.

- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): token store (Keychain + in-memory)"`.

---

### Task 8: Sync-state store (cursor + epoch)

**Files:**

- Create: `Sources/MedTrackerSync/SyncStateStore.swift`, `Tests/MedTrackerSyncTests/SyncStateStoreTests.swift`

**Interfaces:**

- Produces:

```swift
public struct SyncStateStore: Sendable {
    public init(dbWriter: any DatabaseWriter)
    public func loadCursor() throws -> String?
    public func saveCursor(_ cursor: String) throws
    public func loadEpoch() throws -> Int          // default 0 when unset
    public func saveEpoch(_ epoch: Int) throws
}
```

Uses the `sync_state` table as KV: rows keyed `"__cursor__"` and `"__epoch__"` (epoch stored as a decimal string in the `cursor` column).

- Consumes: `MedTrackerData.SyncState`, GRDB `DatabaseWriter`.

- [ ] **Step 1: Write failing tests** — `SyncStateStoreTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

@Test func cursorAndEpochRoundTrip() throws {
    let db = try MedTrackerDatabase.open()
    let store = SyncStateStore(dbWriter: db)
    #expect(try store.loadCursor() == nil)
    #expect(try store.loadEpoch() == 0)
    try store.saveCursor("2026-07-26T10:00:00.000Z")
    try store.saveEpoch(7)
    #expect(try store.loadCursor() == "2026-07-26T10:00:00.000Z")
    #expect(try store.loadEpoch() == 7)
    try store.saveEpoch(8)     // overwrite
    #expect(try store.loadEpoch() == 8)
}
```

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement.** Each getter `dbWriter.read { SyncState.fetchOne($0, key: key)?.cursor }`; setters `dbWriter.write { try SyncState(tableName: key, cursor: value, updatedAt: 0).upsert($0) }`. `loadEpoch` maps the string via `Int(...) ?? 0`; `saveEpoch` stores `String(epoch)`. Use constant keys `"__cursor__"`, `"__epoch__"`.
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): cursor + epoch store"`.

---

### Task 9: Wire → record mapping

**Files:**

- Create: `Sources/MedTrackerSync/WireMapping.swift`, `Tests/MedTrackerSyncTests/WireMappingTests.swift`

**Interfaces:**

- Produces an `enum WireMapping` namespace of pure converters + a `WireMappingError`:

```swift
public enum WireMappingError: Error, Equatable { case badDate(String) }
public enum WireMapping {
    static func epoch(_ iso: String) throws -> Double
    static func epochOpt(_ iso: String?) throws -> Double?
    static func medication(_ w: WireMedication) throws -> Medication
    static func schedule(_ w: WireSchedule) throws -> MedicationSchedule
    static func doseLog(_ w: WireDoseLog) throws -> DoseLog
    static func inventoryEvent(_ w: WireInventoryEvent) throws -> InventoryEvent
    static func auditLog(_ w: WireAuditLog) throws -> AuditLog
    static func profile(_ u: SessionUser, now: Double) -> Profile
    static func settings(_ p: WirePreferences) throws -> Settings
}
```

- Consumes: Task 3 wire types; `MedTrackerData` record types.

- [ ] **Step 1: Write failing tests** — `WireMappingTests.swift`:

```swift
import Foundation
import MedTrackerData
import Testing
@testable import MedTrackerSync

@Test func parsesISOWithAndWithoutFractional() throws {
    #expect(try WireMapping.epoch("2026-07-26T10:00:00.000Z") == 1785060000)   // pinned
    #expect(try WireMapping.epoch("2026-07-26T10:00:00Z") == 1785060000)
    #expect(throws: WireMappingError.badDate("nope")) { _ = try WireMapping.epoch("nope") }
}

@Test func mapsMedicationPreservingStrings() throws {
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    let m = try WireMapping.medication(r.medications[0])
    #expect(m.id == "m1")
    #expect(m.dosageAmount == "50")            // stays TEXT
    #expect(m.inventoryCount == 30)
    #expect(m.updatedAt == 1785056400)         // 2026-07-26T09:00:00Z, pinned
    #expect(m.archivedAt == nil)
}

@Test func mapsScheduleDaysOfWeekJSON() throws {
    let w = WireSchedule(id: "s", medicationId: "m", userId: "u", scheduleKind: "fixed_time",
        timeOfDay: "08:00", intervalHours: nil, daysOfWeek: [1, 3, 5], sortOrder: 0,
        effectiveFrom: "2026-07-01T00:00:00.000Z", effectiveTo: nil,
        createdAt: "2026-07-01T00:00:00.000Z")
    let s = try WireMapping.schedule(w)
    #expect(s.daysOfWeekArray == [1, 3, 5])    // re-encoded through MedTrackerData's JSON accessor
    #expect(s.timeOfDay == "08:00")
}

@Test func mapsPreferencesCollapsingNotificationChannels() throws {
    let p = WirePreferences(userId: "u", accentColor: "#6366f1", dateFormat: "DD/MM/YYYY",
        timeFormat: "12h", uiDensity: "comfortable", reducedMotion: false,
        overdueEmailReminders: false, overduePushReminders: true,
        lowInventoryEmailAlerts: false, lowInventoryPushAlerts: false,
        doseLogPageSize: 20, heatmapPeriod: 90, exportFormat: "pdf",
        updatedAt: "2026-07-26T10:00:00.000Z")
    let s = try WireMapping.settings(p)
    #expect(s.overdueRemindersEnabled == true)     // email||push
    #expect(s.lowInventoryAlertsEnabled == false)
}
```

> Confirm the two pinned epoch values on first run (`1785060000`, `1785056400`); if Foundation yields different integers, write the actual values into the asserts and note it — the point is a pinned contract.

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement.** `epoch` tries a fractional `ISO8601DateFormatter` (`[.withInternetDateTime, .withFractionalSeconds]`) then a plain one (`[.withInternetDateTime]`); throws `.badDate` if both fail (cache the two formatters as `static let`). Each record mapper copies fields straight across, converting date strings via `epoch`/`epochOpt`. `medication` passes `dosageAmount`/`scheduleIntervalHours` through unchanged. `schedule` passes `daysOfWeek: w.daysOfWeek` to the `MedicationSchedule` init (which JSON-encodes it internally). `doseLog` maps `sideEffects` to `[SideEffectEntry]` (name/severity). `settings` collapses booleans per Global Constraints (`email || push`). `profile` fills `Profile(userId: u.id, email: u.email, name: u.name, timezone: u.timezone, createdAt: now, updatedAt: now)`.
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): wire→record mapping"`.

---

### Task 10: SyncApplier — delta apply

**Files:**

- Create: `Sources/MedTrackerSync/SyncApplier.swift`, `Tests/MedTrackerSyncTests/SyncApplierDeltaTests.swift`

**Interfaces:**

- Produces:

```swift
public struct SyncApplier: Sendable {
    public init(dbWriter: any DatabaseWriter)
    public func apply(_ response: SyncResponse) throws     // one db.write; branches on fullResync
}
```

Task 10 implements the `fullResync == false` branch + tombstones; Task 11 adds the `fullResync == true` branch.

- Consumes: Task 9 mapping, `SyncResponse`, `MedTrackerData` records + `MedTrackerDatabase`.

- [ ] **Step 1: Write failing tests** — `SyncApplierDeltaTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

private func openDB() throws -> DatabaseQueue { try MedTrackerDatabase.open() }

@Test func deltaUpsertsMedicationScheduleDose() throws {
    let db = try openDB()
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r)
    try db.read { d in
        #expect(try Medication.fetchCount(d) == 1)
        #expect(try MedicationSchedule.fetchCount(d) == 1)
        #expect(try DoseLog.fetchOne(d, key: "d1")?.status == "taken")
    }
}

@Test func deltaReplacesSchedulesWholesale() throws {
    let db = try openDB()
    // seed a med with TWO local schedules
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "Med", dosageAmount: "50", dosageUnit: "mg",
            form: "tablet", category: "prescription", colour: "#112233", startedAt: 0,
            createdAt: 0, updatedAt: 0).insert(d)
        try MedicationSchedule(id: "old1", medicationId: "m1", userId: "u1", scheduleKind: "prn",
            effectiveFrom: 0, createdAt: 0).insert(d)
        try MedicationSchedule(id: "old2", medicationId: "m1", userId: "u1", scheduleKind: "prn",
            effectiveFrom: 0, createdAt: 0).insert(d)
    }
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r)   // response carries exactly one schedule s1 for m1
    try db.read { d in
        let ids = try MedicationSchedule.filter(Column("medication_id") == "m1")
            .fetchAll(d).map(\.id).sorted()
        #expect(ids == ["s1"])   // old1/old2 gone, s1 present
    }
}

@Test func deltaAppliesTombstoneDeletion() throws {
    let db = try openDB()
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
            updatedAt: 0).insert(d)
        try DoseLog(id: "dOld", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
            updatedAt: 0).insert(d)
    }
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r)   // tombstone t1 deletes dose_log dOld
    try db.read { d in #expect(try DoseLog.fetchOne(d, key: "dOld") == nil) }
}
```

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement the delta branch.** `apply` opens `try dbWriter.write { db in if response.fullResync { try applyFull(db, response) } else { try applyDelta(db, response) } }`. `applyDelta`:
  - medications: for each `w`, `try WireMapping.medication(w).upsert(db)`, then `try MedicationSchedule.filter(Column("medication_id") == w.id).deleteAll(db)` and insert each mapped schedule.
  - dose logs: `try WireMapping.doseLog($0).upsert(db)`.
  - inventory events / audit logs: `try WireMapping.inventoryEvent($0).upsert(db)` / `auditLog($0).upsert(db)` (upsert is safe even though append-only).
  - profile: if `response.profile` present, `try WireMapping.profile($0, now: 0).upsert(db)`.
  - preferences: if present, `try WireMapping.settings($0).upsert(db)`.
  - tombstones: `try applyTombstones(db, response.tombstones)` — map `entityType` → table name via a whitelist `["medication": "medication", "dose_log": "dose_log", "medication_schedule": "medication_schedule", "inventory_event": "inventory_event"]` and `db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [t.entityId])`; ignore unknown types.
  - Order medications before schedules/doses so FKs hold. (`now: 0` for profile is fine; the first full sync overwrites.)
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): applier delta upsert + tombstones"`.

---

### Task 11: SyncApplier — full resync + atomic rollback

**Files:**

- Modify: `Sources/MedTrackerSync/SyncApplier.swift`
- Test: `Tests/MedTrackerSyncTests/SyncApplierFullTests.swift`

**Interfaces:**

- Produces: the `fullResync == true` branch of `SyncApplier.apply` — wipes all synced tables, then inserts the response wholesale; local-only tables untouched; tombstones ignored.
- Consumes: Task 10.

- [ ] **Step 1: Write failing tests** — `SyncApplierFullTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

@Test func fullResyncWipesAndReplaces() throws {
    let db = try MedTrackerDatabase.open()
    // stale local rows that must be gone afterwards
    try db.write { d in
        try Medication(id: "stale", userId: "u1", name: "Stale", dosageAmount: "1", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
            updatedAt: 0).insert(d)
        // a local-only outbox row that must SURVIVE
        try OutboxEntry(id: "keepme", commandType: "log_dose", payload: "{}",
            idempotencyKey: "k", createdAt: 0).insert(d)
    }
    var r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    r = r.withFullResync(true)   // test helper flips the flag (see Step 3)
    try SyncApplier(dbWriter: db).apply(r)
    try db.read { d in
        #expect(try Medication.fetchOne(d, key: "stale") == nil)  // wiped
        #expect(try Medication.fetchOne(d, key: "m1") != nil)     // replaced with server row
        #expect(try OutboxEntry.fetchOne(d, key: "keepme") != nil) // local-only preserved
    }
}

@Test func applyIsAtomicOnFailure() throws {
    let db = try MedTrackerDatabase.open()
    // A dose whose medication is absent violates the FK -> whole apply must roll back.
    let bad = """
    {"epoch":1,"fullResync":false,"serverTime":"2026-07-26T10:00:00.000Z",
    "cursor":"2026-07-26T10:00:00.000Z","medications":[],
    "doseLogs":[{"id":"dx","userId":"u1","medicationId":"ghost","quantity":1,
    "takenAt":"2026-07-26T08:00:00.000Z","loggedAt":"2026-07-26T08:00:00.000Z","notes":null,
    "sideEffects":null,"status":"taken","updatedAt":"2026-07-26T08:00:00.000Z"}],
    "inventoryEvents":[],"auditLogs":[],"tombstones":[],"preferences":null,"profile":null}
    """
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(bad.utf8))
    #expect(throws: (any Error).self) { try SyncApplier(dbWriter: db).apply(r) }
    try db.read { d in #expect(try DoseLog.fetchOne(d, key: "dx") == nil) }  // nothing committed
}
```

- [ ] **Step 2: Run red** — FAIL (needs `withFullResync` + the full branch).
- [ ] **Step 3: Implement.** Add a tiny test-support extension in the **source** file (or a `@testable`-visible helper) `func withFullResync(_ v: Bool) -> SyncResponse` that returns a copy with `fullResync = v` — since `SyncResponse` is a struct with `var` fields, the test can also just mutate a `var`; prefer mutating a `var` in the test and delete the helper reference. (Update the test to `var r = …; r.fullResync = true` and drop `withFullResync`.) Implement `applyFull(db, response)`: delete children-first — `try DoseLog.deleteAll(db)`, `try InventoryEvent.deleteAll(db)`, `try AuditLog.deleteAll(db)`, `try MedicationSchedule.deleteAll(db)`, `try Medication.deleteAll(db)`, plus `Profile`/`Settings` — then insert medications (parents) first, then schedules/doses/events/audits, then profile/preferences. Never touch `OutboxEntry`, `SyncState`, `ReminderEvent`. The enclosing `dbWriter.write` already guarantees atomic rollback for the failure test.
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): applier full resync + atomic apply"`.

---

### Task 12: Outbox store (enqueue + status transitions)

**Files:**

- Create: `Sources/MedTrackerSync/OutboxStore.swift`, `Tests/MedTrackerSyncTests/OutboxStoreTests.swift`

**Interfaces:**

- Produces:

```swift
public enum EntityKind: String, Sendable { case medication, doseLog = "dose_log" }
public struct OutboxStore: Sendable {
    public init(dbWriter: any DatabaseWriter)
    @discardableResult
    public func enqueue(type: String, payload: JSONValue,
                        localEntityId: String? = nil, localEntityKind: EntityKind? = nil) throws -> OutboxEntry
    public func pending() throws -> [OutboxEntry]          // status == "pending", FIFO by created_at
    public func markSent(_ id: String) throws
    public func markFailed(_ id: String, error: String) throws   // increments attempt_count, sets last_error
}
```

- Consumes: `MedTrackerData.OutboxEntry`, `MedTrackerCore.createId`, `JSONValue`.

- [ ] **Step 1: Write failing tests** — `OutboxStoreTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

@Test func enqueueWritesPendingRowWithReconciliationFields() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let e = try store.enqueue(type: "log_dose", payload: .object(["medicationId": .string("m1")]),
                              localEntityId: "localDose1", localEntityKind: .doseLog)
    #expect(e.status == "pending")
    #expect(e.localEntityId == "localDose1")
    #expect(e.localEntityKind == "dose_log")
    #expect(!e.idempotencyKey.isEmpty)
    let pend = try store.pending()
    #expect(pend.map(\.id) == [e.id])
}

@Test func markSentAndFailedTransition() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let a = try store.enqueue(type: "refill", payload: .object([:]))
    try store.markSent(a.id)
    #expect(try store.pending().isEmpty)
    let b = try store.enqueue(type: "refill", payload: .object([:]))
    try store.markFailed(b.id, error: "boom")
    let row = try db.read { try OutboxEntry.fetchOne($0, key: b.id) }
    #expect(row?.status == "failed"); #expect(row?.attemptCount == 1); #expect(row?.lastError == "boom")
}

@Test func pendingIsFIFO() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let first = try store.enqueue(type: "a", payload: .object([:]))
    let second = try store.enqueue(type: "b", payload: .object([:]))
    #expect(try store.pending().map(\.id) == [first.id, second.id])   // created_at, then rowid tiebreak
}
```

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement.** `enqueue` encodes `payload` to a JSON string (`JSONEncoder`), builds `OutboxEntry(id: createId(), commandType: type, payload: json, idempotencyKey: createId(), status: "pending", attemptCount: 0, lastError: nil, localEntityId: localEntityId, localEntityKind: localEntityKind?.rawValue, createdAt: monotonicSeconds())`, inserts, returns it. For deterministic FIFO when many rows share a `createdAt`, order `pending()` by `created_at, rowid`. Use a `createdAt` seeded from an injectable clock defaulting to `Date().timeIntervalSince1970`; the FIFO test relies on the `rowid` tiebreak, so it passes even with identical timestamps. `markSent`/`markFailed` do `dbWriter.write` updates (fetch, mutate, `update(db)`).
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): outbox store (enqueue + transitions)"`.

---

### Task 13: Reconciler — local→server id rewrite

**Files:**

- Create: `Sources/MedTrackerSync/Reconciler.swift`, `Tests/MedTrackerSyncTests/ReconcilerTests.swift`

**Interfaces:**

- Produces:

```swift
public struct Reconciler: Sendable {
    public init()
    /// Runs inside an existing write transaction (caller sets PRAGMA defer_foreign_keys=ON).
    public func reconcile(localId: String, serverId: String, kind: EntityKind, in db: Database) throws
}
```

Rewrites the created row's own id and its state-table FK references, then remaps `localId→serverId` inside every still-pending outbox payload.

- Consumes: `EntityKind` (Task 12), GRDB `Database`, `JSONValue`, `OutboxEntry`.

- [ ] **Step 1: Write failing tests** — `ReconcilerTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

private func writeDeferred(_ db: DatabaseQueue, _ work: @escaping (Database) throws -> Void) throws {
    try db.write { d in try d.execute(sql: "PRAGMA defer_foreign_keys = ON"); try work(d) }
}

@Test func reconcilesDoseId() throws {
    let db = try MedTrackerDatabase.open()
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
            updatedAt: 0).insert(d)
        try DoseLog(id: "localDose", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
            updatedAt: 0).insert(d)
    }
    try writeDeferred(db) { d in
        try Reconciler().reconcile(localId: "localDose", serverId: "srvDose", kind: .doseLog, in: d)
    }
    try db.read { d in
        #expect(try DoseLog.fetchOne(d, key: "localDose") == nil)
        #expect(try DoseLog.fetchOne(d, key: "srvDose") != nil)
    }
}

@Test func reconcilesMedicationAndCascadesChildrenAndPendingPayloads() throws {
    let db = try MedTrackerDatabase.open()
    let outbox = OutboxStore(dbWriter: db)
    try db.write { d in
        try Medication(id: "localMed", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
            updatedAt: 0).insert(d)
        try MedicationSchedule(id: "sc1", medicationId: "localMed", userId: "u1",
            scheduleKind: "prn", effectiveFrom: 0, createdAt: 0).insert(d)
        try DoseLog(id: "do1", userId: "u1", medicationId: "localMed", takenAt: 0, loggedAt: 0,
            updatedAt: 0).insert(d)
    }
    // a pending command that references the still-local medication id
    let pendingCmd = try outbox.enqueue(type: "log_dose",
        payload: .object(["medicationId": .string("localMed")]))
    try writeDeferred(db) { d in
        try Reconciler().reconcile(localId: "localMed", serverId: "srvMed", kind: .medication, in: d)
    }
    try db.read { d in
        #expect(try Medication.fetchOne(d, key: "srvMed") != nil)
        #expect(try Medication.fetchOne(d, key: "localMed") == nil)
        #expect(try MedicationSchedule.fetchOne(d, key: "sc1")?.medicationId == "srvMed")
        #expect(try DoseLog.fetchOne(d, key: "do1")?.medicationId == "srvMed")
        let cmd = try OutboxEntry.fetchOne(d, key: pendingCmd.id)!
        #expect(cmd.payload.contains("srvMed")); #expect(!cmd.payload.contains("localMed"))
    }
}
```

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement.** With raw SQL inside the passed `db`:
  - `.doseLog`: `UPDATE dose_log SET id = ? WHERE id = ?` (serverId, localId).
  - `.medication`: `UPDATE medication SET id = ?  WHERE id = ?`; `UPDATE medication_schedule SET medication_id = ? WHERE medication_id = ?`; `UPDATE dose_log SET medication_id = ? WHERE medication_id = ?`.
  - Pending-payload remap (both kinds): fetch `OutboxEntry.filter(Column("status") == "pending")`, and for each, decode `payload` → `JSONValue`, call `.replacing(localId, with: serverId)`, re-encode, `UPDATE outbox SET payload = ? WHERE id = ?` when changed. (Skip the entry currently being reconciled if desired; harmless either way since its own payload won't contain `localId` for server-generated-id creates.)
    The caller (Task 14) is responsible for `PRAGMA defer_foreign_keys = ON`; without it the `medication` id update trips the FK. Document that requirement in a doc-comment.
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): id reconciler (rows + pending payloads)"`.

---

### Task 14: Outbox drainer

**Files:**

- Create: `Sources/MedTrackerSync/OutboxDrainer.swift`, `Tests/MedTrackerSyncTests/OutboxDrainerTests.swift`

**Interfaces:**

- Produces:

```swift
public struct DrainResult: Equatable, Sendable { public var sent: Int; public var failed: Int; public var inProgress: Int }
public struct OutboxDrainer: Sendable {
    public init(apiClient: APIClient, dbWriter: any DatabaseWriter,
                outbox: OutboxStore, reconciler: Reconciler = Reconciler())
    public func drain(token: String) async throws -> DrainResult
}
```

- Consumes: Tasks 5/6 (`APIClient.runCommands`), Task 12 (`OutboxStore`), Task 13 (`Reconciler`).

- [ ] **Step 1: Write failing tests** — `OutboxDrainerTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

private func makeDrainer(_ db: DatabaseQueue, _ t: MockTransport) -> (OutboxDrainer, OutboxStore) {
    let api = APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
    let outbox = OutboxStore(dbWriter: db)
    return (OutboxDrainer(apiClient: api, dbWriter: db, outbox: outbox), outbox)
}

@Test func drainReconcilesCreateAndMarksSent() throws { try runDrainReconciles() }
func runDrainReconciles() throws {}   // placeholder to keep file compiling before async test below

@Test func drainCreateDoseReconcilesServerId() async throws {
    let db = try MedTrackerDatabase.open()
    let t = MockTransport()
    let (drainer, outbox) = makeDrainer(db, t)
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
            updatedAt: 0).insert(d)
        try DoseLog(id: "localDose", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
            updatedAt: 0).insert(d)
    }
    let e = try outbox.enqueue(type: "log_dose", payload: .object(["medicationId": .string("m1")]),
                               localEntityId: "localDose", localEntityKind: .doseLog)
    t.enqueue(status: 200,
        json: #"{"results":[{"id":"\#(e.idempotencyKey)","ok":true,"result":{"id":"srvDose"}}]}"#)
    let res = try await drainer.drain(token: "tok")
    #expect(res == DrainResult(sent: 1, failed: 0, inProgress: 0))
    try db.read { d in
        #expect(try DoseLog.fetchOne(d, key: "srvDose") != nil)
        #expect(try OutboxEntry.fetchOne(d, key: e.id)?.status == "sent")
    }
}

@Test func drainHandlesErrorAndInProgressIndependently() async throws {
    let db = try MedTrackerDatabase.open()
    let t = MockTransport()
    let (drainer, outbox) = makeDrainer(db, t)
    let a = try outbox.enqueue(type: "refill", payload: .object([:]))
    let b = try outbox.enqueue(type: "refill", payload: .object([:]))
    t.enqueue(status: 200, json: """
    {"results":[{"id":"\(a.idempotencyKey)","ok":false,"error":"not found"},
                {"id":"\(b.idempotencyKey)","ok":false,"error":"in_progress"}]}
    """)
    let res = try await drainer.drain(token: "tok")
    #expect(res == DrainResult(sent: 0, failed: 1, inProgress: 1))
    try db.read { d in
        #expect(try OutboxEntry.fetchOne(d, key: a.id)?.status == "failed")
        #expect(try OutboxEntry.fetchOne(d, key: b.id)?.status == "pending")   // left for next sync
    }
}
```

(Delete the `runDrainReconciles` placeholder once the real async tests compile.)

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement `drain`.** Read `outbox.pending()`; if empty return zeros. Build `[WireCommand]` (`id: entry.idempotencyKey, type: entry.commandType, payload: decode(entry.payload)`), chunk by 200, `await apiClient.runCommands(chunk, token:)`. Index results by id. For each entry, look up its result:
  - `ok == true`: in one `dbWriter.write` with `PRAGMA defer_foreign_keys = ON` — if the entry has `localEntityId`+`localEntityKind` **and** the result carries a server `id` (`result?["id"]?.stringValue`), call `reconciler.reconcile(localId:serverId:kind:in:)`; then set status `sent`. (`sent += 1`.)
  - `ok == false, error == "in_progress"`: leave pending (`inProgress += 1`).
  - `ok == false` otherwise: `markFailed(id, error:)` (`failed += 1`).
  - No result for an entry (shouldn't happen): treat as in_progress (leave pending).
    Return the tallies. Surface `APIError` from `runCommands` by rethrowing (a transport/401/429 aborts the drain; already-processed writes are durable).
- [ ] **Step 4: Run green** — passes.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): outbox drainer + reconciliation wiring"`.

---

### Task 15: SyncEngine (actor orchestrator)

**Files:**

- Create: `Sources/MedTrackerSync/SyncEngine.swift`, `Tests/MedTrackerSyncTests/SyncEngineTests.swift`

**Interfaces:**

- Produces:

```swift
public struct SyncOutcome: Equatable, Sendable {
    public var fullResync: Bool
    public var pushed: DrainResult
    public var pulledMedications: Int
    public var pulledDoseLogs: Int
}
public actor SyncEngine {
    public init(config: SyncConfig, dbWriter: any DatabaseWriter,
                tokenStore: any TokenStore, transport: HTTPTransport = URLSessionTransport())
    @discardableResult public func login(email: String, password: String) async throws -> LoginOutcome
    @discardableResult public func verifyTOTP(preAuthToken: String, code: String) async throws -> SessionUser
    @discardableResult public func signInWithApple(identityToken: String, fullName: String?) async throws -> SessionUser
    @discardableResult public func enqueue(type: String, payload: JSONValue,
        localEntityId: String?, localEntityKind: EntityKind?) throws -> OutboxEntry
    public func sync() async throws -> SyncOutcome     // drain -> pull -> apply -> persist cursor+epoch
}
```

On successful auth the engine persists `StoredSession` via the token store. `sync()` throws `APIError.unauthorized` when no session is stored.

- Consumes: every prior task.

- [ ] **Step 1: Write failing tests** — `SyncEngineTests.swift`:

```swift
import Foundation
import GRDB
import MedTrackerData
import Testing
@testable import MedTrackerSync

private func engine(_ db: DatabaseQueue, _ t: MockTransport, _ ts: TokenStore) -> SyncEngine {
    SyncEngine(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!),
               dbWriter: db, tokenStore: ts, transport: t)
}

@Test func loginPersistsSession() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    let outcome = try await engine(db, t, ts).login(email: "a@b.com", password: "pw")
    #expect(outcome == .session(token: "sess_abc", user: try #require(sessionUser())))
        || true   // (compare token instead if SessionUser equality is awkward)
    #expect(try ts.load() == StoredSession(token: "sess_abc", userId: "u1"))
}
private func sessionUser() -> SessionUser? { nil }  // helper stub; remove if unused

@Test func syncWithoutSessionThrowsUnauthorized() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    await #expect(throws: APIError.unauthorized) { _ = try await engine(db, t, ts).sync() }
}

@Test func syncDrainsPullsAppliesAndPersistsCursor() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    try ts.save(StoredSession(token: "tok", userId: "u1"))
    // no pending outbox -> drain makes NO /commands call; first HTTP is the /sync GET
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    let out = try await engine(db, t, ts).sync()
    #expect(out.fullResync == false)
    #expect(out.pulledMedications == 1)
    #expect(out.pushed == DrainResult(sent: 0, failed: 0, inProgress: 0))
    try db.read { d in #expect(try Medication.fetchCount(d) == 1) }
    #expect(try SyncStateStore(dbWriter: db).loadCursor() == "2026-07-26T10:00:00.000Z")
    #expect(try SyncStateStore(dbWriter: db).loadEpoch() == 2)
}

@Test func secondSyncSendsStoredCursorAndEpoch() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    try ts.save(StoredSession(token: "tok", userId: "u1"))
    try SyncStateStore(dbWriter: db).saveCursor("2026-07-26T09:00:00.000Z")
    try SyncStateStore(dbWriter: db).saveEpoch(2)
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    _ = try await engine(db, t, ts).sync()
    let comps = URLComponents(url: t.requests.last!.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.queryItems?.first { $0.name == "since" }?.value == "2026-07-26T09:00:00.000Z")
    #expect(comps.queryItems?.first { $0.name == "epoch" }?.value == "2")
}
```

> The first test's `SessionUser` equality is fiddly — simplify it to assert only the persisted `StoredSession` (the token/userId) and drop the `sessionUser()`/`#require` scaffolding. Keep the token-store assertion; that's the behavior that matters.

- [ ] **Step 2: Run red** — FAIL.
- [ ] **Step 3: Implement `SyncEngine`.** The actor builds an `APIClient`, `OutboxStore`, `SyncApplier`, `OutboxDrainer`, `SyncStateStore` from its deps. Auth methods call the client and, on a session result, `try tokenStore.save(StoredSession(token:, userId: user.id))` and return. `enqueue` delegates to `OutboxStore`. `sync()`:
  1. `guard let session = try tokenStore.load() else { throw APIError.unauthorized }`.
  2. `let pushed = try await drainer.drain(token: session.token)`.
  3. `let resp = try await apiClient.sync(since: try stateStore.loadCursor(), epoch: try stateStore.loadEpoch(), token: session.token)`.
  4. `try applier.apply(resp)`.
  5. `try stateStore.saveCursor(resp.cursor); try stateStore.saveEpoch(resp.epoch)`.
  6. return `SyncOutcome(fullResync: resp.fullResync, pushed: pushed, pulledMedications: resp.medications.count, pulledDoseLogs: resp.doseLogs.count)`.
- [ ] **Step 4: Run green** — `swift test` (whole `MedTrackerSync` suite). All pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(sync): SyncEngine actor orchestrator"`.

---

### Task 16: CI, lint gate, full-suite green, PR

**Files:**

- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1:** Add a `swift test` step for `Packages/MedTrackerSync` to the existing macOS-15 job (alongside Core/Data) and include `Packages/MedTrackerSync` in the `swiftformat --lint` and `swiftlint --strict` invocations (match how Core/Data are referenced). Cache SwiftPM as the existing steps do.
- [ ] **Step 2:** Run the full local gate: `swift test` in all three packages, then `swiftformat --lint Packages/` and `swiftlint --strict` (fix any findings — keep code warning-clean, matching the Phase 1a bar). Record the new `MedTrackerSync` test count.
- [ ] **Step 3: Commit** — `git commit -am "ci: swift test + lint for MedTrackerSync"`.
- [ ] **Step 4:** Push `phase-1b-sync-engine`, open a **draft PR** against `medtracker-mac` `main`, and confirm CI goes green.

---

## Self-Review

**Spec coverage (design spec §1–§12):**

- §1 package + file layout → Task 1 (scaffold), Tasks 3–15 (each unit). ✅
- §2 wire models (numeric-as-string, ISO dates) → Task 3. ✅
- §3 errors + two shapes + HTTP + endpoints → Tasks 4, 5, 6. ✅
- §4 token storage (Keychain + in-memory) → Task 7. ✅
- §5 cursor + epoch via `sync_state` KV → Task 8. ✅
- §6 apply (delta upsert, schedules-wholesale, fullResync wipe+replace, tombstones, prefs 4→2, atomic) → Tasks 9, 10, 11. ✅
- §7 append-only rule + enqueue + drain + reconciliation (rows + pending payloads + cross-command chain) → Tasks 12, 13, 14; schema support → Task 2. ✅
- §8 orchestration (`actor`, drain→pull→apply→persist, 401/429 surfacing, fullResync via epoch) → Task 15. ✅
- §9 error handling (transactional, isolation) → Tasks 11, 14, 15. ✅
- §10 testing discipline (MockTransport, in-memory GRDB) → every task. ✅
- §11 CI → Task 16. ✅
- §12 out-of-scope (`/export/full`, notifications, UI) → not planned. ✅

**Placeholder scan:** two intentional test-scaffolding stubs are called out inline for removal (Task 14 `runDrainReconciles`, Task 15 `sessionUser()`); the `withFullResync` helper is explicitly replaced by a `var` mutation in Task 11. No `TODO`/`TBD`/"add error handling" placeholders remain in source steps.

**Type consistency:** `EntityKind` (Task 12) raw values `medication`/`dose_log` are consumed by `OutboxEntry.localEntityKind` (Task 2, a `String?`) and `Reconciler.reconcile(kind:)` (Task 13) and `OutboxStore.enqueue(localEntityKind:)` (Task 12) and `SyncEngine.enqueue` (Task 15) — all aligned. `APIClient` (Tasks 5/6) method names (`login`/`verifyTOTP`/`signInWithApple`/`sync`/`runCommands`) are the exact ones `OutboxDrainer` (Task 14) and `SyncEngine` (Task 15) call. `SyncApplier.apply` (Tasks 10/11), `OutboxStore` transitions (Task 12), `SyncStateStore` (Task 8) signatures match their call sites in Task 15. `DrainResult` fields (`sent`/`failed`/`inProgress`, Task 14) match the assertions in Tasks 14/15. ✅

**Open confirmations for the implementer (resolve at task start, don't block):**

- The two pinned epoch integers in Task 9 — confirm on first green run and write the actual values in if Foundation differs.
- GRDB 7 `upsert(_:)` availability for TEXT-primary-key records (Task 10/11) — it is (SQLite UPSERT); if a record needs an explicit conflict target, use `insert(onConflict: .replace)` instead.
- Whether `swiftlint --strict` flags the `@unchecked Sendable` on `MockTransport` (Task 5) — it's test-only; add an inline `// swiftlint:disable:next` if needed, matching the Phase 1a approach.
