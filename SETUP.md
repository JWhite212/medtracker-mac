# MedTracker — Notification Go/No-Go Spike

**Purpose:** before investing months in the native Mac app, prove the one assumption the
whole port depends on: **a scheduled local notification fires while the app is fully quit**,
and tapping its action relaunches and reaches the app. If this holds, native reminders are
viable and we proceed. If it doesn't, we rethink the reminder architecture _now_, not later.

Time: ~20–30 minutes. You need a Mac, Xcode 16+ (macOS 15 SDK or newer), and an Apple ID
added to Xcode (a **free** Apple ID works for local run; your paid Developer account is only
needed later for the App Store — and for the optional Test D entitlement).

---

## Step 1 — Create the Xcode project

We don't check a generated `.xcodeproj` into git (it's noisy and Xcode-version-specific);
instead you create it locally in ~1 minute and drop in the source files from `Spike/`.

1. Open **Xcode → File → New → Project…**
2. Choose **macOS → App**, then **Next**.
3. Fill in:
   - **Product Name:** `MedTrackerSpike`
   - **Team:** your Apple ID / team (pick "Add an Account…" if none listed)
   - **Organization Identifier:** `com.jamiewhite` (or your reverse-domain)
     → this makes the **bundle ID** `com.jamiewhite.MedTrackerSpike`
   - **Interface:** SwiftUI **Language:** Swift
   - Leave "Use Core Data" / "Include Tests" unchecked.
4. **Save it inside this folder** (`medtracker-mac/`) so it sits next to `Spike/`.

## Step 2 — Add the spike source files

Xcode generated a `MedTrackerSpikeApp.swift` and `ContentView.swift`. Replace them with ours:

1. In the Xcode Project navigator, **delete** the generated `MedTrackerSpikeApp.swift` and
   `ContentView.swift` (Move to Trash).
2. **Drag all six files from `Spike/` into the project** (into the `MedTrackerSpike` group):
   `MedTrackerSpikeApp.swift`, `AppDelegate.swift`, `SpikeView.swift`,
   `SpikeLog.swift`, `NotificationManager.swift`, `SpikeAPIClient.swift`.
   In the drop dialog: **"Copy items if needed" OFF**, **"Add to target: MedTrackerSpike" ON**
   (referencing them in place keeps git as the source of truth).
3. Build once (**⌘B**). It should compile with no errors.

## Step 3 — Signing & Capabilities

1. Select the project → **MedTrackerSpike** target → **Signing & Capabilities**.
2. **Automatically manage signing** ON; pick your **Team**. Xcode registers the bundle ID for
   you — no manual Developer-portal step needed for the core test.
3. The core notification test (Tests A–C) needs **no special entitlement** — a plain notification
   fires when quit. Leave capabilities as-is for now.
4. For **Test E** (backend round-trip), the sandboxed app needs outbound network: click
   **+ Capability → App Sandbox** (if not already present), then check **Outgoing Connections
   (Client)**. (The provided `Spike/MedTrackerSpike.entitlements` sets exactly sandbox +
   network-client if you'd rather point the target's _Code Signing Entitlements_ build setting
   at it — it deliberately does **not** include the Test D entitlement, so it signs fine on a
   free Apple ID.)
5. For **Test D** (time-sensitive / break-through-Focus) **only**: **+ Capability → Time
   Sensitive Notifications**. This is a _self-service_ entitlement (no Apple approval, unlike
   critical alerts) but **requires a paid Developer account** to provision — a free Apple ID
   cannot sign it. Skip it until Tests A–C pass, and don't add it if you're on a free account.

---

## Step 4 — Run the tests

Run the app (**⌘R**). A window with four sections appears.

### Test A — the make-or-break: fires while QUIT

1. Click **"Request notification permission"** → **Allow** in the system prompt.
   (If you previously denied it: System Settings → Notifications → MedTrackerSpike → Allow.)
2. Click **"Fire in 60s"**. The log shows `SCHEDULED … Now QUIT the app`.
3. **Quit the app with ⌘Q** (fully quit — not just close the window). Optionally confirm it's
   gone from the Dock.
