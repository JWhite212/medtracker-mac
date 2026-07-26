# Phase 1c — SwiftUI App Target + Screens — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Design spec (source of truth for behaviour/design): `docs/superpowers/specs/2026-07-26-phase-1c-swiftui-screens-design.md`. Wire contract (authoritative for every command payload/result): `docs/design/api-v1-contract.md` §4. SDD progress tracker: `.superpowers/sdd/progress.md` — one reviewer gate per task; per-task briefs/reports live alongside it (1a/1b pattern).

**Goal:** Build the native SwiftUI macOS app on top of the finished `MedTrackerCore` / `MedTrackerData` / `MedTrackerSync` packages — app shell + composition root, first-run medical-disclaimer consent gate, auth/session gating (email+password, TOTP, conditional Sign in with Apple), and the **Dashboard / Medications / History** screens — with every user action wired through the thin **optimistic state-effect + outbox-enqueue** write path, all writes converging on the server.

**Architecture:** Two new SPM library packages — `MedTrackerApp` (`@Observable @MainActor` stores / view-models / `WriteCoordinator` / `SyncScheduler` / record→lean-model adapters; the tested read queries + row types live in `MedTrackerData`) and `MedTrackerUI` (SwiftUI views + the dark-only design system) — plus a `MedTrackerTestSupport` test-only package and a thin xcodegen `MedTracker` app-target shell. Reads flow GRDB `ValueObservation` → `Sendable` snapshot values that views render deterministically; writes are a single GRDB transaction (state-only optimistic effect + transaction-joined `OutboxStore.enqueue(_ db:)`) drained by the existing `SyncEngine`. Server-authoritative last-write-wins; the first sync runs behind a modal gate.

**Tech Stack:** Swift 6.2 / Xcode 26 — the new app tree adopts Swift 6 language mode + `SWIFT_STRICT_CONCURRENCY: complete`; the three shipped packages stay Swift 5 mode. SwiftUI-only (macOS 15), GRDB 7 (`DatabaseQueue`), `swift-snapshot-testing` (test-only), xcodegen. Dark-only theme; custom `Canvas`/`Path` charts (no Swift Charts). No network in CI (mock `HTTPTransport` + in-memory GRDB + `InMemoryTokenStore`).

---

## Cross-task reconciliations — AUTHORITATIVE (apply during execution)

These producer-side corrections were surfaced by the plan's adversarial review (signature drift, coverage gaps, missing subviews). They **override** any conflicting task description. Tasks 23–27's fixes are already folded into their execution guidance; the fixes for Tasks 1–22 are listed here (a session-usage limit interrupted folding them inline — see the closing note in §Execution).

**Data + app spine (Tasks 1–16):**
- **Task 1:** the four fetch helpers are `public static func` (consumed cross-package from MedTrackerApp).
- **Task 3:** `HistoryFilter` conforms to `Sendable, Equatable, Hashable` (Task 15 embeds it in a Hashable observation key).
- **Task 9:** `SessionModel` also exposes `lastSyncedAt: Date?`, `isSyncing: Bool`, `lastSyncError: AuthError?`, updated inside `runSync()` (backs the sidebar sync-status indicator, §2.5/§3.4.3).
- **Tasks 13 & 14:** `Medication.scheduleIntervalHoursDecimal` does NOT exist — at the `dailyRateFor(legacyIntervalHours:)` call site use `med.scheduleIntervalHours.flatMap { Decimal(string: $0) }`. (`jsRound(_:) -> Int` IS public in MedTrackerCore — keep it.)
- **Task 14:** `MedicationDetailVM` is the single canonical type, owned in MedTrackerApp: `{ card: MedicationCardVM; schedules: [ScheduleRow]; inventoryEvents: [InventoryEventVM] }` with `InventoryEventVM { id; eventType; quantityChange; previousCount: Int?; newCount: Int?; note: String?; createdAt: Double }`. Any formatted schedule-summary / notes / inventoryCount / alertThreshold the detail view needs are added as fields HERE — MedTrackerUI must NOT redefine it.
- **Task 12:** `AppModel` also observes the `Settings` singleton (`Settings.fetchOne(db, key: 1)`) and exposes `settings: Settings?`.
- **Task 15:** read `dateFormat`/`timeFormat` (absolute-date labels — honored read-only in 1c per §5.3.1/S6, NOT deferred to Phase 2) and `doseLogPageSize` from synced `Settings` (default 20 only when absent). `writeCoordinator` stays `private`; call the public `editDose`/`deleteDose` store wrappers.
- **Task 16:** `MedicationDraft` also exposes `addScheduleRow()`, `removeScheduleRow(at:)`, and `primaryColorBinding` / `secondaryColorBinding: Binding<Color>`.

**UI design system + screens (Tasks 17–22):**
- **Task 17:** add `effectiveReduceMotion = @Environment(\.accessibilityReduceMotion) || settings.reducedMotion`; gate transitions/flash on it (never the informational live counters).
- **Task 19:** `SparklineView(shape:size:stroke:fill:)` — the label is `stroke:`, not `strokeColor:`.
- **Task 20 (canonical component producers):** `StatusPill` provides BOTH `init(status: DoseStatus)` (History) and `init(slot: SlotStatus)` (Dashboard My-Day); `RefillChips(severity:daysUntilRefill:isLowInventory:)`; `QuickLogBar` gains a 1–10 qty control (default 1) + `onLog: (String, Int) -> Void` + the ~700 ms success flash (`#10b981`, suppressed under `effectiveReduceMotion`) + ⌘1–9; `TimingBadge(_ vm: TimingBadgeVM)` (unlabeled).
- **Task 21 (Dashboard):** use `StatusPill(slot:)`, `RefillChips(isLowInventory:)`, `QuickLogBar(onLog: (String,Int))`, `TimingBadge(badge)`; add a transient success toast on quick-log; apply `effectiveReduceMotion`.
- **Task 22 → SPLIT into 22a + 22b:** *22a* = `MedicationsListScreen` (store-owning; wires an `onNew` form sheet + `onSelect` NavigationStack push to detail) + `MedicationCard` (`RefillChips(isLowInventory:)`, `SparklineView(stroke:)`, `TimingBadge(badge)`) + reorder (.onMove → `writeCoordinator.reorder`) + archived DisclosureGroup. *22b* = `MedicationFormView`+`StylePicker`+`ScheduleSection` (Save → `upsertMedication`) + `MedicationDetailScreen` (store-owning; observes the Task-14 detail store; wires refill/adjust/archive/unarchive/edit) + `MedicationDetailView` consuming Task 14's canonical `MedicationDetailVM`. Implement every referenced private subview concretely — `DayOfWeekPicker`, `InventorySection`, `DisclaimerNotice`, `InventoryCard`, `InventoryEventHistory` (real `View` bodies, no comment placeholders).
- **Task 24 (consumers of Task 22a):** `MainShell` wires the real Medications NavigationStack push + `onNew` sheet (not `onSelect: { _ in }` placeholders) and binds `SidebarFooter` to `SessionModel`'s real sync status.

