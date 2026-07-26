# Phase 1b — API Client + Sync Engine (Design Spec)

**Status:** approved 2026-07-26. Successor to Phase 1a (`docs/plans/2026-07-26-phase-1a-domain-core.md`,
merged). Precedes Phase 1c (SwiftUI app target + screens).

**Goal:** Give `medtracker-mac` an offline-capable sync layer against the existing SvelteKit
`/api/v1` backend: authenticate, pull server deltas into the local GRDB replica, and push local
writes through an idempotent command outbox — all as a **headless, `swift test`-able package** with
no app target. Phase 1c wires it to SwiftUI and proves it live.

**Reference contract (source of truth):** `medication-tracker/docs/api-v1-contract.md`. Where this
spec and that contract disagree, the contract wins. The backend surface (`/api/v1`) is merged and
deployed; Phase 1b is a pure client and does **not** change it.

---

## 1. Architecture

One new Swift package, `Packages/MedTrackerSync`:

- **Depends on** `MedTrackerData` (GRDB records, migrations, repositories, the local-only
  `OutboxEntry` / `SyncState` records scaffolded in Phase 1a) and `MedTrackerCore` (`createId`,
  domain types).
- **Swift 6 tools / Swift 5 language mode**, `platforms: [.macOS(.v15)]` — identical to the other
  two packages.
- Headless: every unit is exercised by `swift test` with a mocked HTTP transport and an in-memory
  GRDB database. No `URLSession` hits the network in CI.

The sync layer is **server-authoritative**: pulls replace/upsert local rows (last-write-wins by the
server), and local writes are optimistic overlays that reconcile against the server's canonical
result. This matches the product constraint (the web app is the shared data hub; the Mac app must
not diverge).

### File layout

```
Packages/MedTrackerSync/
  Package.swift                       # products: MedTrackerSync; deps: MedTrackerData, MedTrackerCore
  Sources/MedTrackerSync/
    Config.swift                      # SyncConfig (base URL, etc.)
    WireModels.swift                  # Codable DTOs for /api/v1 (auth, sync, commands)
    APIError.swift                    # typed error + two-shape decoding
    HTTPTransport.swift               # injectable async transport protocol (URLSession-backed)
    APIClient.swift                   # typed async endpoints over HTTPTransport
    TokenStore.swift                  # protocol + KeychainTokenStore + InMemoryTokenStore
    SyncStateStore.swift              # cursor + epoch persistence (sync_state as KV)
    WireMapping.swift                 # DTO <-> GRDB record conversion (ISO<->epoch, prefs 4->2)
    SyncApplier.swift                 # apply SyncResponse -> local DB (delta / fullResync / tombstones)
    Command.swift                     # command envelope + typed enqueue builders
    Reconciler.swift                  # local-id -> server-id rewrite across rows + pending payloads
    OutboxDrainer.swift               # POST /commands + per-result handling + reconciliation
    SyncEngine.swift                  # actor orchestrator: authenticate / enqueue / sync()
  Tests/MedTrackerSyncTests/
    MockURLProtocol.swift             # scripts HTTP responses for URLSession
    ...one test file per source unit
```

A **`v2` migration** is added to `MedTrackerData/Migrations.swift` (see §7).

---

## 2. Wire models (`WireModels.swift`)

Codable structs matching `/api/v1` field-for-field (contract §2–§4). Conventions:

- **Numeric-as-string stays `String`.** `dosageAmount`, `scheduleIntervalHours`,
  `schedules[].intervalHours` arrive as strings and are stored as TEXT in `MedTrackerData` — no
  `Decimal` round-trip in the wire layer.
- **Dates are ISO-8601 `String` on the wire**, converted to UTC epoch-seconds `Double` only when
  mapping into GRDB records (§6). Nulls stay null.
- Key types: `SessionUser`; `LoginOutcome` (enum: `.session(token:user:)` or
  `.totpChallenge(preAuthToken:)`, decoded by presence of `challenge`); `SyncResponse` with nested
  `WireMedication` (serialized medication + `schedules: [WireSchedule]`), `WireSchedule`,
  `WireDoseLog`, `WireInventoryEvent`, `WireAuditLog`, `WireTombstone`, `WirePreferences`;
  command envelope `CommandEnvelope { commands: [WireCommand] }`, `WireCommand { id, type, payload }`,
  `CommandsResponse { results: [CommandResultDTO] }`, `CommandResultDTO { id, ok, result?, error? }`.