4. **Wait.** At ~60s a **MedTracker spike** banner should appear in the top-right **even though
   the app is not running.**
   - ✅ **Banner appears while quit → the core assumption holds.**
   - ❌ No banner → note your macOS version + Notification settings and stop here; we rethink.

> Tip: also try **"Fire in 5 min"**, quit, and go do something else — confirms it's not just a
> "still warm in memory" artifact.

### Test B — survives sleep

Schedule **"Fire in 5 min"**, quit, then **close the lid / let the Mac sleep**. Wake it after
the interval — the banner should be waiting (or arrive on wake). Confirms reminders survive
the most common real-world state.

### Test C — action round-trips into the app (app was quit)

1. Schedule **"Fire in 15s"**, then **⌘Q**.
2. When the banner appears, **hover it and click "Log dose"** (the action button).
3. The app **relaunches**; its event log should show
   `ACTION 'Log dose' tapped … app relaunched/handled ✅`.
   - This proves a notification action can drive a real mutation (log a dose) even from a cold
     start — exactly what the real reminder flow needs.
   - (Note: because the app was quit when the notification fired, there is no "delivered"
     log line for it — that callback only runs in the foreground; the evidence for Test A is
     simply _seeing the banner with the app closed_. The log line here is the action-handling
     one written on relaunch, and it persists via UserDefaults so it's visible when the window
     returns.)

### Test D — time-sensitive breaks through Focus (optional, additive)

1. Add the **Time Sensitive Notifications** capability (Step 3.5) and rebuild.
2. Turn on a **Focus** (e.g. Do Not Disturb) from Control Center.
3. Click **"Fire in 60s — TIME-SENSITIVE"**, quit, wait.
   - ✅ Banner breaks through Focus → time-sensitive reminders work (no critical-alerts needed).
   - ❌ Suppressed → we fall back to normal-level reminders + document the limitation (still fine
     for v1; the design already treats time-sensitive as best-effort).

### Test E — backend round-trip (secondary)

1. In section 3, set **Base URL** to your deployed web app (e.g. `https://<your-app>.vercel.app`)
   and enter a **test account** email/password (the merged `/api/v1` deploys with the app).
2. Click **"Test /api/v1 login + sync"**. Expect:
   `API login OK … / API sync OK ✅ — fullResync=true, medications=N, doseLogs=M`.
   - Proves the Mac app can authenticate (bearer = Lucia session id) and pull the shared dataset.
   - If the account has 2FA on, the log says so and stops — that's expected (we wire `/auth/2fa`
     in the real app).

---

## Go / No-Go criteria

| Result         | Meaning                                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| **Test A ✅**  | **GO.** Native local reminders are viable → proceed to Phase 1 (Mac core).                                  |
| Test A ❌      | **STOP.** Rethink reminders before building. Capture macOS version + notification settings and report back. |
| Tests C & E ✅ | The action→mutation and auth→sync paths (the two riskiest integration seams) are proven.                    |
| Test D result  | Informational — determines whether reminders break through Focus; either outcome is shippable.              |

When you've run these, tell me the outcome (especially Test A) and I'll write the **Phase 1
(Mac core) implementation plan**: the Swift domain-parity port (tests first), GRDB persistence,
the sync engine against `/api/v1`, and the first screens.

---

## Notes / gotchas

- **Notifications need a real app bundle** (this is why it's an Xcode App, not a Swift script) —
  a bundle ID is required for `UNUserNotificationCenter` to register.
- **First-run permission:** if you don't see the Allow prompt, the app may have been denied
  earlier — reset via System Settings → Notifications → MedTrackerSpike.
- **"Fires when quit" is a system guarantee** for _pre-scheduled_ one-shot/calendar triggers:
  the system holds and delivers them. What the real app can't do while quit is _re-compute the
  next interval reminder_ after one fires — that's the "launch-at-login menu-bar agent" mitigation
  in the design spec, and is out of scope for this spike.
- **AlarmKit** (true alarm UI) is iOS/iPadOS-only, not native macOS — so time-sensitive
  notifications are the ceiling on the Mac. This spike measures exactly that ceiling.