---

## Global Constraints

_Every task implicitly includes this section. Values copied verbatim from spec/contract._

- **Toolchain:** Swift 6.2 / Xcode 26; the new app tree (`MedTrackerApp`, `MedTrackerUI`, `App/` target) adopts **Swift 6 language mode + `SWIFT_STRICT_CONCURRENCY: complete`**; the three shipped packages stay `swiftLanguageMode(.v5)` (§2.1). Strict-concurrency diagnostics do **not** propagate into the .v5 packages — their `Sendable` annotations are the contract, not a compiler guarantee (§2.1).
- **Deploy / platform:** macOS **15.0** minimum, `platform: macOS`, **SwiftUI-only** (no AppKit except the SIWA `NSViewRepresentable` bridge) (§2.2).
- **Theme:** **dark-only** (master §10.2); no light-mode variants (§6).
- **Database:** keep the **`DatabaseQueue`** returned by `MedTrackerDatabase.open(path:)` — no package change; `DatabasePool` is a deferred future factory entry point (§2.6, §8-#9). Reads via `ValueObservation`; first sync runs behind a modal gate so the bulk-apply read-stall is harmless (§2.6, §3.3).
- **New dependencies:** exactly one new SPM dep, **`swift-snapshot-testing`**, **test-only**, wired into the snapshot target only (§7). No other new deps; numeric-as-string stays `String`, dates stay UTC **epoch-seconds `Double`** at the record boundary (1b Global Constraints).
- **No network in CI:** every `swift test` runs against a **mock `HTTPTransport` + in-memory GRDB (`open(path: nil)`) + `InMemoryTokenStore`**; no test touches the network or Keychain (§2.4, §7.1).
- **Entitlements (`App/MedTracker.entitlements`) = exactly two keys:** `com.apple.security.app-sandbox: true` + `com.apple.security.network.client: true`. **No** `com.apple.developer.applesignin`, `usernotifications.time-sensitive`, `files.user-selected.read-write`, keychain-access-groups, CloudKit in 1c (§2.3). Hardened Runtime is the build setting `ENABLE_HARDENED_RUNTIME: YES`, not an entitlement.
- **Commits / PRs:** conventional-commit messages, **no AI attribution** of any kind (no session trailer, no Co-Authored-By).
- **Plan location:** `docs/plans/`. **SDD progress tracker:** `.superpowers/sdd/progress.md` (one reviewer gate per task).
- **Write-path rule (load-bearing, §4.1):** on a user action, apply the **minimal optimistic effect to STATE tables only** (`medication`, `dose_log`, `medication_schedule`) and enqueue the `OutboxEntry` **in the same GRDB transaction**; **never** write local `inventory_event`/`audit_log` (those arrive on the next delta pull). `localEntityId`/`localEntityKind` set **only** for the two reconciled create kinds — `.medication` and `.doseLog`. Client ids from `MedTrackerCore.createId()`.
- **Timezone:** all date/day bucketing uses the **synced `Profile.timezone`** (singleton `Profile`, `id == 1`) via `TimeZone(identifier:)`, fallback **`UTC`** — **never `TimeZone.current`** (§1.3, §5.1.0); system-tz fallback only on the offline-relaunch-before-first-Profile edge (§3.3, §8-#16).

---

---

## File / module structure

New tree layout (mirrors §2.1). `NEW` = create; `MOD` = modify.

### `Packages/MedTrackerApp/` — NEW library (Swift 6 mode; `@Observable @MainActor` logic; **no SwiftUI rendering**; depends on Core+Data+Sync; `→ swift test`)
- `Package.swift` — NEW. Swift-6 lang mode, `complete` concurrency, deps on the three local packages; test target adds `MedTrackerTestSupport`.
- `Sources/MedTrackerApp/AppEnvironment.swift` — NEW. Composition root: `dbWriter`/`tokenStore`/`syncEngine`; `live()` + `testing(transport:tokenStore:)` factories (§2.4).
- `Sources/MedTrackerApp/SessionModel.swift` — NEW. `AuthPhase`, `AuthError`, `FirstSyncState`, the auth/consent/sync state machine, the single `runSync()` funnel + 401→re-login (§3).
- `Sources/MedTrackerApp/AppModel.swift` — NEW. `SidebarItem`, app-wide model (selection, `dbWriter`/`userId`/`WriteCoordinator`/`SyncScheduler`, `Profile` observation → `timeZone`) (§2.5, §3.3).
- `Sources/MedTrackerApp/WriteCoordinator.swift` — NEW. All ten `async throws` commands; each = one `dbWriter.write { }` (state effect + tx-joined enqueue) (§4).
- `Sources/MedTrackerApp/SyncScheduler.swift` — NEW. Debounced `requestSync()`, drop-if-in-flight, routes through `SessionModel.runSync()` (§3.4, §4.4).
- `Sources/MedTrackerApp/Adapters.swift` — NEW. `RecordAdapters`: `MedicationSchedule→ScheduleRow`, `DoseLog→DoseEvent`, `Medication→MedicationPattern`, `String→DoseStatus` (§4.1).
- `Sources/MedTrackerApp/DashboardStore.swift` — NEW. `DashboardStore` + `DashboardSnapshot` and its sub-VMs (§5.1).
- `Sources/MedTrackerApp/MedicationsStore.swift` — NEW. `MedicationsStore` + `MedicationCardVM`; detail store/VM (§5.2).
- `Sources/MedTrackerApp/HistoryStore.swift` — NEW. `HistoryStore` (filter state + growing-window observation), `HistoryRowVM`, `HistorySection` (§5.3).
- `Sources/MedTrackerApp/MedicationDraft.swift` — NEW. `@Observable MedicationDraft` → `MedicationFields` + `[MedicationScheduleInput]`; client-side validation (§5.2.3).
- `Tests/MedTrackerAppTests/*` — NEW. Write-layer atomicity, adapters, date-bucketing, store-observation, auth-state-machine tests (§7.1).

> **Note (reconciling §2.1 "DoseLogQueries + aggregation queries" with §8):** the tested read helpers + their row types are defined in **`MedTrackerData`** (below — §8-#2/3/4 explicitly call them "New MedTrackerData query surface", and they need the persistence layer + registered `localDate`). `MedTrackerApp` stores **consume** them inside `ValueObservation.tracking { }`; no query SQL is duplicated in the app package.

### `Packages/MedTrackerUI/` — NEW library (SwiftUI views + design system; depends on App+Core; `→ snapshot-tested under xcodebuild`)
- `Package.swift` — NEW. Swift-6 mode; deps `MedTrackerApp`, `MedTrackerCore`; snapshot test target adds `swift-snapshot-testing` + `MedTrackerTestSupport`.
- `Sources/MedTrackerUI/Theme.swift` — NEW. Dark-only tokens (surface/raised/text/success/warning/danger/accent) + spacing/radius; references asset-catalog colours (§6).
- `Sources/MedTrackerUI/MedicationPatternFill.swift` — NEW. 8 patterns as SwiftUI fills + `<20pt→gradient` degradation + 4-direction text outline (§6).
- `Sources/MedTrackerUI/SparklineView.swift` — NEW. `SparklinePath`/`Canvas` renderer over `buildSparklineShape` (§6).
- `Sources/MedTrackerUI/Components/` — NEW. `MedicationSwatch`, `StatusPill`, `RefillChips`, `AdherenceMiniBar`, `TimingBadge`, `QuickLogBar` (§5.x).
- `Sources/MedTrackerUI/Dashboard/` — NEW. `DashboardView`, `SummaryStrip`, `RefillsCard`, `MyDayTimeline`, `TodayFeed`, `OnboardingCTA` (§5.1).
- `Sources/MedTrackerUI/Medications/` — NEW. `MedicationsListScreen`+`MedicationCard`, `MedicationFormView`+`StylePicker`+`ScheduleSection`, `MedicationDetailView`+`InteractionProbeCard`(stub) (§5.2).
- `Sources/MedTrackerUI/History/` — NEW. `HistoryView`, `FilterBar`, `TimelineEntryRow`, `EditDoseSheet` (§5.3).
- `Sources/MedTrackerUI/Auth/` — NEW. `DisclaimerConsentView`, `LoginView`, `TOTPView`, `FirstSyncView`, `SignInWithAppleControl`, `MainShell` (Split+Stack), `SidebarFooter` (§3, §2.5).
- `Tests/MedTrackerUITests/*` — NEW. Snapshot tests (dark-only, fixed `now`/tz, explicit `sizeCategory`), under `xcodebuild` (§7.2).

### `Packages/MedTrackerTestSupport/` — NEW test-only library (depended on by test targets only)
- `Package.swift` — NEW. Depends `MedTrackerSync`, `MedTrackerData`, `MedTrackerCore`.
- `Sources/MedTrackerTestSupport/MockTransport.swift` — NEW. **Public** `HTTPTransport` mock promoted from `MedTrackerSyncTests/MockTransport` (§8-#7).
- `Sources/MedTrackerTestSupport/Fixtures.swift` — NEW. Public fixture/seed builders (contract JSON, record builders).
- `Sources/MedTrackerTestSupport/FixedClock.swift` — NEW. Deterministic clock/`now` provider.

### `Packages/MedTrackerSync/` — MOD (the tx-joining enqueue, §8-#1)
- `Sources/MedTrackerSync/OutboxStore.swift` — MOD. Add `enqueue(_ db: Database, type:payload:localEntityId:localEntityKind:) throws -> OutboxEntry` (no internal `db.write`).
- `Sources/MedTrackerSync/SyncEngine.swift` — MOD (optional). Add `enqueue(_ db: Database, …)` passthrough if the coordinator routes through the engine.
- `Tests/MedTrackerSyncTests/OutboxStoreTests.swift` — MOD. Roll-back-the-block atomicity test; update the import if `MockTransport` moves to `MedTrackerTestSupport`.

### `Packages/MedTrackerData/` — MOD (new query surface + state-only writer, §8-#2/3/4/5)
- `Sources/MedTrackerData/MedicationQueries.swift` — MOD. Add active/archived list fetch (`order(sort_order)`), schedules-by-med, per-med inventory-event history (§8-#2).
- `Sources/MedTrackerData/DoseAggregations.swift` — NEW. `DailyDoseCount`/`PerMedStat` + streak-dates query (§8-#3a/b/c/d), using registered `localDate`.
- `Sources/MedTrackerData/DoseLogQueries.swift` — NEW. `HistoryRow` + filtered/paged `dose_log ⨝ medication` join with optional-bind filter set + growing LIMIT (§8-#4).
- `Sources/MedTrackerData/StateMedicationWriter.swift` — NEW. State-only upsert med+schedules (no audit) + **re-exposed public `makeSchedule` normalization**, runs inside a caller-passed `Database` (§8-#5, §5.2.4).
- `Tests/MedTrackerDataTests/*` — MOD/NEW. Query + aggregation + writer tests against in-memory GRDB.

### `App/` — NEW (xcodegen app target; near-zero logic)
- `App/MedTrackerApp.swift` — NEW. `@main App`; builds `AppEnvironment.live()` once into `@State`; wraps in `SessionModel`+`AppModel`; `.environment(...)`; hosts the root auth switch.
- `App/MedTracker.entitlements` — NEW. Exactly the two keys (§2.3).
- `App/Info.plist` (or `GENERATE_INFOPLIST_FILE` keys) — NEW. Category `public.app-category.healthcare-fitness`.
- `App/PrivacyInfo.xcprivacy` — NEW. `NSPrivacyTracking=false`; required-reason `UserDefaults CA92.1` (+ `file-timestamp C617.1` if used) (§2.3).
- `App/Assets.xcassets` — NEW. Dark-only theme colours (`actool`-compiled), app icon.
- `App/SignInWithAppleBridge.swift` — NEW (in app target; needs `AuthenticationServices`). Thin delegate → two strings → `SessionModel` (§3.2).

### Config — MOD
- `project.yml` — MOD. Add top-level `packages:` map (5 local `path:` + remote `SnapshotTesting`) + the `MedTracker` `application` target (`SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `deploymentTarget: "15.0"`, `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_ENTITLEMENTS: App/MedTracker.entitlements`, `PRODUCT_BUNDLE_IDENTIFIER: site.jamiewhite.medtracker`, `PRODUCT_NAME: MedTracker`, category `healthcare-fitness`); keep `MedTrackerSpike` (§2.2, §2.3). Bundle id/product name deliberately match `KeychainTokenStore` default `service: "site.jamiewhite.medtracker"`.
- `.github/workflows/ci.yml` — MOD. Add `swift test` for `MedTrackerApp` (`--enable-code-coverage`) + `MedTrackerUI`; add build+snapshot lane (`brew install xcodegen`, `xcodegen generate`, `xcodebuild test … CODE_SIGNING_ALLOWED=NO`); extend SwiftPM cache paths (§7.3).
- `.swiftlint.yml` / `.swiftformat` — MOD. Add the new source trees to `included:`/lint scope; add a **nested `.swiftlint.yml`** under the new app trees re-enabling `identifier_name`/`line_length` (stricter bar for net-new Swift-6 code) (§7.3).

---

---

## Task dependency order

**Parallel group A (all independent — no cross-deps; can run concurrently):** Tasks 1, 2, 3, 4, 5, 6.
_(Tasks 1–6 parallel; 8/9/10 partly parallel after 7; 20–24 parallel after 20; 26–27 sequential tail.)_

See the per-task **blocked-by** annotations in §Tasks. Start with the parallel data-layer group (Tasks 1–6).

## Tasks (decomposition, dependencies, deliverables)

Right-sized to one reviewer gate each; each ends in an independently-testable deliverable. Dependency order: infra/package-changes → consumers.

**Parallel group A (all independent — no cross-deps; can run concurrently):** Tasks 1, 2, 3, 4, 5, 6.

1. **MedTrackerData — list/detail fetch helpers.** Active/archived medication lists (`order(sort_order)`), schedules-grouped-by-med, per-med inventory-event history. _Spec:_ §8-#2, §5.2.1/5.2.6. _Files:_ `MedicationQueries.swift`(MOD)+tests. _Blocked by:_ none.
2. **MedTrackerData — dose aggregations.** `DailyDoseCount` (14-day taken-qty per `localDate`), `PerMedStat` (30-day taken-qty + 7-day taken count + last-taken), distinct-`localDate`-over-all-taken (streak). _Spec:_ §8-#3a/b/c/d, §5.1.1/5.1.2/5.2.1. _Files:_ `DoseAggregations.swift`(NEW)+tests. _Blocked by:_ none.
3. **MedTrackerData — filtered/paged history query.** `HistoryRow` + `dose_log ⨝ medication` join, optional-bind filter set, `localDate` grouping, growing LIMIT; date-range stays sargable via epoch bounds. _Spec:_ §8-#4, §5.3.1/5.3.2. _Files:_ `DoseLogQueries.swift`(NEW)+tests. _Blocked by:_ none. _(Confirm json1, `taken_at` vs `logged_at`, notes-search scope — §8-#13/14/15.)_
4. **MedTrackerData — state-only med writer + re-exposed `makeSchedule`.** State-only upsert med+schedules (delete-then-insert, **no audit**), running inside a caller-passed `Database`; public `makeSchedule` normalization. _Spec:_ §8-#5, §4.1, §5.2.4. _Files:_ `StateMedicationWriter.swift`(NEW)+tests. _Blocked by:_ none.
5. **MedTrackerSync — tx-joining `enqueue(_ db:)`.** `OutboxStore.enqueue(_ db:…)` (no internal write); optional `SyncEngine.enqueue(_ db:…)`. Test rolls back the block, asserts neither row landed. _Spec:_ §8-#1, §4.2. _Files:_ `OutboxStore.swift`(MOD), `SyncEngine.swift`(MOD)+tests. _Blocked by:_ none.
6. **MedTrackerTestSupport — package + MockTransport promotion.** Scaffold package; promote **public** `MockTransport` + fixtures + fixed clock; re-point `MedTrackerSyncTests` import. _Spec:_ §8-#7, §7.1. _Files:_ whole package(NEW); `MedTrackerSyncTests`(MOD). _Blocked by:_ none.

**Sequential app spine:**

7. **MedTrackerApp — package scaffold + AppEnvironment.** Swift-6 package; `AppEnvironment.live()`/`testing(...)`; smoke test builds a `SyncEngine` from all three doubles. _Spec:_ §2.1, §2.4. _Blocked by:_ 5, 6.
8. **MedTrackerApp — record→lean-model adapters.** `RecordAdapters` (ScheduleRow/DoseEvent/pattern/status) with pure-in/pure-out tests (highest-risk seam). _Spec:_ §4.1, §7.1. _Blocked by:_ 7.
9. **MedTrackerApp — SessionModel + AuthPhase + consent gate.** `AuthPhase`/`AuthError`/`FirstSyncState`; disclaimer flag read/persist; login/TOTP/SIWA outcome mapping; `runSync()` + centralized 401→re-login; sync triggers. _Spec:_ §3.1/3.2/3.3/3.4. _Blocked by:_ 7. _(Parallel with 8, 10.)_
10. **MedTrackerApp — WriteCoordinator (all 10 commands).** Each `async throws` = one `dbWriter.write` (state effect per §4.3 + tx-joined enqueue); exact contract §4 payloads/reconcile keys; `reorder` decomposed to pairwise swaps. _Spec:_ §4, contract §4. _Blocked by:_ 4, 5, 8. _(Parallel with 9.)_
11. **MedTrackerApp — SyncScheduler.** Debounced `requestSync()`, drop-if-in-flight, routes to `runSync()`. _Spec:_ §3.4, §4.4. _Blocked by:_ 9.
12. **MedTrackerApp — AppModel + SidebarItem + Profile/timezone observation.** Selection; injects `dbWriter`/`userId`/`WriteCoordinator`/`SyncScheduler`; `Profile(id==1)` → `timeZone` (UTC fallback). _Spec:_ §2.5, §3.3, §5.1.0. _Blocked by:_ 10, 11.
13. **MedTrackerApp — DashboardStore + DashboardSnapshot.** One observation; adapts records; computes slots/summary/refills/quick-log/my-day/today-feed into the Sendable snapshot; view-driven `observe()` + `loadError`. _Spec:_ §5.1, §2.6. _Blocked by:_ 1, 2, 8, 12.
14. **MedTrackerApp — MedicationsStore + MedicationCardVM + detail VM.** Active/archived card VMs (refill pipeline, adherence mini-bar, 14-day sparkline shape, timing badge composition §5.2.5); detail read + inventory-event history. _Spec:_ §5.2.1/5.2.5/5.2.6, §8-#8. _Blocked by:_ 1, 2, 8, 12.
15. **MedTrackerApp — HistoryStore + HistoryRowVM/HistorySection.** Filter state, growing-window observation, Today/Yesterday grouping in `Profile.tz`, edit/delete writes. _Spec:_ §5.3. _Blocked by:_ 3, 8, 12.
16. **MedTrackerApp — MedicationDraft + validation.** `@Observable` draft → `MedicationFields`+`[MedicationScheduleInput]`; client-side validation (master §8.1). _Spec:_ §5.2.3. _Blocked by:_ 10.

**MedTrackerUI (design system before screens; screens 20-24 largely parallel):**

17. **MedTrackerUI — package scaffold + Theme tokens.** Dark-only tokens; snapshot harness wired to `swift-snapshot-testing` under `xcodebuild`. _Spec:_ §6, §7.2. _Blocked by:_ 13 (for snapshot value types) — practically 8/13.
18. **MedTrackerUI — MedicationPatternFill (8 patterns + degradation).** Fill geometry + `<20pt→gradient` + text outline; snapshot all 8 + degradation. _Spec:_ §6, §7.2. _Blocked by:_ 17.
19. **MedTrackerUI — SparklineView (Canvas/Path).** Render `SparklineShape`; snapshot empty/single/flat/normal+dot. _Spec:_ §6, §7.2. _Blocked by:_ 17.
20. **MedTrackerUI — shared components + QuickLogBar.** Swatch/pills/chips/mini-bar/timing badge; `QuickLogBar` contrast text over each colour/pattern (⌘1–9). _Spec:_ §5.1.4/5.1.6, §7.2(F3). _Blocked by:_ 18, 19. _(20-24 parallel.)_
21. **MedTrackerUI — Dashboard views.** `SummaryStrip`/`RefillsCard`/`MyDayTimeline`/`TodayFeed`/`OnboardingCTA` + root `TimelineView(.periodic 30s)` ticker. _Spec:_ §5.1. _Blocked by:_ 13, 20.
22. **MedTrackerUI — Medications views.** `MedicationsListScreen`+`MedicationCard` (reorder/archived group), `MedicationFormView`+`StylePicker`+`ScheduleSection`, `MedicationDetailView`+disabled `InteractionProbeCard`. _Spec:_ §5.2. _Blocked by:_ 14, 16, 20.
23. **MedTrackerUI — History views.** `FilterBar`, grouped list, `TimelineEntryRow`, `EditDoseSheet`, delete dialog. _Spec:_ §5.3. _Blocked by:_ 15, 20.
24. **MedTrackerUI — Auth/consent/shell.** `DisclaimerConsentView`, `LoginView`, `TOTPView`, `FirstSyncView`, `SignInWithAppleControl`, `MainShell`, `SidebarFooter`. _Spec:_ §3, §2.5. _Blocked by:_ 9, 12, 20.

**App target + config + CI:**

25. **App target — @main + entitlements + Info.plist + PrivacyInfo + assets + SIWA bridge.** Compose `AppEnvironment.live()`; root auth switch; asset-catalog colours; SIWA delegate. _Spec:_ §2.2/2.3/2.4, §3.2. _Blocked by:_ 21, 22, 23, 24.
26. **project.yml — packages + MedTracker target.** `packages:` map + `application` target with the §2.2 build settings; keep Spike. _Spec:_ §2.2. _Blocked by:_ 25.
27. **CI + lint.** Add `MedTrackerApp`/`MedTrackerUI` `swift test`; `xcodegen`+`xcodebuild` snapshot lane; extend cache + lint trees + nested stricter `.swiftlint.yml`; record & commit snapshot references. _Spec:_ §7.3. _Blocked by:_ 26.

_(Tasks 1–6 parallel; 8/9/10 partly parallel after 7; 20–24 parallel after 20; 26–27 sequential tail.)_

---

---

## Appendix A: Interface contract

Exact Swift signatures each task **produces** for downstream consumers. Prevents name drift. Existing package types referenced below are verified against source.

### Existing types consumed (verified — do not redefine)

- `MedTrackerCore`: `createId() -> String`; `MedicationPattern: String` (`solid/split/gradient/stripes/hStripes="h-stripes"/dots/checkerboard/radial`, `CaseIterable`); `ReadableTextColor{.dark→"#111111"/.light→"#ffffff"; var hex}`; `renderedColours(colour:String, colourSecondary:String?, pattern:MedicationPattern) -> [String]`; `getReadableTextColor(colour:colourSecondary:pattern:) -> ReadableTextColor`; `ScheduleRow(kind:ScheduleKind, intervalHours:Decimal?, timeOfDay:String?, daysOfWeek:[Int]?)`; `ScheduleKind: String`(`interval/fixedTime="fixed_time"/prn`); `DoseEvent(id:medicationId:takenAt:Date, status:DoseStatus)`; `DoseStatus{.taken/.skipped/.missed}`; `ScheduleSlot`; `SlotStatus{.taken/.skipped/.upcoming/.overdue}`; `computeScheduleSlots(medications:[String], schedulesByMedId:[String:[ScheduleRow]], todaysDoses:[DoseEvent], lastTakenByMed:[String:Date], dayStart:Date, dayEnd:Date, timeZone:TimeZone, now:Date) -> [String:[ScheduleSlot]]`; `computeTimingStatus(intervalHours:Decimal, lastEventAt:Date?, now:Date) -> (status:TimingStatus, minutesUntilDue:Int)`; `classifyHour(_:Int)->TimeOfDayBucket`; `groupSlotsByTimeOfDay(_:[ScheduleSlot], timeZone:TimeZone) -> [(bucket:TimeOfDayBucket, slots:[ScheduleSlot])]`; `expectedPerDay(forSchedules:[ScheduleRow])->Double`; `dailyRateFor(scheduleRows:[ScheduleRow], legacyScheduleType:String?, legacyIntervalHours:Decimal?, thirtyDayTakenQuantity:Int)->Double`; `classifyRefillSeverity(days:Int?)->RefillSeverity`; `daysUntilRefill(inventoryCount:Int?, dailyRate:Double)->Int?`; `adherencePercent(taken:Int, expected:Int)->Double`; `calculateStreak(dateStringsNewestFirst:[String], today:String)->Int`; `clampEffectiveDays(rangeFrom:Date, rangeTo:Date, startedAt:Date, endedAt:Date?)->Int`; `startOfDay(_:Date, timeZone:)->Date`; `localDateString(_:Date, timeZone:)->String`; `localDayOfWeek(_:Date, timeZone:)->Int`; `formatTimeSince(_:Date, now:Date)->String`; `formatDueIn(msUntilDue:Double)->String`; `buildSparklineShape(values:[Double], width:Double, height:Double, strokeWidth:Double=1.5)->SparklineShape`; `SparklineShape{line:String, area:String, dotX:Double?, dotY:Double?}`.
- `MedTrackerData`: records `Medication`/`MedicationSchedule`/`DoseLog`/`InventoryEvent`/`AuditLog`/`Profile`/`Settings`/`OutboxEntry` (all `Sendable`, epoch-`Double` timestamps; computed `dosageAmountDecimal`/`intervalHoursDecimal`/`daysOfWeekArray`/`sideEffectsArray`); `SideEffectEntry(name:String, severity:String)`; `MedicationFields(name:dosageAmount:String, dosageUnit:form:category:colour:colourSecondary:String?, pattern:notes:String?, scheduleType:scheduleIntervalHours:String?, inventoryCount:Int?, inventoryAlertThreshold:Int?)`; `MedicationScheduleInput(scheduleKind:String, timeOfDay:String?, intervalHours:String?, daysOfWeek:[Int]?, sortOrder:Int, effectiveFrom:Date, effectiveTo:Date?)`; `MedTrackerDatabase.open(path:String?=nil) throws -> DatabaseQueue`; `Medication.fetchOwned(_ db:Database, userId:String, id:String) throws -> Medication?`; registered SQL `localDate(epochSeconds, tzIdentifier)`.
- `MedTrackerSync`: `SyncEngine` actor `init(config:SyncConfig, dbWriter:any DatabaseWriter, tokenStore:any TokenStore, transport:HTTPTransport=URLSessionTransport())`, `login/verifyTOTP/signInWithApple`, `enqueue(type:payload:localEntityId:localEntityKind:) throws -> OutboxEntry`, `sync() async throws -> SyncOutcome{fullResync:Bool, pushed:DrainResult, pulledMedications:Int, pulledDoseLogs:Int}`; `OutboxStore(dbWriter:)`; `EntityKind: String`(`.medication/.doseLog="dose_log"`); `StoredSession{token:String, userId:String}`; `TokenStore` protocol; `KeychainTokenStore(service:account:)`; `InMemoryTokenStore()`; `HTTPTransport` protocol; `LoginOutcome{.session(token:String, user:SessionUser)/.totpChallenge(preAuthToken:String)}`; `SessionUser{id,email,name:String; avatarUrl:String?; timezone:String; twoFactorEnabled,emailVerified:Bool}`; `APIError{.badRequest(String)/.unauthorized/.emailConflict/.rateLimited(retryAfter:Int)/.server(status:Int)/.transport(String)/.decoding(String)}`; `JSONValue` enum; `SyncConfig.production`.

### Task 5 — MedTrackerSync tx-joining enqueue (§8-#1)
```swift
extension OutboxStore {
    /// Inserts the pending row inside the CALLER's transaction (no internal db.write),
    /// so the optimistic state effect + this enqueue commit atomically (§4.2).
    @discardableResult
    public func enqueue(_ db: Database, type: String, payload: JSONValue,
                        localEntityId: String? = nil,
                        localEntityKind: EntityKind? = nil) throws -> OutboxEntry
}
// Optional passthrough:
extension SyncEngine {
    @discardableResult
    public func enqueue(_ db: Database, type: String, payload: JSONValue,
                        localEntityId: String? = nil,
                        localEntityKind: EntityKind? = nil) throws -> OutboxEntry
}
```

### Task 4 — MedTrackerData state-only writer (§8-#5)
```swift
public enum StateMedicationWriter {
    /// Re-exposed normalization (mirrors MedicationRepository.makeSchedule, now public):
    /// time_of_day kept only on fixed_time; interval_hours only on interval;
    /// days_of_week only on non-empty fixed_time (empty → nil).
    public static func makeSchedule(medicationId: String, userId: String,
                                    input: MedicationScheduleInput, createdAt: Double) -> MedicationSchedule
    /// State-only upsert inside the CALLER's txn — NO audit_log, NO own db.write.
    /// isCreate=false + id not found/owned → returns nil (no side effect).
    @discardableResult
    public static func upsert(_ db: Database, userId: String, id: String, isCreate: Bool,
                              fields: MedicationFields, schedules: [MedicationScheduleInput],
                              now: Date) throws -> Medication?
}
```

### Tasks 1–3 — MedTrackerData query/aggregation surface (§8-#2/3/4)
```swift
extension Medication {
    static func fetchActive(_ db: Database, userId: String) throws -> [Medication]     // is_archived=0, order sort_order
    static func fetchArchived(_ db: Database, userId: String) throws -> [Medication]
}
extension MedicationSchedule {
    static func groupedByMedication(_ db: Database, userId: String) throws -> [String: [MedicationSchedule]]
}
extension InventoryEvent {
    static func history(_ db: Database, userId: String, medicationId: String) throws -> [InventoryEvent] // created_at DESC
}

public struct DailyDoseCount: Decodable, FetchableRecord, Sendable, Equatable {
    public var medicationId: String    // "medication_id"
    public var localDay: String        // localDate(taken_at,:tz), "yyyy-MM-dd"  ("local_day")
    public var totalQuantity: Int      // SUM(quantity) of taken   ("total_quantity")
}
public struct PerMedStat: Decodable, FetchableRecord, Sendable, Equatable {
    public var medicationId: String
    public var taken7Count: Int              // COUNT taken in last 7d
    public var lastTakenAt: Double?          // MAX(taken_at) taken, epoch
    public var thirtyDayQuantity: Int        // SUM(quantity) taken in last 30d
}
public enum DoseAggregations {
    public static func dailyTakenQuantity(_ db: Database, userId: String, tz: String,
                                          fromEpoch: Double, toEpoch: Double) throws -> [DailyDoseCount]  // 14-day sparkline
    public static func perMedStats(_ db: Database, userId: String,
                                   now: Double) throws -> [PerMedStat]                                    // §8-#3b/c
    public static func distinctTakenLocalDatesNewestFirst(_ db: Database, userId: String,
                                                          tz: String) throws -> [String]                  // §8-#3d streak (unbounded)
}

public struct HistoryRow: Decodable, FetchableRecord, Sendable, Equatable {
    public var doseId: String; public var medicationId: String
    public var medicationName: String; public var dosageAmount: String; public var dosageUnit: String
    public var colour: String; public var colourSecondary: String?; public var pattern: String
    public var quantity: Int; public var takenAt: Double; public var status: String
    public var notes: String?; public var sideEffects: String?     // JSON text
    public var localDay: String                                     // localDate(taken_at,:tz)
}
public struct HistoryFilter: Sendable, Equatable {
    public var medicationId: String?; public var status: String?        // "taken"|"skipped"
    public var fromEpoch: Double?; public var toEpoch: Double?          // sargable UTC bounds
    public var notesQuery: String?; public var sideEffectName: String?; public var sideEffectSeverity: String?
}
public enum DoseLogQueries {
    /// One prepared statement; each filter an optional (:x IS NULL OR predicate) bind;
    /// ORDER BY d.taken_at DESC; grouping key via localDate(taken_at,:tz); growing LIMIT.
    public static func page(_ db: Database, userId: String, tz: String,
                            filter: HistoryFilter, limit: Int) throws -> [HistoryRow]
}
```

### Task 7 — AppEnvironment (§2.4)
```swift
@MainActor public final class AppEnvironment {
    public let dbWriter: any DatabaseWriter
    public let tokenStore: any TokenStore
    public let syncEngine: SyncEngine
    public static func live() throws -> AppEnvironment
    public static func testing(transport: HTTPTransport,
                               tokenStore: any TokenStore = InMemoryTokenStore()) throws -> AppEnvironment
}
```

### Task 8 — Adapters (§4.1)
```swift
public enum RecordAdapters {
    public static func scheduleRow(_ r: MedicationSchedule) -> ScheduleRow
        // ScheduleRow(kind: ScheduleKind(rawValue: r.scheduleKind) ?? .prn,
        //             intervalHours: r.intervalHoursDecimal, timeOfDay: r.timeOfDay, daysOfWeek: r.daysOfWeekArray)
    public static func doseEvent(_ d: DoseLog) -> DoseEvent
        // DoseEvent(id: d.id, medicationId: d.medicationId,
        //           takenAt: Date(timeIntervalSince1970: d.takenAt), status: doseStatus(d.status))
    public static func pattern(_ m: Medication) -> MedicationPattern     // MedicationPattern(rawValue: m.pattern) ?? .solid
    public static func doseStatus(_ raw: String) -> DoseStatus           // "skipped"→.skipped, "missed"→.missed, else .taken
}
```

### Task 9 — SessionModel (§3)
```swift
public enum AuthPhase: Equatable {
    case launching
    case disclaimerConsent
    case unauthenticated(error: AuthError?)
    case totpChallenge(preAuthToken: String, error: AuthError?)
    case firstSync(FirstSyncState)
    case authenticated
}
public enum AuthError: Equatable {
    case invalidCredentials, incorrectCode
    case rateLimited(retryAfter: Int)
    case transport, server, sessionExpired, emailConflict
}
public struct FirstSyncState: Equatable, Sendable {
    public var pulledMedications: Int; public var pulledDoseLogs: Int; public var isIndeterminate: Bool
}
@MainActor @Observable public final class SessionModel {
    public private(set) var phase: AuthPhase
    public init(env: AppEnvironment, defaults: UserDefaults = .standard)
    public func start() async                                   // .launching → disclaimer flag + tokenStore.load()
    public func acknowledgeDisclaimer()                         // persist flag, proceed
    public func signIn(email: String, password: String) async  // → .totpChallenge | .firstSync
    public func verify(code: String) async                     // → .firstSync (retains preAuthToken on failure)
    public func signInWithApple(identityToken: String, fullName: String?) async
    public func runSync() async                                 // the ONLY sync funnel; APIError.unauthorized → clear + .unauthenticated(.sessionExpired)
    public func signOut()
}
```

### Task 10 — WriteCoordinator (§4; contract §4 payloads)
```swift
@MainActor public final class WriteCoordinator {
    public init(dbWriter: any DatabaseWriter, outbox: OutboxStore, userId: String)   // userId injected at construction (A6)

    // log_dose {medicationId, quantity?, takenAt?, notes?, sideEffects?} → {id}; reconcile .doseLog
    public func logDose(medicationId: String, quantity: Int, takenAt: Date?,
                        notes: String?, sideEffects: [SideEffectEntry]?) async throws
    // skip_dose {medicationId} → {id}; reconcile .doseLog (slotExpectedTime is optimistic-local only)
    public func skipDose(medicationId: String, slotExpectedTime: Date) async throws
    // edit_dose {doseId, takenAt?, quantity?, notes?, sideEffects?|null} → {updated}; no reconcile
    //   double-optional: .some(nil) ⇒ send explicit null (clear); .none ⇒ omit key
    public func editDose(doseId: String, takenAt: Date?, quantity: Int?,
                         notes: String??, sideEffects: [SideEffectEntry]??) async throws
    // delete_dose {doseId} → {deleted}
    public func deleteDose(doseId: String) async throws
    // refill {medicationId, quantity, note?|null} → {previousCount,newCount}   (amount → payload "quantity")
    public func refill(medicationId: String, amount: Int, note: String?) async throws
    // adjust_inventory {medicationId, newCount, note?|null} → {previousCount,newCount,quantityChange}
    public func adjustInventory(medicationId: String, newCount: Int, note: String?) async throws
    // upsert_medication_with_schedules {id?, medication:MedicationInput, schedules:ScheduleInput[]}
    //   → {medication}; create reconciles .medication via result.medication.id
    @discardableResult
    public func upsertMedication(id existing: String?, fields: MedicationFields,
                                 schedules: [MedicationScheduleInput]) async throws -> String   // returns local (or existing) med id
    // archive/unarchive {medicationId} → {ok:true}; no reconcile
    public func archive(medicationId: String) async throws
    public func unarchive(medicationId: String) async throws
    // reorder → decomposed into pairwise reorder {medId1, medId2} swaps (§5.2.2); no reconcile
    public func reorder(orderedMedicationIds: [String]) async throws
}
```
Each method body: exactly one `try await dbWriter.write { db in <state effect per §4.3>; try outbox.enqueue(db, type:…, payload:…, localEntityId:…, localEntityKind:…) }`; `throws` on **optimistic/local failure only** (`CHECK` violation or client bound like quantity 1–10) → rollback; sync failures stay durable in the outbox. Integer JSON renders whole (`2`, not `2.0`).

### Task 11 — SyncScheduler (§4.4)
```swift
@MainActor public final class SyncScheduler {
    public init(debounce: Duration = .milliseconds(500), runSync: @escaping @Sendable () async -> Void)
    public func requestSync()   // debounced; drops if a sync is already in flight; routes through runSync (→ SessionModel.runSync)
}
```

### Task 12 — AppModel + SidebarItem (§2.5)
```swift
public enum SidebarItem: Hashable, CaseIterable { case dashboard, medications, history }
@MainActor @Observable public final class AppModel {
    public var selection: SidebarItem?
    public let dbWriter: any DatabaseWriter
    public let userId: String
    public let writeCoordinator: WriteCoordinator
    public let syncScheduler: SyncScheduler
    public private(set) var profile: Profile?
    public var timeZone: TimeZone { profile.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone(identifier: "UTC")! }
    public func observeProfile() async
}
```

### Tasks 13–15 — Per-screen stores + Sendable snapshot value types (§2.6, §5)
```swift
@MainActor @Observable public final class DashboardStore {
    public private(set) var snapshot = DashboardSnapshot.empty
    public private(set) var loadError: Error?
    public init(dbWriter: any DatabaseWriter, userId: String)   // captured once via State(initialValue:)
    public func observe() async                                 // view-driven; CancellationError not surfaced
}
public struct DashboardSnapshot: Sendable, Equatable {
    public var timeZoneID: String
    public var isEmpty: Bool                        // activeMedIds.isEmpty → OnboardingCTA
    public var summary: SummaryStripVM
    public var refills: [RefillRowVM]
    public var quickLog: [QuickLogItemVM]
    public var myDay: [MyDayBucketVM]
    public var todayFeed: [TodayFeedRowVM]
    public static let empty: DashboardSnapshot
}
public struct SummaryStripVM: Sendable, Equatable { public var takenCount, scheduledCount: Int; public var adherencePercent: Double; public var streak: Int }
public struct RefillRowVM: Sendable, Equatable, Identifiable { public var id: String; public var name: String; public var colour: String; public var colourSecondary: String?; public var pattern: MedicationPattern; public var severity: RefillSeverity; public var daysUntilRefill: Int?; public var isLowInventory: Bool }
public struct QuickLogItemVM: Sendable, Equatable, Identifiable { public var id: String; public var name: String; public var colour: String; public var colourSecondary: String?; public var pattern: MedicationPattern; public var textColor: ReadableTextColor }
public struct MyDayBucketVM: Sendable, Equatable, Identifiable { public var id: String; public var bucket: TimeOfDayBucket; public var slots: [MyDaySlotVM] }
public struct MyDaySlotVM: Sendable, Equatable, Identifiable { public var id: String; public var medicationId: String; public var name: String; public var colour: String; public var colourSecondary: String?; public var pattern: MedicationPattern; public var expectedTime: Date; public var status: SlotStatus }
public struct TodayFeedRowVM: Sendable, Equatable, Identifiable { public var id: String; public var medicationId: String; public var name: String; public var colour: String; public var colourSecondary: String?; public var pattern: MedicationPattern; public var expectedTime: Date; public var lastTakenAt: Date? }

@MainActor @Observable public final class MedicationsStore {
    public private(set) var active: [MedicationCardVM] = []
    public private(set) var archived: [MedicationCardVM] = []
    public private(set) var loadError: Error?
    public init(dbWriter: any DatabaseWriter, userId: String)
    public func observe() async
}
public struct MedicationCardVM: Sendable, Equatable, Identifiable {
    public var id: String                          // medicationId
    public var name, dosageAmount, dosageUnit, form, category: String
    public var colour: String; public var colourSecondary: String?
    public var pattern: MedicationPattern; public var textColor: ReadableTextColor
    public var isArchived: Bool
    public var refillSeverity: RefillSeverity; public var daysUntilRefill: Int?; public var isLowInventory: Bool
    public var adherencePercent: Double
    public var sparkline: SparklineShape           // 14-day
    public var timingBadge: TimingBadgeVM?         // §5.2.5 composition
}
public struct TimingBadgeVM: Sendable, Equatable { public var status: TimingStatus; public var minutesUntilDue: Int? }

@MainActor @Observable public final class HistoryStore {
    public private(set) var sections: [HistorySection] = []
    public private(set) var hasMore = false
    public private(set) var loadError: Error?
    public var filter = HistoryFilter()            // change resets loadedPages=1
    public init(dbWriter: any DatabaseWriter, userId: String, writeCoordinator: WriteCoordinator, pageSize: Int = 20)
    public func observe() async
    public func loadMore()                         // loadedPages += 1, rebuild observation
}
public struct HistorySection: Sendable, Equatable, Identifiable {
    public var id: String                          // local_day
    public var label: String                       // "Today"/"Yesterday"/absolute (Profile.tz)
    public var rows: [HistoryRowVM]
}
public struct HistoryRowVM: Sendable, Equatable, Identifiable {
    public var id: String                          // doseId
    public var medicationId, medicationName, dosageAmount, dosageUnit, colour: String
    public var colourSecondary: String?; public var pattern: MedicationPattern; public var textColor: ReadableTextColor
    public var quantity: Int; public var takenAt: Date; public var status: DoseStatus
    public var notes: String?; public var sideEffects: [SideEffectEntry]
}
```

### Task 16 — MedicationDraft (§5.2.3)
```swift
@MainActor @Observable public final class MedicationDraft {
    public enum Mode: Equatable { case new, edit(id: String) }
    public init(mode: Mode)                        // .edit hydrates from records
    public var mode: Mode
    // identity/dosage/style/inventory fields + schedule rows …
    public func validate() -> [String]             // client-side (master §8.1) before optimistic write
    public func fields() -> MedicationFields
    public func schedules() -> [MedicationScheduleInput]   // sortOrder = row index; effectiveFrom defaults now
}
```

### Contract §4 result shapes the write layer branches on (pinned)
`log_dose`/`skip_dose` → `{id}` (both reconcile `.doseLog` via `result.id`); `upsert_medication_with_schedules` → `{medication:<raw row|null>}` (reconcile `.medication` via `result.medication.id`; `null` only on update whose id isn't found/owned); `edit_dose` → `{updated:Bool}`; `delete_dose` → `{deleted:Bool}`; `refill` → `{previousCount,newCount}`; `adjust_inventory` → `{previousCount,newCount,quantityChange}`; `archive`/`unarchive`/`reorder` → `{ok:true}` (none reconcile). `edit_dose` clears `sideEffects` on explicit `null`, leaves it on `undefined`.

---

### Notes for detailed task-authors (open confirmations, don't block)
- **SummaryStrip adherence denominator** (all-day vs due-so-far) is unresolved (§8-#12) — pick one, pin it in the task, cite the web component.
- **History**: confirm SQLite **json1** enabled (§8-#13), `taken_at` vs `logged_at` grouping (§8-#14), notes-search scope (§8-#15) before locking parity.
- **Exact copy strings** (verbatim disclaimer, toasts, validation/labels/CTA) are out-of-sandbox in the SvelteKit components (§8-#12) — spec pins behaviours, not literals.
- **`§2.1` vs `§8` query home**: query row types + SQL live in `MedTrackerData` (tested there); `MedTrackerApp` stores consume them in `ValueObservation`. Do not duplicate.
- **Snapshot value types are the deterministic UI seam** (§2.6/A2-i): every `MedTrackerUI` view is init-injected with its `Sendable` snapshot + fixed `now`/tz — never touches GRDB.

---

---

## Execution

**Plan is decomposition + interface contract + reconciliations.** Per the repo's SDD workflow (as in 1a/1b), each task is executed by a fresh subagent driven from a per-task brief written into `.superpowers/sdd/` at execution time, with a code-review gate before commit; the detailed TDD steps (failing test → implement → verify → commit) are produced in those briefs, honoring §Tasks + the reconciliations + Appendix A verbatim.

Two execution options:
1. **Subagent-Driven (recommended)** — `superpowers:subagent-driven-development`: fresh subagent per task + two-stage review, matching how 1a/1b were built.
2. **Inline** — `superpowers:executing-plans`: batch execution with review checkpoints.

> **Note on this plan's provenance:** the task blocks were authored in full (detailed TDD code) and adversarially reviewed; a session-usage limit (resets 18:30 Europe/London) interrupted the pass that folds the Tasks 1–22 fixes inline, so those fixes live in §Cross-task reconciliations above (Tasks 23–27 already have them applied). The detailed authored TDD code is retained as reference to seed the execution briefs. After the limit resets, this plan can be re-issued with every fix folded inline at 1b altitude if preferred.