- `payload` / `result` are arbitrary JSON — modeled as a small `JSONValue` enum (or
  `[String: AnyCodable]`) so unknown result shapes decode without loss.

## 3. Errors & HTTP (`APIError.swift`, `HTTPTransport.swift`, `APIClient.swift`)

`HTTPTransport` is a one-method async protocol (`send(_ request:) async throws -> (Data, HTTPURLResponse)`),
implemented by `URLSessionTransport` and stubbed in tests by a `MockURLProtocol`-backed session.
`APIClient` builds requests, injects `Authorization: Bearer <token>` on authed routes, and maps
non-2xx responses onto a typed `APIError`:

| HTTP | body shape                                 | `APIError` case                 |
| ---- | ------------------------------------------ | ------------------------------- |
| 400  | `{message}`                                | `.badRequest(String)`           |
| 401  | `{message}`                                | `.unauthorized`                 |
| 409  | `{message:"email_conflict"}`               | `.emailConflict`                |
| 429  | `{error:"rate_limited",retryAfterSeconds}` | `.rateLimited(retryAfter: Int)` |
| 5xx  | any                                        | `.server(status: Int)`          |
| —    | transport failure                          | `.transport(Error)`             |
| —    | undecodable 2xx                            | `.decoding(Error)`              |

The client must **branch on the two body shapes** (contract §6): `message` for thrown errors,
`error === "rate_limited"` for 429. `Retry-After` header is parsed as the fallback for
`retryAfterSeconds`.

**Endpoints** (all `async throws`):

- `login(email:password:) -> LoginOutcome`
- `verifyTOTP(preAuthToken:code:) -> (token: String, user: SessionUser)`
- `signInWithApple(identityToken:fullName:) -> (token: String, user: SessionUser)`
- `sync(since: String?, epoch: Int, token: String) -> SyncResponse`
- `runCommands(_ commands: [WireCommand], token: String) -> CommandsResponse`

`/export/full` is **deferred to Phase 2** (it is a full-resync backup file, not needed by the sync
loop).

## 4. Token storage (`TokenStore.swift`)

```swift
public protocol TokenStore: Sendable {
    func load() throws -> StoredSession?      // token + userId
    func save(_ session: StoredSession) throws
    func clear() throws
}
```

- `KeychainTokenStore` — macOS Keychain (`kSecClassGenericPassword`, fixed service + account).
- `InMemoryTokenStore` — used by all tests (Keychain is unreliable on headless CI).

The bearer token is a Lucia session id (contract §1); it is opaque to the client.

## 5. Cursor & epoch (`SyncStateStore.swift`)

The contract uses a **single** `cursor` (server response time) for every table and an integer
`epoch`. There are no per-table cursors to track, so the Phase-1a `sync_state` table degenerates to
a tiny key/value store: rows `__cursor__` (holds the ISO cursor) and `__epoch__` (holds the epoch as
a decimal string). `SyncStateStore` exposes `loadCursor()/saveCursor()` and `loadEpoch()/saveEpoch()`
over that table. (Documented as a deliberate repurpose so a future reader doesn't expect per-table
rows.)

## 6. Applying a pull (`WireMapping.swift`, `SyncApplier.swift`)

`SyncApplier.apply(_ response: SyncResponse)` runs inside **one** `db.write` transaction:

- **`fullResync == true`:** delete every synced-table row (children before parents, or via cascade),
  then insert everything in the response. Leaves `outbox` and `sync_state` untouched (they hold no FK
  to a synced table). **Caveat (`reminder_event`):** because `reminder_event` carries an
  `ON DELETE CASCADE` FK to `medication`, wiping medications also cascade-deletes any local
  `reminder_event` rows — so a full resync does _not_ preserve the reminder ledger. This is **inert in
  Phase 1b** (`reminder_event` is never written until Phase 2), and is a tracked Phase-2 decision:
  either snapshot/restore `reminder_event` across the wipe, or switch `applyFull` to a diff-based
  upsert-and-prune that only deletes medications the server actually dropped. `tombstones` are ignored
  on a full resync (the client is rebuilding from nothing).
