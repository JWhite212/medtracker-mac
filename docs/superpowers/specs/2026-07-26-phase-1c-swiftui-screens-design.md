# Phase 1c — SwiftUI App Target + Screens (Design Spec)

**Status:** draft 2026-07-26. Successor to Phase 1b (`docs/superpowers/specs/2026-07-26-phase-1b-sync-engine-design.md`, merged). Precedes Phase 2 (differentiators: notification engine, Analytics, full Settings, exports, app lock, openFDA checker) and the ship phase (App-Review completeness: account-deletion UI, SIWA live path, keychain hardening, XCUITest).

**Goal:** Put a native SwiftUI app on top of the three finished, tested packages (`MedTrackerCore`, `MedTrackerData`, `MedTrackerSync`) — an app shell + composition root, a first-run consent gate, auth/session gating, and the three read-heavy screens (Dashboard, Medications, History) — with every user action wired through the **thin optimistic + enqueue write path** whose mechanism Phase 1b built and explicitly deferred the wiring of (Phase 1b §7.1). The result is a signable, sandboxed macOS 15 app that logs in, runs a first full sync, and lets the owner browse and mutate their real data offline, with all writes converging on the server.

**Altitude — 1c is explicitly pre-submission.** It is built to _build, sign, and run_ cleanly, not to clear App Review. `PrivacyInfo.xcprivacy` is included only so the target signs; account-deletion UI (master 5.1.1v), SIWA live-path completeness (4.8), the "Load sample data" review seed (§13), and keychain hardening (§11) are all **ship-phase**, not 1c.

**Reference (source of truth for screens/behaviours/design language):** the master design spec `docs/design/2026-07-25-macos-app-design.md` (esp. §6, §6.1, §8, §10, §10.1, §10.2, §11, §12, §13, §15). Where a screen behaviour and this spec disagree, the master spec wins. Phase 1c changes **no** package public behaviour except the small, enumerated API additions in §8; it adds two new SPM library packages and the app target.

