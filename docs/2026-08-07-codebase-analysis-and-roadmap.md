# MedTracker for Mac — Codebase Analysis & Roadmap

**Date:** 2026-08-07
**Basis:** three independent audits (architecture/Swift-quality, product/roadmap, security/privacy) over the phase-1c worktree, plus a verified build/test/lint baseline.

---

## 1. Where the project actually stands

**The engine is built and well-tested. The car has no body.**

| Layer                                                             | State                                                       |
| ----------------------------------------------------------------- | ----------------------------------------------------------- |
| `MedTrackerCore` — pure domain, ported 1:1 from TypeScript        | ✅ complete, 208 tests                                      |
| `MedTrackerData` — GRDB schema, migrations, queries, repositories | ✅ complete, 61 tests                                       |
| `MedTrackerSync` — API client, outbox, reconciler, sync engine    | ✅ complete, 47 tests                                       |
| `MedTrackerApp` — stores, view-models, write path, session        | ✅ complete, 74 tests                                       |
| `MedTrackerUI` — SwiftUI views                                    | ⚠️ **3 primitives only** (Theme, PatternFill, OutlinedText) |
| App target (`@main`, entitlements, Info.plist)                    | ❌ **does not exist**                                       |

Of ~5,900 lines of production Swift, roughly **229 are SwiftUI**. There is no `App/` directory, no `@main`, and `project.yml` still builds only the throwaway `MedTrackerSpike`. Every screen exists as a fully-tested view-model with **zero pixels attached to it**.

Concretely, the user still cannot: launch anything, accept the disclaimer, log in, sync their data, see a dashboard, or log a dose. All of that logic is written and tested — it is simply not reachable.

**Baseline after this session's fixes:** `swiftformat` 0/110 · `swiftlint --strict` 0 violations in 104 files · 404 tests + 5 render-smoke, all green, all 6 packages now gated in CI.

---

## 2. What this session fixed

1. **CI was red _and_ blind.** `swiftformat --lint Packages` (a CI step) failed on 29/110 files, blocking every PR — while SwiftLint and `swift test` covered only Core/Data/Sync, leaving the ~1,800-line write path entirely ungated. Tree formatted; all six packages now tested and linted in CI.

2. **The snapshot suite was environment-coupled.** Every reference PNG recorded 2026-07-26 failed on 2026-08-07 _on the same machine_ (toolchain drift), and none would ever match a CI runner. Snapshots now default to a **render smoke test** (deterministic anywhere); pixel comparison is opt-in via `SNAPSHOT_PIXEL=1`. The semantics pixels were the only witness to are now asserted directly.

3. **`adjust_inventory` no-op guard (HIGH — data correctness).** It compared `Int?` to `Int`, so an untracked medication (`inventoryCount == nil`) adjusted to `0` was accepted locally, while the server — computing `newCount - (previousCount ?? 0)` — rejects it as a no-op. The outbox row parks as `failed` and the server's `updated_at` never advances, so **no delta pull can ever heal the wrong local count**. Fixed to match reference semantics, with regression tests.

4. **Flaky `SyncSchedulerTests`** — asserted after fixed sleeps; now polls for the observable outcome.

---

## 3. The single most important recommendation

**Build the app target now, before writing any more SwiftUI.**

The plan orders the app target (Tasks 25–26) _after_ six packages of screens (19–24). That means writing every screen with **no way to run any of it**, verified only by image diffs. Inverting this:

- turns six blind tasks into six verifiable ones;
- surfaces signing, entitlement, and asset-catalog problems while they are cheap;
- lets the owner log in against the live backend and watch real Neon history land in SQLite — converting every later screen from "does the snapshot match?" to "does my data look right?".

**Recommended order:** `25 + 26` (app target + project.yml, wired to a placeholder shell) → **24** (disclaimer → login → TOTP → first-sync → `MainShell`) → `19` → `20` → `21` → `22a` → `22b` → `23` → `27`.

Task 24 is the highest-value screen work because it is the _only_ path by which real data ever enters the app.

**Blocker to clear first:** the verbatim medical-disclaimer copy is unsourced (it lives in the SvelteKit registration-consent component). It is required in three places — the first-run gate, the medication form, and later every export. Extract it before starting Task 24.

---

## 4. Prioritized technical backlog

### High

- **Duplicated business logic.** `MedicationRepository` / `DoseRepository` / `InventoryRepository` are referenced by _nothing_ outside their own tests — `WriteCoordinator` reimplements the same clamp/restore/refill/adjust math inline. The `adjust_inventory` bug above is exactly this risk materialising. Either delete the repositories or extract the shared math into one tested helper both paths call.
- **`Medication.fetchOwned` implemented three times** (`MedicationQueries.swift:15` internal, plus private copies in `WriteCoordinator` and `MedicationsStore`). This is an owner-scoping predicate — precisely the security-relevant check that must have one implementation. Make it `public`, delete the copies.
- **No logging anywhere.** Every `ValueObservation` loop swallows non-cancellation errors with only a comment. A disk-full write or post-OS-upgrade schema mismatch would silently freeze a screen with no trail in Console.app. Add one `os.Logger` per package and log at `.error` in every swallowed catch.

### Medium