- **`fullResync == false` (delta):**
  - **medications:** upsert each; for every returned medication, **replace its schedule set
    wholesale** — delete local `medication_schedule` rows for that `medication_id`, then insert the
    response's `schedules` child array (contract §3: schedules have no independent cursor and always
    arrive as the med's full current set).
  - **dose_logs:** upsert by id.
  - **inventory_events, audit_logs:** insert (append-only; the server only returns rows with
    `created_at > since`, so these are always new).
  - **profile:** upsert the singleton `Profile` from `SessionUser`.
  - **preferences:** upsert the singleton `Settings`, collapsing the web's four notification
    booleans into the local two. The Mac app has a single (native-notification) channel, so a local
    toggle is on if **either** matching web channel is on:
    `overdueRemindersEnabled = overdueEmailReminders || overduePushReminders`,
    `lowInventoryAlertsEnabled = lowInventoryEmailAlerts || lowInventoryPushAlerts`. On write-back
    (`update_preferences`) the local value is mirrored to **both** channels of that pair, so the
    collapse is idempotent across a round-trip. Every other preference maps 1:1.
  - **tombstones:** delete each `entityId` from the table implied by `entityType`
    (`medication` / `dose_log` / `medication_schedule` / `inventory_event`).

Mapping rules (`WireMapping.swift`): ISO date strings → epoch `Double`; numeric strings pass through
as TEXT; `daysOfWeek` / `sideEffects` re-encoded as the JSON-TEXT shape `MedTrackerData` expects;
`changes` (audit) stored as raw JSON TEXT. The whole apply is atomic — a mapping/insert failure
rolls back the entire pull, leaving the last-good replica intact.

## 7. Optimistic writes, the outbox, and reconciliation

### 7.1 The append-only rule (key decision)

`inventory_event` and `audit_log` rows are **server-owned**. The server mints its own copies when a
command runs, and they arrive on the next delta pull (`created_at > since`). Therefore an optimistic
local write updates only **state** tables — `medication` (including `inventoryCount`), `dose_log`,
`medication_schedule` — and **never** writes local event/audit rows. This eliminates event
duplication and reduces reconciliation to a single primary-id rewrite. Trade-off: offline inventory
_history_ and audit trail don't reflect not-yet-synced actions (they self-heal on the next sync),
but `inventoryCount` — the load-bearing number — updates instantly.

> The full Phase-1a repositories (`logDose`, `refill`, … which _do_ write event/audit rows) remain
> as the atomic-transaction reference; the synced write path uses a thin optimistic + enqueue layer
> instead. The user-action wiring lives in Phase 1c; Phase 1b provides and tests the
> enqueue/reconcile mechanism.

### 7.2 Enqueue

`SyncEngine.enqueue` writes an `OutboxEntry` (`status = "pending"`, `idempotencyKey = createId()`)
whose `payload` is the exact JSON to POST, plus the new `local_entity_id` / `local_entity_kind`
columns (§7.4) when the command optimistically created a local row. For create commands the caller
also applies the minimal local effect (§7.1) in the same transaction as the enqueue.

### 7.3 Drain (`OutboxDrainer.swift`)