**Reference (write path):** `medication-tracker/docs/api-v1-contract.md` is the source of truth for the ten command `type` strings and their payload JSON. It is **not yet in this repo** and must be copied in before the write-path tasks (§0(c), §4, §8-#10). The auth path is fully modelled/tested in `MedTrackerSync` and is unblocked today.

---

## 0. Decisions needing owner sign-off

Four boundary/structure choices exceed or reinterpret the confirmed 1c scope and need an explicit yes before implementation. Recommendations are mine.

- **(a) Module split — two new SPM library packages + one test-only package, not UI-in-the-app-target.** `MedTrackerApp` (stores / view-models / write-layer / adapters / queries) + `MedTrackerUI` (SwiftUI views + design system) + `MedTrackerTestSupport` (test-only), versus the confirmed "app target linking the 3 packages." **Recommend YES** — it makes the write path and view-models `swift test`-able headlessly, matches the 1a/1b package discipline, and master §6 already envisions multiple packages.
- **(b) No `.xcworkspace` — xcodegen local-`path:` package embedding in the generated `.xcodeproj`.** Reuses the existing `project.yml`/Spike setup instead of a hand-managed workspace (the confirmed scope said "workspace"). **Recommend YES.**
- **(c) Contract copy-in.** `api-v1-contract.md` must be copied into `medtracker-mac` before the write-path implementation tasks. **Recommend the owner copy it into `docs/design/`** (same home as this design spec); auth-path work proceeds in parallel.
- **(d) SIWA scope.** The button + full `SyncEngine.signInWithApple` wiring ship and compile, but the live path (paid `com.apple.developer.applesignin` capability + confirmed backend `/auth/apple`) is a **manual gated smoke, not a CI/1c acceptance gate**. **Recommend YES.**

| #   | Decision                                      | Recommendation     | Owner: Approve / Reject | Date |
| --- | --------------------------------------------- | ------------------ | ----------------------- | ---- |
| a   | Two library packages + test-support           | YES                |                         |      |
| b   | xcodegen embedding, no workspace              | YES                |                         |      |
| c   | Copy `api-v1-contract.md` into `docs/design/` | YES (owner action) |                         |      |
| d   | SIWA live path = manual gated smoke           | YES                |                         |      |

---

## 1. Scope

### 1.1 In scope (Phase 1c)

| Area                       | What ships                                                                                                                                                                                                                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **App shell**              | New SwiftUI `MedTracker` app target + xcodegen config linking the three local SPM packages; two new SPM library packages (`MedTrackerApp`, `MedTrackerUI`) + one test-support package; composition root / `AppEnvironment`; `NavigationSplitView` sidebar with exactly three destinations.      |
| **First-run consent**      | Blocking medical-disclaimer consent gate (verbatim text, `disclaimerAcknowledged` in `UserDefaults`) before the app is usable (§3, master §13/1.4.1).                                                                                                                                           |
| **Auth / session gating**  | Email+password login, TOTP challenge, Keychain session, 401→re-login, first-run full-sync gate. Sign in with Apple wired to `SyncEngine.signInWithApple`, **conditional** on backend SIWA availability + paid entitlement (§0(d), manual).                                                      |
| **Dashboard**              | SummaryStrip, RefillsCard, My-Day timeline (time-of-day groups), QuickLogBar pills (pattern bg + contrast text, qty 1–10, ~700 ms success flash), Today feed with overdue rows + Skip, TimeSince live counters, zero-meds onboarding CTA.                                                       |
| **Medications**            | List (MedicationCard: pattern swatch, refill/low chips, adherence mini-bar, 14-day sparkline), reorder, archived group; Med form + detail (identity/dosage/form/category/StylePicker/ScheduleSection/inventory; disclaimer notice; refill/adjust + inventory-event history; archive/unarchive). |
| **History (`/log`)**       | Filter bar (med/status/date/notes-search/side-effects), profile-tz local-date grouping (Today/Yesterday/…), pagination, TimelineEntry edit sheet + delete.                                                                                                                                      |
| **Optimistic-write layer** | All ten commands wired as thin state-effect + outbox-enqueue (`log_dose`, `skip_dose`, `edit_dose`, `delete_dose`, `refill`, `adjust_inventory`, `upsert_medication_with_schedules`, `archive`, `unarchive`, `reorder`).                                                                        |
| **Design language**        | Dark-only theme tokens, 8 medication patterns as SwiftUI fills with `<20pt→gradient` degradation, `getReadableTextColor`, custom `Canvas`/`Path` sparkline, accessibility parity (VoiceOver, Dynamic Type, reduce-motion from system + synced pref).                                            |
| **Testing/CI**             | Mock-first hermetic `swift test` over the logic packages; snapshot tests under `xcodebuild`; app build lane; manual live smoke gated on backend.                                                                                                                                                |

### 1.2 Deferred to Phase 2 (stub/placeholder mention only)

| Deferred                                                                                            | 1c posture                                                                               |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Notification engine (`NotificationPlanner`, actions, suppression, tz/wake triggers, menu-bar agent) | Not built. Replan triggers on write/sync are Phase 2.                                    |
| Analytics screen (Insights, Heatmap, distributions, period control)                                 | **Sidebar entry omitted entirely** (§2.5), not a disabled stub.                          |
| Full Settings screens (Profile/Appearance/Notifications/Data/Privacy)                               | **No Settings screen** (§1.3); only a sidebar-footer account control + sync-status chip. |
| CSV/PDF export via `NSSavePanel`                                                                    | `Csv` Core helpers exist but unused; no export UI.                                       |
| App lock (`LocalAuthentication`) + re-auth gates; account-deletion UI                               | Not built (ship-phase / Phase 2).                                                        |
| openFDA interaction checker                                                                         | Detail renders a disabled "coming soon" `InteractionProbeCard` stub only.                |

### 1.3 Boundary decisions (confirmed with owner)

- **No dedicated Settings screen in 1c.** Timezone for all date bucketing comes from the synced `Profile.timezone` (single-row `Profile`, `id == 1`), **never** `TimeZone.current`. Accent stays the default `#6366f1`; the 10-preset picker (a Settings concern) is Phase 2. The one thing Settings would otherwise host — **Sign Out** and a **sync-status indicator** — lives in the sidebar footer (§2.5), not a destination.
- **The 1c↔2 line is "read + mutate the existing data model, converging on the server."** Anything that generates new device-side signal (notifications, analytics aggregates as a screen, exports) is Phase 2. The aggregation _math_ those screens need already exists in `MedTrackerCore`; 1c does not surface it.

---

## 2. Architecture

### 2.1 Module layout — testable libraries + a thin app shell

The stores, view-models, the optimistic-write layer, the record→lean-model adapters, and the design system live in SPM library packages, not the app target (§0(a)). The app target holds only what _cannot_ run under `swift test`.

```
Packages/
  MedTrackerCore/  MedTrackerData/  MedTrackerSync/   (existing — Swift 5 language mode)
  MedTrackerApp/          NEW library — @Observable @MainActor stores / view-models /
                          WriteCoordinator / SyncScheduler / SessionModel /
                          record→ScheduleRow·DoseEvent·ScheduleSlot adapters /
                          DoseLogQueries + aggregation queries. Depends on Core+Data+Sync.
                          NO SwiftUI rendering.  → swift test
  MedTrackerUI/           NEW library — SwiftUI Views + design system (pattern fills,
                          sparkline Path rendering, colour resolution). Depends on App+Core.
                          → snapshot-tested under xcodebuild
  MedTrackerTestSupport/  NEW test-only library — public HTTPTransport mock (promoted from
                          MedTrackerSyncTests/MockTransport), fixture/seed builders, fixed-clock.
App/  (xcodegen app target) — @main App, AppEnvironment composition root, KeychainTokenStore
                          wiring, DisclaimerConsentView, asset catalog, entitlements, Info.plist,
                          PrivacyInfo.xcprivacy. Near-zero logic.
```

**Justification.** An app-hosted XCTest bundle needs the app to launch (GUI session, signing, run loop) and does not compose with the fast `swift test` lane the three packages already run. An SPM library gets `swift test` for free and reuses the Phase 1b doubles verbatim: in-memory GRDB via `MedTrackerDatabase.open(path: nil)`, `InMemoryTokenStore`, and an `HTTPTransport` stub. A store test builds a real `SyncEngine(config:dbWriter:tokenStore:transport:)` from all three doubles and drives it with zero network. Keeping the target a shell means the un-unit-testable code is the code with almost nothing to test.

**Language mode.** `MedTrackerApp` / `MedTrackerUI` / the app target adopt **Swift 6 language mode + `SWIFT_STRICT_CONCURRENCY: complete`** (Xcode 26 / Swift 6.2 toolchain); the three ported packages stay in Swift 5 mode (`swiftLanguageMode(.v5)`). Interop is safe because those packages vend a `Sendable` public surface (records `Sendable`; `SyncEngine` an `actor`; `OutboxStore`/`SyncStateStore` `Sendable`) — with the caveat that strict-concurrency diagnostics do **not** propagate _into_ the packages, so their annotations are the contract, not a compiler-enforced guarantee.

### 2.2 Workspace + app target (xcodegen)

The current `project.yml` builds only `MedTrackerSpike` and references no packages. Add a top-level `packages:` map (local `path:` for the three shipped + two new library packages, plus the remote `SnapshotTesting` for the snapshot target) and the `MedTracker` application target (`type: application`, `platform: macOS`, `deploymentTarget: "15.0"`, `SWIFT_VERSION: "6.0"` + `SWIFT_STRICT_CONCURRENCY: complete`, `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_ENTITLEMENTS: App/MedTracker.entitlements`, `INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.healthcare-fitness`). Dependencies: `MedTrackerApp` + `MedTrackerUI` (transitively pulling Core/Data/Sync).

**Product name / bundle id `MedTracker` / `site.jamiewhite.medtracker`** deliberately match `KeychainTokenStore`'s default `service: "site.jamiewhite.medtracker"` (`TokenStore.swift`) and the API host `medication-tracker.jamiewhite.site`. (The Spike used `com.jamiewhite` / `public.app-category.medical`; both change here — §13 wants Health & Fitness.)

**No `.xcworkspace` (§0(b)).** xcodegen's local-`path:` entries embed the packages as references _inside_ the generated `.xcodeproj`; modern Xcode resolves local packages without a workspace. One generator (xcodegen), one generated artifact (git-ignored), `project.yml` + package sources as the durable source of truth.

**Keep the Spike** as a secondary, non-release target on its own Phase-0 go/no-go merit: it is the go/no-go harness and builds independently at no cost to the release target. (Its use as the time-sensitive-entitlement provisioning probe is a Phase-2 concern and not a reason to retain it now.)

### 2.3 Entitlements (1c only) — exactly two keys

New `App/MedTracker.entitlements`:

| Key                                 | Value  | Why                      |
| ----------------------------------- | ------ | ------------------------ |
| `com.apple.security.app-sandbox`    | `true` | Mandatory for MAS (§11). |
| `com.apple.security.network.client` | `true` | `/api/v1` login + sync.  |

- **Hardened Runtime** is the build setting `ENABLE_HARDENED_RUNTIME: YES`, not an entitlement key.
- **Keychain needs no entitlement in 1c.** `KeychainTokenStore` uses a plain `kSecClassGenericPassword` item keyed on `service`/`account` with no `kSecAttrAccessGroup`; under App Sandbox it lands in the app's default access group. `keychain-access-groups` is only for cross-app sharing (not done). The data-protection-keychain hardening is ship-phase (§2.6/A7, §8-#6) — **no third entitlement in 1c**.
- **`PrivacyInfo.xcprivacy` (build/sign only, not Review completeness):** `NSPrivacyTracking=false`; declare the required-reason API **`UserDefaults CA92.1`** (the `disclaimerAcknowledged` flag, §3) and `file-timestamp C617.1` if used; GRDB bundles its own manifest.
- **Explicitly excluded (Phase 2, per scope):** `usernotifications.time-sensitive`, `files.user-selected.read-write`, critical-alerts, CloudKit, and **`com.apple.developer.applesignin`** (§3.2 — kept out of default signing so automatic signing works on a free account; added by hand only for the SIWA live smoke).

### 2.4 Composition root / DI — `AppEnvironment`

A single composition root constructed once at launch, holding process-wide infrastructure. Plain `Sendable` infra, **not** `@Observable`; mutable UI/session state lives in `@Observable` models (§2.6, §3).

```swift
@MainActor final class AppEnvironment {
    let dbWriter: any DatabaseWriter     // DatabaseQueue from MedTrackerDatabase.open
    let tokenStore: any TokenStore       // KeychainTokenStore (live) / InMemoryTokenStore (tests)
    let syncEngine: SyncEngine           // actor, .production config

    static func live() throws -> AppEnvironment {
        let db  = try MedTrackerDatabase.open(path: databaseURL().path)   // returns DatabaseQueue
        let tok = KeychainTokenStore()
        let eng = SyncEngine(config: .production, dbWriter: db, tokenStore: tok)
        return .init(dbWriter: db, tokenStore: tok, syncEngine: eng)
    }
    static func testing(transport: HTTPTransport,
                        tokenStore: any TokenStore = InMemoryTokenStore()) throws -> AppEnvironment {
        let db  = try MedTrackerDatabase.open(path: nil)                  // in-memory GRDB
        let eng = SyncEngine(config: .production, dbWriter: db, tokenStore: tokenStore, transport: transport)
        return .init(dbWriter: db, tokenStore: tokenStore, syncEngine: eng)
    }
}
```

- **DB path (sandbox):** `~/Library/Containers/site.jamiewhite.medtracker/Data/Library/Application Support/MedTracker/medtracker.sqlite` — FileVault-covered, Time-Machine-backed (§12). `MedTrackerDatabase.open` applies the migrator, registers the `localDate` SQL function, sets `foreign_keys=ON` + WAL.
- **The test seam is already supported by shipped signatures:** `open(path: nil)` → in-memory; `SyncEngine.init(...transport:)` takes any public `HTTPTransport`; `InMemoryTokenStore` is public. No production test-hook needed.
- **Injection & userId (A6).** `@main App` builds `AppEnvironment.live()` once into `@State`, wraps it in the `@Observable SessionModel` (§3) + `@Observable AppModel`, and injects via `.environment(...)`. The authenticated **`userId` is threaded from `SessionModel` into the `WriteCoordinator` at construction** — the coordinator never reads it per-write from `KeychainTokenStore.load()?.userId` on the main actor. Screens read the app-wide model from `@Environment` and construct their per-screen `@State` stores by init-injection (§2.6), each getting the exact `dbWriter`/`userId`/`WriteCoordinator` it needs.
- **The repositories are not constructed.** `MedicationRepository`/`DoseRepository`/`InventoryRepository` are _not_ on the synced write path (they write server-owned `inventory_event`/`audit_log` rows). Reads go through `ValueObservation` on records directly. In 1c the repos stay dormant as the atomic reference + parity-test target; the composition root does **not** wire them (that would be dead wiring).

### 2.5 Navigation — `NavigationSplitView`

Root `@Observable @MainActor AppModel` carries the selected sidebar item; a top-level auth switch (§3) selects consent / login / TOTP / first-sync / the shell.

```swift
enum SidebarItem: Hashable { case dashboard, medications, history }   // 1c: exactly three
```

`MainShell` = `NavigationSplitView { Sidebar } detail: { NavigationStack(path:) }`, one `NavigationStack` per selected root so medication detail/form pushes stay scoped. **Sidebar navigation uses ordinary `List` selection bound to `AppModel.selection` — no custom ⌘-number shortcut.**

**Keyboard shortcuts (master §10.1), via `.keyboardShortcut`:** **⌘1–9 → quick-log the Nth active medication** on the Dashboard QuickLogBar (a power feature, not navigation); **`n` → new medication**; **`/` → focus the History filter**; **`?` → help**. All are **suppressed while text-editing** (the responder chain handles focus, so a field with focus swallows the key). These bindings live where their surface does (§5.1.4, §5.2, §5.3).

**Omit Analytics and Settings entirely (not disabled stubs).** (1) §13 optimises for a coherent, populated app; dangling disabled rows read as unfinished on a health app. (2) There is no Settings screen in 1c, so the entry would lead nowhere. (3) `SidebarItem` extends trivially in Phase 2. **Sign Out** + last-synced indicator live in the **sidebar footer**, not a destination.

### 2.6 Observation model — GRDB → `@Observable @MainActor` stores

**Keep the `DatabaseQueue`** that `MedTrackerDatabase.open` returns — no package change. Honest rationale: on a `DatabaseQueue`, `PRAGMA journal_mode=WAL` is effectively inert and **all reads funnel through the single connection**, so the bulk first-sync `SyncApplier.apply` transaction would stall observations. That is acceptable because the first sync runs **behind a modal progress gate** (§3.3 — no concurrent observers yet), and steady-state deltas are tiny. `DatabasePool` is a trivial future switch (a new factory entry point) if observation contention ever appears (§8-#9).

Every record is `Sendable + FetchableRecord + PersistableRecord + Codable + Identifiable` and `any DatabaseWriter` is `Sendable` (GRDB 7), so the bridge is race-free by construction: the `@Sendable` tracking closure produces a `Sendable` snapshot struct; the only landing site is a `@MainActor` store's stored properties.

**Observation lifecycle (A1) — view-driven structured task, no stored `Task`, no `deinit`:**

```swift
@MainActor @Observable final class DashboardStore {
    private(set) var snapshot = DashboardSnapshot.empty
    private(set) var loadError: Error?
    private let dbWriter: any DatabaseWriter
    private let userId: String

    // Driven by the view's `.task { await store.observe() }` — SwiftUI owns the lifetime and
    // cancels on disappear. No stored Task; no deinit; no retain cycle.
    func observe() async {
        let userId = self.userId
        do {
            let observation = ValueObservation.tracking { db in try DashboardSnapshot(db, userId: userId) }
            for try await snap in observation.values(in: dbWriter) { snapshot = snap; loadError = nil }
        } catch is CancellationError {
            // view disappeared — not an error, do not surface
        } catch {
            loadError = error   // view shows a retry that re-invokes observe(), rebuilding the observation
        }
    }
}
struct DashboardSnapshot: Sendable { /* Sendable records only */ }
```

**Rules (apply to every screen store — Dashboard/Medications/History):**

- **View-driven cancellation (A1):** the view calls `.task { await store.observe() }`; `observe()` runs the `for try await` loop _directly_ so SwiftUI auto-cancels it on disappear. No stored `Task`, no `deinit` backstop.
- **Error handling (A5):** a real stream error sets `loadError` **and** the view offers a retry that re-invokes `observe()` (rebuilding the observation); `CancellationError` is distinguished and never surfaced as an error, so a disappearing view never renders a false failure.
- **Render-from-value (A2-i):** SwiftUI views render from the `Sendable` **snapshot value**, init-injected — the store is a thin producer of that value. This is what makes snapshot tests deterministic (§7.2): instantiate the view with a fixed snapshot + fixed `now`/tz, never touching GRDB or the observation. The record→lean-model adapters (§4.1) are the real unit-test seam.
- **`@State` ownership (A2-ii):** stores are **`@State`-owned, constructed once via `State(initialValue:)`**, capturing `dbWriter`/`userId`/`WriteCoordinator` at first init. **Constructing a store in `body` is forbidden** (SwiftUI recreates view structs every parent render, which would restart/duplicate the observation).

  ```swift
  struct DashboardScreen: View {
      @State private var store: DashboardStore
      init(env: AppModel) {                                  // capture once, not in body
          _store = State(initialValue: DashboardStore(dbWriter: env.dbWriter, userId: env.userId))
      }
      var body: some View {
          DashboardView(snapshot: store.snapshot, now: /* ticker */)   // renders from the value
              .task { await store.observe() }                          // SwiftUI-cancelled
      }
  }
  ```

- **One snapshot per screen:** one observation, fewer reader hops, atomic UI updates — not N observations. Before any `MedTrackerCore` call, the store **adapts records → the lean domain models** (§4.1), always threading `Profile.timezone`.

---

## 3. Auth, session gating & sync wiring

`SyncEngine` already owns the entire network + persistence surface for auth: `login`/`verifyTOTP`/`signInWithApple` each call the endpoint _and_ persist the `StoredSession` to the injected `TokenStore` on success; `sync()` guards on `tokenStore.load()` and throws `APIError.unauthorized` when it is absent. **Phase 1c adds no networking and no token code** — only a `@MainActor` observable model driving the actor and mapping outcomes/errors onto view state. Every auth wire shape (`LoginBody`, `TOTPBody`, `AppleBody`, `SessionResponse`, `LoginOutcome`) is already modelled and unit-tested, so the auth path does **not** need the contract copy-in (only the write path does).

### 3.1 First-run consent gate + the auth state machine (`SessionModel`)

One `@MainActor @Observable final class SessionModel` is the single source of truth for which root view renders:

```swift
enum AuthPhase: Equatable {
    case launching                                             // reading UserDefaults + tokenStore.load() once
    case disclaimerConsent                                     // first-run blocking DisclaimerConsentView
    case unauthenticated(error: AuthError?)                    // LoginView
    case totpChallenge(preAuthToken: String, error: AuthError?)// TOTPView
    case firstSync(FirstSyncState)                             // initial full-sync progress UI
    case authenticated                                         // NavigationSplitView shell
}
```

**First-run medical-disclaimer consent (master §13 / 1.4.1).** At `.launching`, `SessionModel` reads `disclaimerAcknowledged` from `UserDefaults` (local-only, the CA92.1 required-reason API declared in §2.3). If `false` → `.disclaimerConsent`, a **blocking** `DisclaimerConsentView` showing the **verbatim** medical disclaimer (copy is web-sourced, §8-#12) with an explicit "I understand" acknowledgment; the app is otherwise **unusable** until acknowledged. On acknowledgment, set the flag and proceed to the token check. Subsequent launches skip it. This replicates the web's registration consent gate as a first-run step. (Analytics/exports disclaimers stay Phase 2; the med-form notice is 1c — §5.2.)

1. **Email+password.** `LoginView` → `signIn(email:password:)` → `engine.login(...)`, switch on `LoginOutcome`: `.session` (engine persisted the `StoredSession`) → `.firstSync`; `.totpChallenge(preAuthToken)` → `.totpChallenge` (**no token persisted yet** — a killed app returns to login).
2. **TOTP.** `TOTPView` → `verify(code:)` → `engine.verifyTOTP(preAuthToken:code:)`. Success persists + returns `SessionUser` → `.firstSync`. Wrong code → `.unauthorized`/`.badRequest` → stay on `.totpChallenge` with an inline error, `preAuthToken` retained.
3. **Error mapping.** A small `AuthError` maps typed `APIError` to copy: `.unauthorized` → "Invalid email or password" (login) / "Incorrect code" (TOTP); `.rateLimited(retryAfter:)` → "Too many attempts, try again in N s" (disable submit for `retryAfter`); `.transport` → "Can't reach the server"; `.emailConflict` (SIWA-only). Fields stay populated across a failed attempt; an `isSubmitting` flag disables re-entry. Because `SessionModel` is `@MainActor` and `SyncEngine` an `actor`, there is no data-race surface beyond `await` suspension points.

### 3.2 Sign in with Apple (conditional, §0(d))

**Button.** Idiomatic path is SwiftUI's `SignInWithAppleButton` (`AuthenticationServices`), returning `Result<ASAuthorization, Error>`; if the raw `ASAuthorizationAppleIDButton` is required, bridge it with an `NSViewRepresentable` + a `Coordinator` implementing `ASAuthorizationControllerDelegate`/`…PresentationContextProviding`. Request via `ASAuthorizationAppleIDProvider().createRequest()` (`requestedScopes = [.fullName, .email]`); drive with `ASAuthorizationController`. On success, extract `identityToken` (`Data?` JWT → UTF-8 `String`) and `fullName` (`PersonNameComponents?` → `PersonNameComponentsFormatter`). Apple returns name/email **only on the first authorization**; later sign-ins yield `nil`, which `SyncEngine.signInWithApple(identityToken:fullName:)` already accepts. Hand the two strings to `SessionModel.signInWithApple(...)` → `engine.signInWithApple(...)` → persists → `.firstSync`. `APIError.emailConflict` (409) → "This email already has a password account — sign in with your password instead." The delegate seam is deliberately thin (extract two strings, call the model), so outcome/error handling is unit-testable without the `ASAuthorization` machinery.

**Entitlement + backend both conditional & manual.** SIWA needs the paid `com.apple.developer.applesignin` capability, kept **out of the default committed entitlements**. The button + wiring ship and compile; the capability is added via Xcode "Signing & Capabilities" only for the manual smoke, once (a) a paid account is provisioned and (b) the backend `/auth/apple` route is confirmed deployed. Without the entitlement the button renders but `performRequests()` fails — so the live SIWA path is inherently a manual, gated test.

### 3.3 Session gating

**Root switch.** After consent, `SessionModel` does one `tokenStore.load()`: `nil` → `.unauthenticated`; non-nil → toward the shell + a kicked sync (no auth round-trip on relaunch — the Lucia session is a 30-day sliding token; a stale token is discovered lazily on the first `sync()` → `.unauthorized`).

**Identity/timezone comes from the synced `Profile`, not `StoredSession`.** `StoredSession` carries only `{token, userId}`; date bucketing needs `Profile.timezone`, populated by the `/sync` pull (`SyncApplier` upserts the singleton `Profile`). The shell reads `Profile(id == 1)` via `ValueObservation`. Two consequences:

- **First run after login** → `.firstSync` runs `engine.sync()` behind a **modal progress gate** _before_ revealing date-bucketed screens (this is also why the DatabaseQueue read-stall during the bulk apply is harmless — §2.6). This is the §12 "migration = login + sync": the owner's Neon history arrives here. The first `sync()` has no stored cursor/epoch, so the server returns a full snapshot — assert `SyncOutcome.fullResync == true`; drive a progress view off `pulledMedications`/`pulledDoseLogs` (or an indeterminate "Loading your medications…"). On success → `.authenticated`. Zero meds after first sync → the onboarding CTA (§5.1.7), not a spinner.
- **Relaunch with a token but offline/empty replica:** if the initial `sync()` throws a transport error, do **not** bounce to login (the session is fine) — enter the shell with whatever local data exists, show a "Couldn't refresh" retry banner, and **fall back to system timezone** for bucketing until a `Profile` row exists (§8-#16).

**401 → re-login, centralized.** Every `sync()` funnels through one `SessionModel.runSync()` whose `catch` treats `APIError.unauthorized` as the sole re-auth signal: `tokenStore.clear()`, then `.unauthenticated(error: .sessionExpired)`. This is the only place that clears the session. All other errors (`.transport`/`.server`/`.rateLimited`) leave `phase == .authenticated` and surface as a non-blocking banner — a dead network must never look like a logout.

### 3.4 Sync triggers (1c)

All three call the same `SessionModel.runSync()` (the actor serializes overlapping calls; every step is idempotent, so double-fires are safe):

1. **Launch / foreground.** After the initial `.firstSync`, re-sync on each `ScenePhase`/`NSApplication.didBecomeActiveNotification` transition to `.active`, throttled (skip if a sync ran in the last ~30 s).
2. **After every write.** The user action performs, in **one GRDB transaction**, the minimal optimistic state effect + the outbox enqueue (§4); the UI updates instantly via `ValueObservation`; then a **debounced** `SyncScheduler.requestSync()` (§4.4) routes through `runSync()` to drain the outbox and re-pull. A failed sync leaves the `OutboxEntry` `pending` for the next trigger — the write is durable regardless.
3. **Manual refresh.** A toolbar control + `⌘R` calls `runSync()` with a visible spinner + error banner.

**`NSBackgroundActivityScheduler` periodic pull → Phase 2.** §7.6 defines the ~15-min pull purely as the _notification_ staleness tax; replanning is the deferred `NotificationPlanner`. Pulling it into 1c would couple to a Phase-2 subsystem and add a nondeterministic timer-driven trigger that undermines deterministic CI. 1c's freshness comes from the three deterministic, mockable triggers above.

---

## 4. The optimistic-write layer (`WriteCoordinator`)

Phase 1b §7.1 deferred "user-action wiring" to 1c. The layer lives in **`MedTrackerApp`** (not a shipped package's public surface). All ten commands are **net-new** — the Phase-1a repositories cannot be reused because they write the server-owned `inventory_event`/`audit_log` rows the rule forbids on the synced path (those rows arrive on the next delta pull and self-heal the local ledger).

### 4.1 The write-path rule (restated, load-bearing)

On a user action the app: (1) applies the **minimal optimistic local effect to STATE tables only** — `medication` (incl. `inventoryCount`/`sortOrder`/`isArchived`), `dose_log`, `medication_schedule` — and **never** writes local `inventory_event`/`audit_log`; (2) enqueues an `OutboxEntry` **in the same transaction** (§4.2, mandatory); (3) a later `sync()` drains the outbox (`POST /commands`) and re-pulls the server's canonical rows. Optimistic effects mirror the reference repositories' _state math_ exactly (clamp on decrement; unclamped restore on delete) but omit the event/audit rows. `localEntityId`/`localEntityKind` are set **only** for the two reconciled create kinds — `.medication` and `.doseLog` — because `Reconciler.reconcile` rewrites exactly those (`medication.id` + child FKs, or `dose_log.id`) when the server returns a canonical id; every other command references existing ids. Client ids are `createId()` from `MedTrackerCore`.

**Adaptation layer (records → lean Core models), used by every screen and the coordinator:**

```
MedicationSchedule → ScheduleRow(kind: ScheduleKind(rawValue: row.scheduleKind)!,
                                 intervalHours: row.intervalHoursDecimal,
                                 timeOfDay: row.timeOfDay, daysOfWeek: row.daysOfWeekArray)
DoseLog            → DoseEvent(id:, medicationId:, takenAt: Date(timeIntervalSince1970:), status:)
Medication.pattern → MedicationPattern(rawValue:) ?? .solid
```

### 4.2 Interface + the mandatory transaction join (A3)

The "optimistic effect + `OutboxEntry` insert in ONE transaction" invariant is **unsatisfiable with the shipped API**: both `SyncEngine.enqueue` and `OutboxStore.enqueue` open their own `db.write`, so as written the two land in _two_ transactions — a crash between them loses the outbox row (dose applied locally, never sent) or strands a command whose optimistic effect rolled back. **Phase 1c MUST close this** (this is required, not an optional fallback):

- **Preferred (recommended):** add `OutboxStore.enqueue(_ db: Database, type:payload:localEntityId:localEntityKind:) -> OutboxEntry` (no internal write, callable inside the caller's `dbWriter.write`) to `MedTrackerSync` (§8-#1), keeping id/idempotency-key generation in one place.
- **Alternative (no package change):** inline `OutboxEntry(id: createId(), idempotencyKey: createId(), status: "pending", createdAt: Date().timeIntervalSince1970, …).insert(db)` inside the coordinator's transaction (verified viable — public memberwise init + public `createId()`).

Because the whole write becomes a single `await dbWriter.write { … }`, the coordinator methods are **`async throws`** (A4), not synchronous on `@MainActor` — so a 20-schedule-row `upsert` (§5.2.4) never janks the main thread:

```swift
@MainActor final class WriteCoordinator {   // userId injected at construction (A6)
    func logDose(medicationId: String, quantity: Int, takenAt: Date?, notes: String?, sideEffects: [SideEffectEntry]?) async throws
    func skipDose(medicationId: String, slotExpectedTime: Date) async throws
    func editDose(doseId: String, takenAt: Date?, quantity: Int?, notes: String??, sideEffects: [SideEffectEntry]??) async throws
    func deleteDose(doseId: String) async throws
    func refill(medicationId: String, amount: Int, note: String?) async throws
    func adjustInventory(medicationId: String, newCount: Int, note: String?) async throws
    @discardableResult func upsertMedication(id existing: String?, fields: MedicationFields, schedules: [MedicationScheduleInput]) async throws -> String
    func archive(medicationId: String) async throws
    func unarchive(medicationId: String) async throws
    func reorder(orderedMedicationIds: [String]) async throws   // decomposed into pairwise reorder{medId1,medId2} swaps (§5.2.2)
}
```

Each method runs its state effect + enqueue inside one `await dbWriter.write { db in … }` and `throws` on the **optimistic (local) failure only** (a `CHECK` violation, or a client-side bound like quantity 1–10); the transaction rolls back and the caller shows an inline/toast error. Sync failures are durable in the outbox and never thrown here.

### 4.3 Per-command state effect + payload + reconcile keys

| `type`                             | Optimistic STATE effect (state-only, mirrors the reference repo minus event/audit)                           | `localEntityId`/`kind`                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| `log_dose`                         | insert `DoseLog(status:"taken")`; if `inventoryCount != nil`, `= max(0, prev − qty)` (clamp)                 | new dose id / `.doseLog`                  |
| `skip_dose`                        | insert `DoseLog(status:"skipped", quantity:1, takenAt: slotExpectedTime)`; no inventory change               | new dose id / `.doseLog`                  |
| `edit_dose`                        | update dose fields; if `status=="taken"` & qty changed, `newCount = max(0, prev − (newQty−oldQty))` (clamp)  | —                                         |
| `delete_dose`                      | delete dose row; if was `"taken"` & tracked, `newCount = prev + qty` (**unclamped** restore)                 | —                                         |
| `refill`                           | `inventoryCount = (prev ?? 0) + amount` (seeds tracking when nil)                                            | —                                         |
| `adjust_inventory`                 | `inventoryCount = newCount`                                                                                  | —                                         |
| `upsert_medication_with_schedules` | insert/update `medication`; **delete-then-insert** its `medication_schedule` set                             | new med id (creates only) / `.medication` |
| `archive`                          | `isArchived=true`, `archivedAt=now`, `updatedAt=now`                                                         | —                                         |
| `unarchive`                        | `isArchived=false`, `archivedAt=nil`, `updatedAt=now`                                                        | —                                         |
| `reorder`                          | swap the two affected meds' `sort_order` (state-only); multi-position move → adjacent-swap sequence (§5.2.2) | —                                         |

**`skip_dose` reconcile — confirmed safe (contract §4).** `skip_dose` returns `{ id }`, the same result shape as `log_dose`, so wiring it symmetric to `log_dose` (`.doseLog`; the drainer reads the canonical id at `result.result?["id"]`) reconciles correctly, with **no** duplicate-skipped-row risk. (Plan nuance: the `skip_dose` _payload_ is only `{ medicationId }` — the server stamps its own skip time via `logSkippedDose`, so the optimistic local `takenAt: slotExpectedTime` is provisional and is replaced by the server's canonical row on the next pull; verify the post-sync slot re-match against the web behaviour.)

**Offline chain safety:** a `reorder`/`archive`/`log_dose` enqueued against an offline-created med's local cuid2 `X` (before its `upsert` acks) is safe — `Reconciler.remapPendingOutboxPayloads` rewrites `X→Y` inside every still-`pending` payload when the create acks, so the server only ever sees the canonical id.

### 4.4 Triggering `sync()` after a write — debounced (S4)

Do **not** `await syncEngine.sync()` inline (the optimistic effect is already durable; the UI already updated). Call a **debounced `SyncScheduler.requestSync()`** that **drops if a sync is already in flight**. `SyncEngine` is a reentrant actor whose steps are idempotent, so coalescing is _efficiency, not correctness_ — a plain drop-if-in-flight debounce suffices; the single-flight + trailing-"dirty"-re-run machinery is YAGNI and is not built. The scheduler routes through `SessionModel.runSync()` so the 401→re-login rule (§3.3) holds uniformly.

### 4.5 Contract payloads (resolved — contract now in `docs/design/api-v1-contract.md`)

The ten command `type` strings and their **exact payloads + result shapes are pinned by the in-repo contract** (`docs/design/api-v1-contract.md` §4). Facts the write layer depends on: `log_dose`/`skip_dose` → `{ id }` (new dose-log id; both reconcile `.doseLog` via `result.id`); `upsert_medication_with_schedules` → `{ medication: <raw row | null> }` (reconcile `.medication` via `result.medication.id`; `null` only on an update whose id isn't found/owned); `edit_dose` → `{ updated: Bool }`, `delete_dose` → `{ deleted: Bool }`, `refill` → `{ previousCount, newCount }`, `adjust_inventory` → `{ previousCount, newCount, quantityChange }`, `archive`/`unarchive` → `{ ok: true }` (none reconcile). **`reorder` is a pairwise swap `{ medId1, medId2 }`** (`swapSortOrder`), not an ordered-list command (§5.2.2). `edit_dose` clears `sideEffects` on explicit `null`, leaves it on `undefined`. `JSONValue.number` integer fields render whole (`2`, not `2.0`).

---

## 5. Screens

Every web `use:enhance` success maps to **local GRDB write + `ValueObservation` refresh + outbox enqueue**, preserving the same side-effects (toast text, ~700 ms flash, sheet close) and validation messages (master §10). All time/date computation uses `Profile.timezone`. Pill styling everywhere uses `renderedColours(colour:colourSecondary:pattern:)` + `getReadableTextColor(colour:colourSecondary:pattern:)` from `MedicationStyle.swift`.

### 5.1 Dashboard

The sidebar's first destination — a **read-mostly aggregation surface** driven by one `ValueObservation` over `medication`, `medication_schedule`, `dose_log`, plus a single root time ticker for live counters. Its only writes are the two synced quick-actions (log, skip).

**5.1.0 Shared inputs (resolved once per emission by `DashboardStore`):** `tz` from `Profile.timezone` (`TimeZone(identifier:)`, fall back to `UTC`, never `TimeZone.current`); `now = Date()` at emission (DB-state clock, separate from the ticker's live clock); `dayStart/dayEnd` via `startOfDay(now, timeZone: tz)` and start-of-next-local-day (Calendar-based, DST-safe); `activeMedIds` = `Medication.filter(is_archived == false).order(sort_order)` (zero → onboarding CTA); `schedulesByMedId` filtered to the effective window (`effectiveFrom ≤ now`, `effectiveTo == nil ‖ > now`) and adapted to `[ScheduleRow]`; `todaysDoses` = `DoseLog` in `[dayStart, dayEnd)` as `[DoseEvent]`; `lastTakenByMed` = most-recent `taken` per med; `slotsByMed` = `computeScheduleSlots(medications:schedulesByMedId:todaysDoses:lastTakenByMed:dayStart:dayEnd:timeZone:now:)` (`Schedule.swift`) — the single source for My-Day, Today feed, and SummaryStrip counts. Core functions are pure and cheap, so the VM recomputes the derived tree on each emission; live _time_ is handled separately and never re-queries the DB.

```
DashboardView (ScrollView)
├─ if activeMedIds.isEmpty → OnboardingCTA
└─ else
   ├─ SummaryStrip     (taken/scheduled today, adherence %, streak)
   ├─ RefillsCard      (meds with non-ok refill severity)
   ├─ QuickLogBar      (pattern pills, qty 1–10, success flash) — PRIMARY WRITE
   ├─ MyDayTimeline    (slots grouped by TimeOfDayBucket; upcoming rows show live "Due in …")
   └─ TodayFeed        (overdue rows + Skip; per-med TimeSince) — WRITE (skip)
```

**5.1.1 SummaryStrip.** READ (no new fetch beyond one history read): slot tallies from `slotsByMed`; adherence-today = `adherencePercent(taken:expected:)` (caps 100, 1-decimal parity), with the _denominator choice_ (all-day vs due-so-far) flagged (§8-#12); streak = `calculateStreak(dateStringsNewestFirst:, today:)` where the VM builds distinct `localDateString(...)` over **all** `taken` doses newest-first — an unbounded-range aggregation (§8-#3d). WRITE: none.

**5.1.2 RefillsCard.** READ per active med: `dailyRate = dailyRateFor(scheduleRows:legacyScheduleType:legacyIntervalHours:thirtyDayTakenQuantity:)`; `days = daysUntilRefill(inventoryCount:dailyRate:)` = `floor(inv/rate)`; `severity = classifyRefillSeverity(days:)` (critical ≤3, warning ≤7, watch ≤14, else ok). Low-inventory chip is a separate record check (`inventoryCount != nil && ≤ inventoryAlertThreshold`). `.ok` hidden; sorted by days ascending. Per master §15 the card uses **only** this schedule-aware forecast — it does **not** surface the legacy `calculateDaysUntilRefill` number. `thirtyDayTakenQuantity` needs a new `SUM(quantity)` aggregation (§8-#3b). WRITE: none.

**5.1.3 MyDayTimeline.** READ: flatten `slotsByMed.values` → `groupSlotsByTimeOfDay(_:timeZone:)` → ordered by `TimeOfDayBucket.allCases`, ascending within each bucket; bucketing via `classifyHour(localHour)` (morning [5,12), afternoon [12,17), evening [17,21), night otherwise). Bucket→emoji/label is a view concern (Core exposes only the enum). Per-row styling from the `Medication` joined by `slot.medicationId`. WRITE: none.

**5.1.4 QuickLogBar (primary write; ⌘1–9).** READ: active meds' name + styling; qty constrained **1–10** (default 1). **`⌘1–9` quick-logs the Nth active medication** (§2.5), suppressed while text-editing. WRITE — quick-log (optimistic + enqueue, one txn): insert `DoseLog(id:createId(), status:"taken", quantity:qty, takenAt:now, loggedAt:now, updatedAt:now)`; `inventoryCount = max(0, prev − qty)`; enqueue `log_dose` with `localEntityId: doseId, localEntityKind: .doseLog`. Confirmed keys `medicationId`, `quantity`; remaining keys contract-dependent (§8-#10). Reconciliation is already wired (drainer reads `result.result?["id"]`, rewrites `dose_log.id` X→Y; next delta pull upserts the canonical row).

**5.1.5 TodayFeed + TimeSince + Skip.** READ: overdue set = slots `status == .overdue`; TimeSince = `formatTimeSince(lastTakenByMed[medId], now: tickDate)` ("just now"/"{m}m ago"/…/"Not yet taken"); due-in = `formatDueIn(msUntilDue:)`; interval meds' badge from `computeTimingStatus(intervalHours:lastEventAt:now:)`. WRITE — skip an overdue slot (optimistic + enqueue, one txn): insert `DoseLog(status:"skipped", takenAt: slot.expectedTime, loggedAt:now)`; **no inventory change**; enqueue `skip_dose` `localEntityKind: .doseLog`. The optimistically-inserted skipped dose re-enters `todaysDoses` next emission, so `computeScheduleSlots` re-matches the slot to `.skipped` and it drops from the feed — no manual UI removal. Reconcile is confirmed safe — `skip_dose` returns `{ id }` like `log_dose` (contract §4).

**Live-counter strategy.** One shared ticker at `DashboardView` root: `TimelineView(.periodic(from: .now, by: 30))`; its `context.date` threads to every `formatTimeSince`/`formatDueIn`/`computeTimingStatus`. 30 s bounds the `due_now`/`overdue` flip lag to ≤30 s while staying cheap. DB state and time are decoupled — the ticker never touches GRDB. Reduce-motion (`@Environment(\.accessibilityReduceMotion) ‖ Settings.reducedMotion`) does **not** stop the counters (they are information) — it only suppresses the transition on value change and the success flash.

**5.1.6 Success side-effects & validation.** ~700 ms QuickLogBar pill flash (success `#10b981`, `withAnimation(.easeOut(duration: 0.7))`; under reduce-motion apply state without animation); a transient success toast (copy web-sourced, §8-#12); quick-log qty UI-constrained to 1–10; no free-text on the Dashboard write path.

**5.1.7 OnboardingCTA (zero meds).** Replaces the whole body when `activeMedIds.isEmpty`; **single primary CTA "Add your first medication"** → the Medication form (whose save is `upsert_medication_with_schedules`, `.medication`). **No "Load sample data" in 1c (S1):** a server-authoritative client cannot locally seed — a local sample med is wiped by the next full-resync (`SyncApplier.applyFull` `deleteAll`s every synced table). The real §13 App-Review seed is a **ship-phase** affordance run as `upsert` commands against the live account.

### 5.2 Medications (list + form + detail)

```
MedicationsListScreen (detail root; `n` = new med)
├─ toolbar: NewMedicationButton, ReorderEditToggle
├─ ActiveList (List, .onMove, sorted by sortOrder) → MedicationCard ×N
│    PatternSwatch · IdentityBlock(name,dosage,form,category) · TimingBadge ·
│    RefillChips{severity, low} · AdherenceMiniBar · Sparkline14
├─ ArchivedGroup (DisclosureGroup) → MedicationCard(archived) → Unarchive
└─ EmptyState
MedicationFormView(.new | .edit(id))  (sheet; @Observable MedicationDraft)
├─ DisclaimerNotice (verbatim med-form disclaimer, master §13/1.4.1)
├─ IdentitySection{Name,Notes} · DosageSection{Amount,Unit} · FormPicker · CategoryPicker
├─ StylePicker{PatternGrid(8), PrimaryColorWell, SecondaryColorWell(enabled: pattern≠solid), LiveSwatch}
├─ ScheduleSection{ ScheduleRowEditor ×(1…20) : KindSegment(interval|fixed_time|prn) → per-kind fields }
├─ InventorySection{Track, Count, AlertThreshold} · ValidationSummary · Save/Cancel
MedicationDetailView(id)
├─ Header(large swatch) · EditButton · TimingRow · ScheduleSummary
├─ InventoryCard{count, threshold, severityChip, daysUntilRefill, Refill→sheet, Adjust→sheet}
├─ InventoryEventHistory(newest-first; server-owned) · AdherencePanel{mini-bar, Sparkline14}
├─ Archive/Unarchive · [Phase-2] InteractionProbeCard (disabled stub)
```

**Med-form disclaimer notice (F2).** The form carries the **verbatim** medical disclaimer as a persistent notice (master §13/1.4.1 "medication form"), distinct from the first-run consent gate (§3.1). Copy is web-sourced (§8-#12). (Analytics/exports disclaimers remain Phase 2.)

**5.2.1 List READ — `MedicationCardVM`.** One `ValueObservation` returning active + archived VMs: fetch medications (`order(sort_order)`, partition on `isArchived`), schedules grouped `[medId:[ScheduleRow]]`, and three aggregations (§8-#3a/b/c): 14-day taken-quantity per `localDate`; 30-day taken-quantity per med; 7-day taken count + last-taken per med. Per card: swatch via `renderedColours`/`getReadableTextColor`; refill chip + "~Nd left" from the **single** `dailyRateFor → daysUntilRefill → classifyRefillSeverity` pipeline (never legacy `calculateDaysUntilRefill`, master §15); low-inventory chip (record check); adherence mini-bar = `adherencePercent(taken: taken7, expected: jsRound(expectedPerDay(forSchedules:) × clampEffectiveDays(rangeFrom: now-7d, rangeTo: now, startedAt:, endedAt:)))`; 14-day sparkline = `buildSparklineShape(...)` → `Path` in a `Canvas`; timing badge (§5.2.5).

**5.2.2 List WRITE — reorder / archive.** Reorder (`.onMove`): the contract's `reorder` is a **pairwise swap** `{medId1, medId2}` (`swapSortOrder`), not an ordered-list command — decompose a move into the adjacent-swap sequence that realizes it: renumber the affected `sortOrder` span locally (state only) and enqueue one `reorder` per adjacent swap, no `localEntityId`. (Simplest faithful fallback: move-up/move-down controls = one swap = one command.) Archive/Unarchive: optimistic `is_archived`/`archived_at`/`updated_at`, **no** local `audit_log`, enqueue `archive`/`unarchive` `{medicationId}`, no `localEntityId`. Payload shapes contract-owned (§8-#10).

**5.2.3 Form modelling.** `@Observable MedicationDraft` projects on save to `MedicationFields(name, dosageAmount:String, dosageUnit, form, category, colour, colourSecondary:String?, pattern, notes:String?, scheduleType, scheduleIntervalHours, inventoryCount:Int?, inventoryAlertThreshold:Int?)` and `[MedicationScheduleInput(scheduleKind, timeOfDay:String?, intervalHours:String?, daysOfWeek:[Int]?, sortOrder, effectiveFrom:Date, effectiveTo:Date?)]`. **StylePicker:** secondary well enabled only when `pattern != .solid`; live preview recomputes `getReadableTextColor` on change. **ScheduleSection:** interval → `intervalHours`; fixed_time → `timeOfDay` (`HH:mm`) + `daysOfWeek` (0=Sun…6=Sat, empty ⇒ every day, stored nil); prn → all nil. `effectiveFrom` defaults to `now`; `sortOrder = row index`.

**Client-side validation (master §8.1, before the optimistic write; the DB `CHECK` is the backstop):** `name` 1–200; `dosageAmount` `^\d+(\.\d+)?$`; `dosageUnit` 1–20; `notes` ≤1000; `pattern ∈ MedicationPattern`; `form` ∈ {tablet, capsule, liquid, softgel, patch, injection, inhaler, drops, cream, other}; `category` ∈ {prescription, otc, supplement} (contract §4); interval `0 < h ≤ 72`; `timeOfDay` `^([01]\d|2[0-3]):[0-5]\d$`; `daysOfWeek` ints 0–6, ≤7; **1–20 rows** per med; inventory ints ≥ 0.

**5.2.4 Form WRITE — `upsert_medication_with_schedules`.** One optimistic txn on state tables + enqueue (§4.2). **Create:** `medId = createId()`; insert `medication` + `medication_schedule` rows; no `audit_log`; enqueue `localEntityId: medId, localEntityKind: .medication`. **Update:** update `medication`; **replace all** schedule rows (deleteAll then insert — mirrors `updateMedicationWithSchedules` minus audit); enqueue with **no** `localEntityId` (the next pull replaces the med's schedules wholesale). Envelope `{"medication":{…},"schedules":[…]}`, ack `result.medication.id`; inner field names/casing contract-owned (§8-#10). Because the synced path cannot call `MedicationRepository` (it writes audit rows), the per-kind `makeSchedule` normalization (`private`) must be **replicated in a new thin state-only writer** (§8-#5) so the `CHECK` isn't tripped.

**Legacy columns:** `scheduleType`/`scheduleIntervalHours` are deprecated (canonical = `medication_schedule` rows) but still carried on `MedicationFields`; send whatever the contract expects inside `upsert`, but derive no timing from them.

**5.2.5 Timing badge (quirk-fix — fixed_time gets a badge too, master §15).** `computeTimingStatus` handles interval only; for fixed_time meds, derive from a `computeScheduleSlots` set over a short horizon (now→+24h), pick the next `.overdue`/`.upcoming` slot, map to overdue-vs-due-soon by proximity. Interval "never taken" → no active reminder (kept quirk, §15). No single Core "next-dose for any kind" helper exists — this composition is VM work (§8-#8).

**5.2.6 Detail READ/WRITE.** READ: med + schedules via `ValueObservation`; refill forecast identical to the card; **inventory-event history** `InventoryEvent.filter(medication_id==id).order(created_at.desc)`. **UX note (load-bearing):** because the write path never inserts local `inventory_event` rows, a just-made refill/adjust updates `inventoryCount` **instantly** but its ledger row appears **only after the next `sync()`** — design the list to tolerate that lag; do not fabricate a local event row. WRITE: **Refill** (qty>0, `.invalidRefillQuantity` parity): `inventoryCount = (prev ?? 0) + amount`; enqueue `refill` `{medicationId, quantity, note?}`. **Adjust** (`newCount ≥ 0` & `≠ prev`, `.invalidAdjustment` parity): `inventoryCount = newCount`; enqueue `adjust_inventory` `{medicationId, newCount, note?}`. Payload shapes contract-owned (§8-#10). Phase-2 `InteractionProbeCard` renders disabled/"coming soon" only.

### 5.3 History (`/log`)

The History detail owns an `@Observable HistoryStore` holding filter state, the live paged observation, and the two writes.

```
HistoryScreen
├─ FilterBar{ MedicationFilterMenu(All|each med, active+archived) · StatusFilterMenu(All|taken|skipped) ·
│            DateRangeControl(All/7d/30d/Custom→two DatePickers in Profile.tz) ·
│            NotesSearchField(debounced; "/" focuses) · SideEffectsFilter(Toggle + name/severity) ·
│            ClearFiltersButton }
├─ HistoryList (live from ValueObservation)
│    ForEach group (keyed by profile-tz local date, newest-first) → SectionHeader("Today"/"Yesterday"/date)
│      → TimelineEntryRow{ swatch · name+dosage · StatusPill · "×N", time · notesPreview · SideEffectChips · Edit/Delete }
│    LoadMoreFooter(hasMore) · EmptyState(no doses vs no matches)
├─ EditDoseSheet(.sheet(item:)) { takenAt DatePicker · quantity Stepper(1–10) · notes ≤500 ·
│    SideEffectsEditor(≤20 rows, {name 1–100, severity∈mild/moderate/severe}) · Save(700ms flash)/Cancel }
└─ DeleteConfirmation(.confirmationDialog)
```

`missed` is never a row-level status (master §8.2 — aggregate-inferred), so the status filter offers **All / Taken / Skipped**. The `/` shortcut focuses `NotesSearchField` (§2.5), suppressed while already text-editing.

**5.3.1 READ — live filtered/paged query.** No join record exists; the store fetches a flat `HistoryRow` (`Decodable, FetchableRecord`) via a `dose_log ⨝ medication` SQL join that **must not** filter `is_archived` (a dose on an archived med still shows). Each filter is an optional `(:x IS NULL OR predicate)` bind, so one prepared statement serves all combinations (medication / status / date-range / notes-`LIKE` / side-effects-`json_each` EXISTS). The composite indexes all end in `taken_at`, satisfying `ORDER BY d.taken_at DESC` with no sort step. Grouping uses the registered `localDate(taken_at, :tz)` SQL function (delegating to `MedTrackerCore.localDateString` — one DST-correct implementation). The **date-range filter stays sargable**: it does not apply `localDate()` to the column; the store converts the picked local start/end to a half-open UTC-epoch interval via `Time.startOfDay(_:timeZone:)` and binds epoch bounds. **Today/Yesterday** labels compare each group's `local_day` to `localDateString(now, tz)` / `localDateString(startOfDay(now,tz)−1s, tz)`; anything else renders an absolute date honouring `Settings.timeFormat`/`dateFormat` (app-side `DateFormatter` in `Profile.timezone`). Side-effects JSON uses SQLite **json1** (`json_each`/`json_extract`) — confirm json1 is enabled in the deployment SQLite (§8-#13).

**Read-only synced prefs (S6).** `Settings.reducedMotion`, `timeFormat`, `dateFormat`, and `doseLogPageSize` are consumed as **read-only synced parity** in 1c — only the deferred Settings screen can change them; here they reflect what the web app set. `dateFormat` is honored (master §15 "implement it") but **not user-editable in 1c**.

**5.3.2 Pagination — growing-window observation.** `loadedPages` starts 1; `limit = loadedPages × Settings.doseLogPageSize` (default 20). One `ValueObservation.tracking { fetch(base + " LIMIT \(limit)") }` consumed as an async sequence — live for its whole length. `loadMore()` increments `loadedPages`, re-creating the observation (previous task cancelled per §2.6). `hasMore = rows.count == limit`. A filter change resets to `loadedPages = 1`. The growing window re-reads the loaded span on each change — correct and simple at hundreds-to-low-thousands scale; keyset pagination is a noted fallback if a history ever grows large.

**5.3.3 WRITE — edit / delete (thin optimistic overlay, one txn).** **Edit** (`takenAt`, `quantity` 1–10, `notes` ≤500 empty→nil, `sideEffects`; status not editable — the reference `updateDose` never changes status): update the row; if `status=="taken"` & qty changed, `inventoryCount = max(0, prev − (newQty−oldQty))` (clamp); enqueue `edit_dose` (existing id, no reconcile). **Delete:** delete the row; if was `"taken"` & tracked, `inventoryCount = prev + qty` (**unclamped** restore, intentionally asymmetric); no local tombstone (the server tombstone arrives via the next pull, idempotent against the already-deleted row); enqueue `delete_dose` `{id}`. After either commits, `SyncScheduler.requestSync()` drains + re-pulls. `edit_dose`/`delete_dose` payload shapes (id key, wire date format, null-clearing) are contract-owned — no in-repo example (§8-#10).

---

## 6. Design language execution

Dark-only theme (master §10.2). Glass panels → `.ultraThinMaterial`/`.thinMaterial` over surface `#0a0a0f` (or literal white-8%/white-12% fills, radius 12–16pt); tokens as asset-catalog colours (surface `#0a0a0f`, raised `#12121a`, text `#f0f0f5`/`#8888a0`, success `#10b981`, warning `#f59e0b`, danger `#ef4444`, accent fixed `#6366f1` in 1c — the 10-preset picker is Phase 2).

- **8 medication patterns** as SwiftUI fills (`LinearGradient`/`RadialGradient`/`AngularGradient`/`Canvas`) with exact geometry and the **`<20pt → gradient` degradation**. Core (`MedicationStyle.swift`) ports only the **colour math** — `renderedColours(...) -> [String]` and `getReadableTextColor(...) -> ReadableTextColor{.dark #111111 / .light #ffffff, .hex}` — so fill geometry, degradation, and the 4-direction 1px text outline are `MedTrackerUI` view concerns.
- **Custom sparkline:** `buildSparklineShape(values:width:height:strokeWidth:)` → `SparklineShape{line, area, dotX?, dotY?}` rendered as `Path` in a `Canvas` (no Swift Charts). `dotX/dotY` non-nil only for the single-non-empty-day case; empty values → empty path.
- **Accessibility parity (master §10.2):** VoiceOver labels reuse the exact aria-label strings; Dynamic Type via relative sizing; **reduce-motion honoured from both the system setting and the synced `Settings.reducedMotion` pref** (`effective = @Environment(\.accessibilityReduceMotion) ‖ Settings.reducedMotion`), suppressing transitions/crossfades and the ~700 ms flash but never the informational live counters; WCAG-contrast foreground on arbitrary user colours via `getReadableTextColor`.

---

## 7. Testing & CI

Mock-first, network-free `swift test`, matching Phase 1a/1b discipline; live backend / real Keychain / SIWA are a **manual, backend-gated smoke pass**, not a CI gate. `swift-snapshot-testing` is the only new test-only dependency, wired into the snapshot target only.

**7.1 Logic unit tests (`MedTrackerApp`, in-memory GRDB + `MockTransport` + `InMemoryTokenStore`):**

- **Optimistic-write layer** — for each of the ten commands: assert the effect touches **only** state tables and writes **no** local `inventory_event`/`audit_log`; assert exactly one `OutboxEntry` enqueued **in the same transaction** — **roll back the write block and assert neither the state row nor the outbox row landed** (the §4.2 atomicity invariant); assert `payload` JSON + `type` match the contract; then drive `SyncEngine.sync()` against a scripted `MockTransport` and assert server rows replace the optimistic ones (incl. `.medication`/`.doseLog` reconcile and the offline create-then-log remap chain).
- **Adapters** — record→lean-model mapping before every Core call (highest-risk seam, pure-in/pure-out).
- **Date bucketing** — `Time.localDateString`/`startOfDay`/`localDayOfWeek` fed from **synced `Profile.timezone`** with injected fixed `now`/tz (the §15 device-tz-vs-user-tz fix).
- **Store observation contracts** — a store re-emits after an optimistic write and again after `sync()` applies the delta; an observation error sets `loadError` and a retry rebuilds it; a cancellation does not surface as an error (§2.6/A5).
- **Auth/session state machine** — first-run `.disclaimerConsent → acknowledge → .launching` proceeds only after the flag persists; `.totpChallenge → verifyTOTP → .firstSync`; a scripted 401 → re-login; first full sync asserts `fullResync == true` + populated rows + `.authenticated`; 429/transport leave `.authenticated` + banner, session not cleared.

`MockTransport` (currently `@testable`-internal to `MedTrackerSyncTests`) is promoted, with fixtures + a fixed-clock, into **`MedTrackerTestSupport`**, depended on by test targets only.

**7.2 Snapshot tests (`MedTrackerUI`, dark-only, under `xcodebuild`).** Views render from an **init-injected `Sendable` snapshot value** (§2.6/A2-i) with a fixed `now`/tz and explicit `\.sizeCategory` — deterministic, never touching GRDB or the observation. Targets: `MedicationCard` across all 8 `MedicationPattern` cases + the `<20pt→gradient` degradation + refill/low/adherence/sparkline matrix; **`QuickLogBar` pill contrast text over each medication's colour/pattern set** (`renderedColours`/`getReadableTextColor`) — **not** accent presets (accent is fixed `#6366f1` in 1c) (F3); the sparkline (empty/single/flat/normal + dot); `SummaryStrip`/`RefillsCard` zero/one/many; My-Day + Today-feed rows (all `SlotStatus`; overdue+Skip; the fixed-time-badge fix); onboarding empty state; History grouped list + entry with notes/side-effects; `StylePicker` grid; `DisclaimerConsentView` + the med-form notice; plus one `.accessibility3` variant on a text-heavy view. **Run under `xcodebuild test`, not `swift test`** — asset-catalog colours are compiled by `actool` only in an app/framework bundle, and materials/fonts render faithfully only there.

**7.3 CI (`.github/workflows/ci.yml`, pinned `macos-15` / Xcode 26).** Keep the three existing `swift test` steps (Core/Data/Sync). Add: `swift test` for `MedTrackerApp` (`--enable-code-coverage`) and `MedTrackerUI`; then a build+snapshot lane — `brew install xcodegen`, `xcodegen generate`, `xcodebuild test -project MedTracker.xcodeproj -scheme MedTracker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. GitHub's `macos-15` GUI session renders `NSHostingView` to bitmap headlessly; real signing is a manual release step. Extend `.swiftlint.yml`/`.swiftformat` to the new source trees, holding new Swift-6 app code to a stricter bar (a nested `.swiftlint.yml` re-enabling `identifier_name`/`line_length`, since the current `disabled_rules` were justified only by the TS-ported parity source). Set coverage floors **only on logic packages** (`MedTrackerApp` + keep Core/Data/Sync green); do **not** floor SwiftUI view bodies; measure the first green baseline, pin it, ratchet up only. Keep `SNAPSHOT_TESTING_RECORD` off in CI; record references once on the canonical runner and commit them.

**7.4 Deferred.** XCUITest is ship-phase (master §14) — 1c journey coverage is the store integration tests (login → optimistic write → enqueue → sync end-to-end against `MockTransport`, asserting DB state). Optionally keep one trivial launch smoke.

**7.5 Manual smoke (owner, signed build, backend up):** first-run disclaimer consent persists across relaunch; email+password → TOTP → session; SIWA (only if backend live) → note result; first sync populates all three screens; quick-log → flash → optimistic Today row → after sync the canonical `dose_log` replaces it and inventory matches; refill/adjust → count instant, `inventory_event` history appears only after sync; create med → server id reconciles across `medication`/`medication_schedule`/`dose_log`; **offline chain** (create med → log against it → connect+sync → `log_dose.medicationId` remapped); archive/unarchive + reorder persist across relaunch; History pagination/edit/delete; force a 401 → drop to re-login; Keychain persists across relaunch.

---

## 8. Package-API gaps to close in Phase 1c

Consolidated; conflicts resolved.

**Highest priority — blocks every synced write:**

1. **Transaction-joining `enqueue` (MANDATORY, not optional — §4.2).** The write-path rule requires the optimistic state effect and the `OutboxEntry` insert to commit in **one** transaction, but `OutboxStore.enqueue`/`SyncEngine.enqueue` each open their own `dbWriter.write`. **Add** `OutboxStore.enqueue(_ db: Database, type:payload:localEntityId:localEntityKind:) -> OutboxEntry` (no internal write) + a matching `SyncEngine.enqueue(_ db:…)`, callable inside the app's `dbWriter.write` (**recommended** — keeps id/idempotency-key generation in one place). Acceptable alternative: the `WriteCoordinator` inlines the `OutboxEntry(…).insert(db)` (verified viable — public init + public `createId()`). Tests roll back the block and assert neither write landed.

**New `MedTrackerData` query surface** (`MedicationQueries` today exposes only `fetchOwned`):

2. **List/detail fetch helpers** — active/archived medication lists (`order(sort_order)`), schedules-by-med, per-med inventory-event history. Tested query helpers so the VMs stay thin.
3. **The un-ported `getPerMedicationStats`/`getDailyDoseCounts` aggregations** — (a) 14-day taken-quantity sums grouped by `localDate(taken_at,:tz)`; (b) 30-day taken-quantity sum per med (forecast); (c) 7-day taken count + last-taken instant per med (mini-bar + interval anchor); **(d) distinct `localDate(taken_at,:tz)` over ALL `taken` doses, newest-first, feeding `calculateStreak`** (SummaryStrip §5.1.1) — **unbounded range**, needs the registered `localDate` function + an index consideration on `dose_log(taken_at)`/status. The `dose_log_med_taken_idx`/`dose_log_user_status_taken_idx` indexes already exist.
4. **A filtered/paged `DoseLogQueries` read** (History) — the `dose_log ⨝ medication` join with the optional-bind filter set, `localDate` grouping, and growing LIMIT. Net-new, unit-testable against in-memory GRDB with the registered `localDate` function.
5. **A thin state-only "optimistic upsert med + schedules" writer** — the synced path cannot call `MedicationRepository.create/updateMedicationWithSchedules` (they write `audit_log`), so the per-kind `makeSchedule` normalization + delete-then-insert replacement (both `private`) must be re-exposed/replicated so the 3-way `CHECK` isn't tripped and no audit row is written.

**Package fixes / mismatches:**

6. **Keychain accessibility — ACCEPTED deviation for 1c; hardening deferred to ship phase (A7).** `KeychainTokenStore.save` sets `kSecAttrAccessibleAfterFirstUnlock`; master §5.1/§11 want `…AfterFirstUnlockThisDeviceOnly`. On macOS's file-based keychain the `kSecAttrAccessible*` class is **inert** unless the query opts into the data-protection keychain (`kSecUseDataProtectionKeychain = true` + the required entitlement). The token **persists correctly** as-is. **1c keeps `KeychainTokenStore` unchanged and stays at exactly two entitlement keys (§2.3);** the data-protection-keychain + `…ThisDeviceOnly` + entitlement hardening move to the ship phase. No package change in 1c.
7. **`MockTransport` is not shipped** — `@testable`-internal to the sync test target; promote the public `HTTPTransport` mock into `MedTrackerTestSupport`.
8. **No unified "timing for any schedule kind" helper** (fixed-time badge §5.2.5) — compose from `computeScheduleSlots`/`computeTimingStatus` in the VM. Minor.
9. **No pool factory / no vended session accessor** (minor, non-blocking): `MedTrackerDatabase.open` returns `DatabaseQueue` only (a future `DatabasePool` needs a new entry point — §2.6); no single "session" object, so `userId`/`timezone` come from the `Profile` singleton via `ValueObservation`, the token being auth-presence truth.

**Needs the out-of-sandbox `api-v1-contract.md` (copy-in required, §0(c)) or web source:**

10. **Command payloads + result shapes — RESOLVED** (contract now in `docs/design/api-v1-contract.md` §4; see §4.5). All ten payloads/results are pinned. Corrections vs the earlier assumption: **`reorder` is a pairwise swap `{medId1, medId2}`** (not an ordered list, §5.2.2), and **`skip_dose` returns `{ id }`** (safe reconcile, §4.3). Remaining nuances to verify at implementation: whether `edit_dose` clears `notes` on explicit `null` (only `sideEffects`-null is documented as clearing), and integer-JSON strictness (`JSONValue.number` renders whole numbers without `.0`).
11. **`form`/`category` enums — RESOLVED** (contract §4): `form` = {tablet, capsule, liquid, softgel, patch, injection, inhaler, drops, cream, other}; `category` = {prescription, otc, supplement}; `pattern` = the 8 `MedicationPattern` cases; `scheduleType` = {scheduled, as_needed}.
12. **Exact copy strings** — **the verbatim medical disclaimer** (first-run consent gate §3.1 + med-form notice §5.2, sourced from the web registration-consent / disclaimer component), the success-toast text, validation messages, the SummaryStrip metric labels + adherence denominator (all-day vs due-so-far), RefillsCard copy, and the onboarding CTA copy live in the SvelteKit components (out of sandbox). The spec pins behaviours, not literal strings.
13. **Confirm SQLite json1** in the deployment SQLite (system SQLite on macOS 15 ships it — flag to confirm; the fallback is a fragile `LIKE` or an in-Swift post-filter that breaks the paged window).
14. **Grouping/sort key `taken_at` vs `logged_at`** — this design groups/sorts History on `taken_at`; the web `/log` may use `logged_at`. Confirm before locking parity.
15. **Notes-search scope** — this design searches only `dose_log.notes`; the web may also match medication name / side-effect names (one-line `WHERE` extension). Confirm.
16. **Nothing seeds a local `Profile` at auth time** — `login`/`verifyTOTP`/`signInWithApple` persist only the token, so a token-present-but-offline relaunch may have no `Profile` (hence no timezone). **Decision (recommended):** gate date-bucketed screens behind the first successful full sync, with a system-timezone fallback on the offline-relaunch edge (§3.3). (Alternative: have the composition root write `Profile(id:1)` from the returned `SessionUser` at auth time.)

---

## 9. Explicitly out of scope for Phase 1c

**Altitude reminder:** 1c is **pre-submission**. `PrivacyInfo.xcprivacy` is present only so the target builds and signs cleanly (§2.3) — not for App-Review completeness. The following are deferred:

- **Ship-phase (App-Review completeness):** account-deletion UI (master 5.1.1v), SIWA live-path completeness (4.8, §3.2), the "Load sample data" review seed (§13, §5.1.7), keychain data-protection hardening (§8-#6), XCUITest journeys (master §14).
- **Phase 2:** notification engine (`NotificationPlanner`, categories/actions, suppression, tz/wake/sync replan, menu-bar `SMAppService` agent, QA matrix); Analytics screen (**sidebar entry omitted**); full Settings screens + the 10-preset accent picker + user-editable `dateFormat`/`doseLogPageSize`/`heatmapPeriod` (they are read-only synced parity in 1c, §5.3.1); CSV/PDF export via `NSSavePanel` + `/export/full` client (`Csv` Core helpers stay unused); app lock (`LocalAuthentication`) + the 8 re-auth gates; openFDA interaction checker (disabled `InteractionProbeCard` stub only); `NSBackgroundActivityScheduler` periodic pull + APNs silent nudge (§3.4).
- **Deferred (documented):** SQLCipher / at-rest encryption toggle (master §11); any change to the `/api/v1` backend surface; per-field conflict resolution / CRDTs (server-authoritative last-write-wins suffices for one account).