- **`@preconcurrency import MedTrackerData`** in `WriteCoordinator` masks Sendable diagnostics for the _whole_ module. The real fix is two lines: declare `MedicationFields` and `MedicationScheduleInput` as `Sendable` (both are plain value structs) and drop the import attribute.
- **`SyncApplier` writes `Profile.createdAt/updatedAt` as epoch 0** on every sync (`WireMapping.profile(profile, now: 0)`), while `SyncResponse.serverTime` is fetched and never used. Not user-visible today; wrong data durably on disk.
- **Stores hold `any DatabaseWriter` but only ever read.** Type them `any DatabaseReader` so no future code can bypass `WriteCoordinator` and write to SQLite without enqueueing to the outbox.
- **`DashboardSnapshot.build` is 112 lines** assembling five independent sections that already have comment boundaries — mechanical extraction, no behaviour change.
- **Force-unwrapped `medByID[slot.medicationId]!`** in the My-Day and Today-feed builders. Safe today by an invariant enforced across a module boundary only by convention; `guard let … else { continue }` degrades by dropping a row instead of crashing the landing screen.

### Security (audit found the core clean — no SQL injection, no PHI logging, HTTPS-only, no analytics SDKs)

- **Keychain hardening** — currently `kSecAttrAccessibleAfterFirstUnlock` with no `kSecUseDataProtectionKeychain`, so the accessibility class is inert on macOS's file-based keychain. The bearer token is a 30-day sliding credential; do this before any real device leaves your hands.
- **PHI unencrypted at rest** — a documented, deliberate trade-off (FileVault + sandbox only). Worth restating given the Health & Fitness category, especially if FileVault is ever off or a backup target is unencrypted.
- **`Spike/` logs response bodies and a token prefix** — confirm the prototype target is excluded from the release archive.

---

## 5. Scope holes not in any plan

1. **Account deletion has no backend route.** Guideline 5.1.1(v) makes in-app account deletion mandatory for an account-based app, and the design spec asserts "backend flow exists" — but the vendored `/api/v1` contract has none. This is a `medication-tracker`-repo task that sits outside every existing phase plan, and it is a hard App Review rejection trigger.
2. **Three backend commands are built server-side but unwired:** `update_preferences`, `wipe_dose_history`, `wipe_archived_medications`, plus `GET /export/full`. These are the entire backend half of Settings → Data/Privacy and the JSON backup.
3. **Paid-account entitlements have lead time:** `com.apple.developer.applesignin` (required by 4.8, since the backend offers Google/GitHub) and `usernotifications.time-sensitive` (Phase 2's headline feature). Neither can be assumed; both cost nothing to start now.

---

## 6. Feature ideas worth building

Ranked by value for a single-user, desk-bound macOS tracker whose companion is an Android browser.

| Idea                                                     | Why it matters                                                                                                                                                                                                                                                 | Effort                     |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| **Menu-bar quick-log** (`MenuBarExtra` + `SMAppService`) | Phase 2 already needs a resident agent to keep interval reminder chains alive. Making it a _product feature_ means the most-used action costs one click and the app never needs to be open. This is the difference between "an app I open" and "an app I use". | 1–1.5 wk on top of Phase 2 |
| **App Intents / Shortcuts**                              | Unlocks Siri, Spotlight, and Focus/time automations; the cheapest thing that makes this read as a modern native app. Run intents in-process so writes go through the real `WriteCoordinator` + outbox.                                                         | 1–1.5 wk                   |
| **Undo on quick-log** (⌘Z + toast action)                | A mis-tapped pill writes a dose, decrements inventory, _and_ enqueues a command. `delete_dose` already does the unclamped restore. Without undo the fix is a trip to History.                                                                                  | 1–2 days                   |
| **Log a dose at a slot time**, not just "now"            | `logDose(takenAt:)` already accepts it; the UI only ever passes `now`. A dose taken at 08:00 and logged at 18:00 buckets and slot-matches wrong (±1 h tolerance) — it silently corrupts adherence numbers.                                                     | 2–3 days                   |
| **"Why didn't I get a reminder?" log**                   | The `reminder_event` table exists precisely for this audit trail and currently has no reader. Notification bugs are otherwise invisible — and transparency reads well in Review notes.                                                                         | 2–3 days                   |
| **Interval "schedule-creation anchor"** (opt-in)         | Retires the inherited quirk where a brand-new interval prescription never reminds until the first dose is logged. Opt-in preserves web parity by default.                                                                                                      | 2–3 days                   |
| **⌘K command palette**                                   | Very Mac-native, and a natural home for the ⌘1–9 / `n` / `/` shortcuts the spec already mandates.                                                                                                                                                              | 1 wk                       |

**Architectural note:** if widgets or out-of-process intents are ever wanted, move the SQLite file into an **App Group container** and add a `DatabasePool` factory _now_ — retrofitting the container path later is a user-data migration; today it is free.

**Explicitly decline:** HealthKit (does not exist on macOS — no framework to link), CloudKit sync (the backend _is_ the sync fabric; adding CloudKit recreates the exact second silo the architecture was designed to avoid), and SQLCipher before v1.

---

## 7. Honest schedule

| Phase | Remaining                                                        | Estimate                                                                                                                                                                                |
| ----- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1c    | App target + 7 screen tasks + CI polish                          | 3–4 wk                                                                                                                                                                                  |
| 2     | Notifications, Analytics, Settings, export, app lock, openFDA    | **9–11 wk** (the spec's 4–6 wk is optimistic: Analytics needs a whole new aggregation layer, and the accent picker is a theming refactor since `Theme.accent` is a hard-coded constant) |
| 3     | Accessibility, privacy manifest, screenshots, TestFlight, Review | 3–4 wk + unknown backend work for account deletion + one rejection round-trip                                                                                                           |