Drain pending entries **FIFO** (`created_at` order), sending **one command per `POST /commands`
request** and applying its result (below) before the next entry is read. This ordering is what makes
the offline create-then-reference chain (§7.4) work: a create's reconciliation remaps a dependent
command's local id **in the DB** before that dependent is transmitted, so the server never receives an
un-reconciled local id. Each entry's current payload is re-read from the DB immediately before it is
sent (so a prior reconcile's remap is picked up). Handle each `CommandResultDTO` (contract §4):

- **`ok` + a server id in `result`** → run **reconciliation** (§7.4), mark the entry `sent`.
- **`ok` with no id (replay of a cached result, or an idempotent no-id command)** → mark `sent`.
- **`error`** → mark `failed`, increment `attemptCount`, record `lastError`. Isolated: one command's
  failure never blocks its siblings.
- **`"in_progress"`** → leave `pending`, back off (do not hot-loop the same id); the next `/sync`
  reconciles actual state.

### 7.4 Reconciliation (`Reconciler.swift`)

When a create command acks with server id `Y` for the local id `X` recorded on the entry, run — in
one transaction with `PRAGMA defer_foreign_keys = ON`:

1. Rewrite the created row's own id and its direct FK references in **state** tables:
   - kind `medication`: `medication.id`, `medication_schedule.medication_id`, `dose_log.medication_id`
     (`X → Y`).
   - kind `dose_log`: `dose_log.id` (`X → Y`).
2. Rewrite `X → Y` inside every **still-pending** outbox `payload` — this handles the offline chain
   "create med (local `X`) → log a dose against `X`" before any sync: the pending `log_dose`
   payload's `medicationId` is remapped so the server receives `Y`.

The subsequent delta pull then upserts the server's canonical rows onto id `Y` idempotently, and
replaces the med's schedules wholesale (§6) — so local schedule ids need no rewrite.

Only `medication` and `dose_log` are reconciled kinds; `refill` / `adjust` / `archive` / `unarchive`
/ `reorder` / `edit` / `delete` reference existing ids and create no new client-visible entity.

## 8. Orchestration (`SyncEngine.swift`)

An `actor` (serializes concurrent `sync()` calls). Holds `APIClient`, a GRDB `DatabaseWriter`,
`TokenStore`, `SyncStateStore`.

- `authenticate(...)` → calls the relevant auth endpoint, persists the token + a `Profile`/`Settings`
  seed, returns the outcome (including the TOTP-challenge branch).
- `enqueue(...)` → §7.2.
- `sync() async throws -> SyncOutcome`:
  1. **drain** the outbox (§7.3),
  2. **pull** `sync(since: loadCursor(), epoch: loadEpoch())`,
  3. **apply** (§6),
  4. persist `cursor` + `epoch` from the response.
     Surfaces `.unauthorized` (caller should re-auth) and `.rateLimited` (caller/back-off) rather than
     swallowing them. `fullResync` is handled transparently inside apply. `SyncOutcome` reports
     `{ fullResync, appliedCounts, pushed, failed }`.

Wipe commands bump the server epoch (contract §4); the next `sync()` sees `fullResync` because the
stored epoch is behind — no special-casing needed.

## 9. Error handling summary

- Transport / 5xx during drain or pull → `sync()` throws; caller retries later. Already-applied work
  is durable (drain and apply are each transactional).
- 429 → surface `retryAfter`; the caller schedules the next attempt.
- 401 → `.unauthorized`; the session is stale, caller must re-authenticate.
- Per-command validation/domain errors → recorded on the entry, never fatal to the batch.
- All DB mutations (apply, reconcile, enqueue+optimistic-effect) are single transactions; partial
  application is impossible.

## 10. Testing

Discipline mirrors Phase 1a (transcribe the contract into executable tests). Harness:
`MockURLProtocol` scripts HTTP responses; in-memory GRDB (`MedTrackerDatabase.open(path: nil)`);
`InMemoryTokenStore`.

Coverage:

- **APIClient / APIError:** each auth outcome (session, TOTP challenge, Apple new/existing/conflict),
  both error-body shapes, 429 `Retry-After`, bearer header injection.
- **SyncApplier:** delta upsert; fullResync wipe-and-replace; tombstone deletion per entity type;
  schedules-wholesale-replace; numeric-string + ISO-date mapping; preferences 4→2 collapse; atomic
  rollback on a mid-apply failure.
- **OutboxDrainer / Reconciler:** FIFO drain; `ok`/replay/`in_progress`/`error` handling and
  isolation; id reconciliation for `dose_log` and `medication`, including the cross-command chain and
  pending-payload remap; `attemptCount`/`lastError` bookkeeping.
- **SyncStateStore:** cursor/epoch persistence round-trip; first-sync (no cursor) path.
- **SyncEngine:** end-to-end drain→pull→apply against scripted responses; `fullResync` via a bumped
  epoch; 401/429 propagation.

## 11. CI

Extend `.github/workflows/ci.yml` with a `swift test` step for `Packages/MedTrackerSync` and include
its sources under the existing `swiftformat --lint` / `swiftlint --strict` gates.

## 12. Explicitly out of scope for Phase 1b

- SwiftUI / app target / user-action wiring (Phase 1c).
- `/export/full` client + file emission, notifications, app lock (Phase 2).
- Any change to the `/api/v1` backend surface.
- Per-field conflict resolution / CRDTs (server-authoritative last-write-wins is sufficient for a
  single-user account).
