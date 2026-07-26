# Phase 1a — Mac Core: Domain-Parity Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `medtracker-mac` Swift package workspace and port the web app's pure domain layer to Swift, transcribing its unit tests as an executable **parity contract** — the de-risking foundation every later phase builds on. No UI, no network.

**Architecture:** Two local Swift packages, each `swift test`-able headlessly (no Xcode needed): **`MedTrackerCore`** (pure domain — schedule/timing/refill/adherence/insights/sparkline/style/formatters; zero deps beyond Foundation) and **`MedTrackerData`** (GRDB/SQLite schema, migrations, repositories with the load-bearing transactions). The parity tests transcribe the web app's `tests/unit/*.test.ts` into Swift Testing; DST/timezone tests are written **first**, before any consumer, because Foundation `Calendar` and JS `Intl` resolve DST differently and that divergence is the single biggest correctness risk in the whole port.

**Tech Stack:** Swift 6.2 (Swift 5 language mode for now — flip to 6 later), Foundation, GRDB.swift 7 (SQLite), Swift Testing, SwiftLint + SwiftFormat, XcodeGen (already installed) for the eventual app target (not needed in 1a). Minimum deployment macOS 15.

**Reference implementation (the source of truth to port from):** the merged web app at `/Users/jamiewhite/Documents/Personal/Projects/medication-tracker` (branch `main`). Each task cites the exact TS source file and its test file. **Open the TS file and its test alongside each task** — the Swift is a faithful translation, and the transcribed tests are the acceptance criteria.

## Global Constraints

_Every task's requirements implicitly include this section. Values are copied verbatim from the web app; a Swift result that disagrees is a bug in the port, not an "improvement."_

- **Parity is the contract.** Port behavior exactly. If you believe the web behavior is wrong, note it and keep it — do NOT silently "fix" it (that changes user-visible numbers). Intentional divergences are listed in the design spec's "inherited-quirks register" and are out of scope for 1a.
- **Timezone:** all day boundaries, slot resolution, and date bucketing use the **user's profile IANA timezone** (a stored `Profile.timezone`), NOT `TimeZone.current`. Model it as an explicit `TimeZone` parameter threaded through every function that needs it — never read the ambient zone inside a pure function.
- **`daysOfWeek` is `0=Sunday…6=Saturday`** (matches Postgres `extract(dow)` and the JSON stored by the web app). Convert to Foundation's `Calendar.component(.weekday)` (which is `1=Sunday…7=Saturday`) with **`+1`** exactly at the Calendar boundary.
- **Numbers:** `dosageAmount` and `intervalHours` are `Decimal` in Swift (they were numeric-as-string in TS). `inventoryCount`/`quantity` are `Int` in **doses**, not raw units.
- **IDs:** cuid2 `TEXT` everywhere (Task 2 ports a cuid2 generator).
- **JS `Math.round` vs Swift rounding:** JS `Math.round` rounds half **up** (toward +∞): `round(-0.5) == 0`, `round(2.5) == 3`. Swift's `.rounded()` uses `.toNearestOrAwayFromZero` (`(-0.5).rounded() == -1`). Inputs here are non-negative in nearly all cases, but where a rounded value can be negative (trend deltas), replicate JS half-up explicitly: `(x + 0.5).rounded(.down)`. Add a `jsRound(_:)` helper in Task 3 and use it wherever the TS calls `Math.round`.
- **Exact constants (carry verbatim):**
  - Dose→slot match tolerance: **±1 hour** (`3_600_000` ms); greedy, one dose per slot, ascending slot order.
  - Timing status: overdue when `msUntilDue ≤ −60_000`; due_now when `−60_000 < ms ≤ +60_000`; due_soon when `≤ 3_600_000`; else ok. Never-handled → overdue with `minutesUntilDue = −1`.
  - Refill severity: **critical ≤ 3d, warning ≤ 7d, watch ≤ 14d**, else ok; `days = floor(inventory / dailyRate)`, nil when inventory nil or `dailyRate ≤ 0`.
  - Daily-rate selection order: (1) schedule rows if `expectedPerDay > 0`; (2) legacy `24/intervalHours` when `scheduleType == "scheduled"` and interval finite `> 0`; (3) `thirtyDayTakenQuantity / 30`; else 0.
  - Expected doses/day per schedule row: interval `24/hrs`; fixed_time `daysOfWeek.count/7` if non-empty else `1`; prn `0`.
  - Adherence `= min(100, jsRound(taken/expected * 1000)/10)` (1-decimal); overuse `= jsRound((taken−expected)/expected * 1000)/10` when `taken > expected` else 0; both 0 when `expected == 0`.
  - Stat windows: weekly = last `7*24h`; list-view avg-daily = `(rows in last 30*24h)/30` (row count, any status); refill 30-day signal = **sum of `quantity` of `taken` rows only**.
  - Time-of-day buckets by **local hour**: morning `[5,12)` ☀️, afternoon `[12,17)` 🌤️, evening `[17,21)` 🌅, night otherwise 🌙.
  - Streak: 0 unless `dates[0]` equals today's `en-CA` (`yyyy-MM-dd`) date in the user tz; then count consecutive days where the gap rounds to exactly 1.
  - Insights (max 5, sorted warning=0/positive=1/info=2): trend needs `medStats.count ≥ 2 && prevAvg > 0 && |avg−prev| ≥ 5`; highest/lowest need `≥ 2` meds with `expectedTotal > 0`, lowest emits only when bottom `< 80`; worst-day needs `total(dow) ≥ 7` and `min < avg*0.7`; peak-hour needs `total(hour) ≥ 5` and `maxHour ≥ total*0.3`; side-effects needs `≥ 3` occurrences; streak needs `≥ 3`; refill counts entries with severity `critical` OR `warning`. **Exact strings including the em dash `—`** (see Task 7).
  - `clampEffectiveDays` = rounded-day count of the intersection of `[rangeFrom, rangeTo]` and `[startedAt, endedAt ?? +∞]`; 0 if no overlap; an overlap under 12h rounds to 0.
  - Contrast picker: candidates `#111111` / `#ffffff`; sRGB linearize `s ≤ 0.04045 ? s/12.92 : ((s+0.055)/1.055)^2.4`; luminance `0.2126R+0.7152G+0.0722B`; ratio `(hi+0.05)/(lo+0.05)`; pick the candidate with the **greater worst-case** ratio across every rendered colour (secondary counted only when pattern ≠ solid and c2 ≠ c1); tie → dark.
  - Validation: schedule interval `0 < h ≤ 72`; `timeOfDay` matches `^([01]\d|2[0-3]):[0-5]\d$`; `daysOfWeek` ints 0–6, ≤ 7; 1–20 schedule rows per med. Dose quantity `≥ 1` (create), `1…10` (edit); notes ≤ 500; side effects ≤ 20.
- **Coverage floor:** every ported module ships with its transcribed test suite; a module without its tests is not "done." CI (Task 12) runs `swift test` on both packages.

## File Structure

```
medtracker-mac/
  Packages/
    MedTrackerCore/
      Package.swift
      Sources/MedTrackerCore/
        Cuid2.swift                 # Task 2
        JSRound.swift + Time.swift  # Task 3  (formatters, startOfDay, parseWallClock, jsRound, local-date helpers)
        Schedule.swift              # Task 4  (ScheduleRow, computeScheduleSlots, computeTimingStatus, classifyHour, groupSlotsByTimeOfDay)
        Inventory.swift             # Task 5  (dailyRateFor, classifyRefillSeverity, daysUntilRefill, expectedPerDayForSchedules)
        Analytics.swift             # Task 6  (adherence, overuse, streak, trend, clampEffectiveDays, isActiveOn, distributions)
        Insights.swift              # Task 7  (buildInsights + InsightInputs)
        Sparkline.swift             # Task 8
        MedicationStyle.swift       # Task 9  (getReadableTextColor, pattern geometry enums)
        Reminders.swift             # Task 10 (isOverdue for interval/fixed_time, dedupe-key strings)
        Csv.swift                   # Task 11 (escapeCsvCell, dose-CSV row builder — pure)
        Models.swift                # shared value types (Medication, Schedule, DoseLog, SideEffect, enums)
      Tests/MedTrackerCoreTests/    # one file per module, transcribed from tests/unit/*.test.ts (+ DST additions)
    MedTrackerData/
      Package.swift                 # depends on GRDB.swift 7 + MedTrackerCore
      Sources/MedTrackerData/
        Schema.swift                # Task 13 (GRDB record types + column defs)
        Migrations.swift            # Task 13 (DatabaseMigrator v1)
        LocalDateFunction.swift     # Task 13 (registered SQL function: localDate(epoch, tz))
        Database.swift              # Task 13 (DatabaseQueue/Pool factory, foreign_keys ON, WAL)
        Repositories/*.swift        # Task 14 (transactional units)
      Tests/MedTrackerDataTests/
  .github/workflows/ci.yml          # Task 15
```

_Not in Phase 1a:_ the app target / SwiftUI (Phase 1c), the API client + sync engine (Phase 1b), `MedTrackerServices` (notifications/export — Phase 2). Keep those out.

---

### Task 1: Package scaffolding

**Files:**

- Create: `Packages/MedTrackerCore/Package.swift`, `Sources/MedTrackerCore/Placeholder.swift`, `Tests/MedTrackerCoreTests/SmokeTests.swift`

**Interfaces:**

- Produces: a `swift test`-able `MedTrackerCore` package (Swift Testing), macOS 15 platform.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerCore", targets: ["MedTrackerCore"])],
    targets: [
        .target(name: "MedTrackerCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MedTrackerCoreTests", dependencies: ["MedTrackerCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

- [ ] **Step 2: Write the smoke test**

`Tests/MedTrackerCoreTests/SmokeTests.swift`:

```swift
import Testing
@testable import MedTrackerCore

@Test func packageBuilds() {
    #expect(Bool(true))
}
```

`Sources/MedTrackerCore/Placeholder.swift`: `enum MedTrackerCore {}` (delete once real code lands).

- [ ] **Step 3: Run**

Run: `cd Packages/MedTrackerCore && swift test`
Expected: 1 test passes.

- [ ] **Step 4: Commit**

```bash
git add Packages/MedTrackerCore
git commit -m "chore(core): scaffold MedTrackerCore package (Swift Testing)"
```

---

### Task 2: cuid2 generator

**Files:**

- Create: `Sources/MedTrackerCore/Cuid2.swift`, `Tests/MedTrackerCoreTests/Cuid2Tests.swift`

**Interfaces:**

- Produces: `func createId() -> String` — a 24-char cuid2-format id (lowercase letter start, base36 body). We do NOT need byte-for-byte compatibility with `@paralleldrive/cuid2`, only a collision-resistant id of the same shape; the web app's ids arrive via sync and are stored verbatim, so ours only need to be valid `TEXT` primary keys.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import MedTrackerCore

@Test func idShape() {
    let id = createId()
    #expect(id.count == 24)
    #expect(id.first!.isLetter)
    #expect(id.allSatisfy { $0.isLowercase || $0.isNumber })
}
@Test func idsAreUnique() {
    let ids = Set((0..<10_000).map { _ in createId() })
    #expect(ids.count == 10_000)
}
```

- [ ] **Step 2: Run red** — `swift test --filter Cuid2` → fails (no `createId`).
- [ ] **Step 3: Implement** a cuid2-style generator: first char = random `a…z`; then 23 chars from a SHA-256 over a counter + random entropy + high-res timestamp, base36-encoded. (A compact, well-known implementation: hash `"\(counter)\(UInt64.random)\(DispatchTime.now().uptimeNanoseconds)"`, base36 the digest, take 23 chars.) Keep it dependency-free (use `import Crypto` only if you add swift-crypto; otherwise a small SHA-256 or even `UUID`-derived base36 is acceptable for local ids).
- [ ] **Step 4: Run green**, then **Commit**: `feat(core): cuid2-style id generator`.

---

### Task 3: Time utilities + DST-parity tests (write these FIRST)

**Port from:** `src/lib/utils/time.ts`. **Transcribe:** `tests/unit/time.test.ts`.

**Files:**

- Create: `Sources/MedTrackerCore/JSRound.swift`, `Sources/MedTrackerCore/Time.swift`, `Tests/MedTrackerCoreTests/TimeTests.swift`

**Interfaces (produce these exact signatures — later tasks depend on them):**

- `func jsRound(_ x: Double) -> Int` — JS `Math.round` semantics (half up toward +∞).
- `func formatTimeSince(_ from: Date, now: Date) -> String` — `<60s`→"just now"; `<60m`→"{m}m ago"; `<24h`→"{h}h {m}m ago"; else "{d}d ago" (all floors).
- `func formatDueIn(msUntilDue: Double) -> String` — `|ms|<60000`→"Due now"; else "Due in {h}h {m}m"/"Overdue {h}h {m}m" omitting zero components.
- `func startOfDay(_ date: Date, timeZone: TimeZone) -> Date` — the UTC instant of local midnight in `timeZone`.
- `func localDateString(_ date: Date, timeZone: TimeZone) -> String` — `yyyy-MM-dd` (en-CA) of the local date.
- `func localDayOfWeek(_ date: Date, timeZone: TimeZone) -> Int` — `0=Sunday…6=Saturday`.
- `func wallClockToUTC(year:month:day:hour:minute:timeZone:) -> Date` — resolve a wall-clock in `timeZone` to a UTC instant (the DST-critical one; see spec §8).

**Why first:** these underpin schedules, analytics, and reminders. Getting DST right here means everything above it is correct.

- [ ] **Step 1: Transcribe `time.test.ts` verbatim** into `TimeTests.swift` (each `it(...)` → a `@Test`), using a fixed `TimeZone(identifier: "Europe/London")` and `America/New_York` where the TS uses them. Keep the exact expected strings.

- [ ] **Step 2: ADD DST parity tests** (these do not exist in the TS suite — they are the new safety net). Use `America/New_York` (spring-forward 2026-03-08 02:00→03:00, fall-back 2026-11-01 02:00→01:00):

```swift
private let nyc = TimeZone(identifier: "America/New_York")!

@Test func startOfDay_springForwardDay() {
    // 2026-03-08 is a 23-hour day in NYC. Local midnight is still a well-defined instant.
    let noonUTC = ISO8601DateFormatter().date(from: "2026-03-08T17:00:00Z")!  // 12:00 EST
    let sod = startOfDay(noonUTC, timeZone: nyc)
    #expect(localDateString(sod, timeZone: nyc) == "2026-03-08")
    // local midnight of 03-08 EST = 05:00 UTC
    #expect(sod == ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z")!)
}

@Test func wallClock_insideSpringForwardGap() {
    // 02:30 on 2026-03-08 does not exist (clocks jump 02:00→03:00).
    // Pin the chosen instant: document what Calendar returns and assert it, so a
    // future Foundation change is caught. (Foundation resolves the gap forward.)
    let d = wallClockToUTC(year: 2026, month: 3, day: 8, hour: 2, minute: 30, timeZone: nyc)
    // Expect the gap to resolve to 03:30 EDT = 07:30 UTC (assert whatever it actually is; the
    // point is a PINNED, documented value — cross-check against the TS offset-subtraction result).
    #expect(ISO8601DateFormatter().string(from: d) == "2026-03-08T07:30:00Z")
}

@Test func wallClock_fallBackAmbiguousHour() {
    // 01:30 on 2026-11-01 occurs twice. Pin which instant Foundation picks (first occurrence, EDT).
    let d = wallClockToUTC(year: 2026, month: 11, day: 1, hour: 1, minute: 30, timeZone: nyc)
    #expect(ISO8601DateFormatter().string(from: d) == "2026-11-01T05:30:00Z")  // 01:30 EDT
}
```

> When you implement `wallClockToUTC`, first run these tests to discover what Foundation actually returns for the gap/ambiguous cases, then **write that value into the assertion** and add a comment noting it matches (or, if it doesn't, how it differs from) the TS `localTimeOnDateToUtc` offset-subtraction result in `schedule.ts:74-101`. The goal is a pinned contract, not a guessed one.

- [ ] **Step 3: Run red** (`swift test --filter TimeTests`), **implement `Time.swift` + `JSRound.swift`** using a `Calendar(identifier: .gregorian)` with `.timeZone` set (do NOT use `Intl`-style offset subtraction — `Calendar.date(from: DateComponents)` and `startOfDay(for:)` are the idiomatic, DST-correct primitives). **Run green.**

- [ ] **Step 4: Commit** — `feat(core): time/date utilities with DST parity tests`.

---

### Task 4: Schedule slot computation

**Port from:** `src/lib/utils/schedule.ts`. **Transcribe:** `tests/unit/schedule.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Models.swift` (the value types below), `Sources/MedTrackerCore/Schedule.swift`, `Tests/MedTrackerCoreTests/ScheduleTests.swift`.

**Interfaces:**

- In `Models.swift`: `enum ScheduleKind { case interval, fixedTime, prn }`, `struct ScheduleRow { let kind: ScheduleKind; let intervalHours: Decimal?; let timeOfDay: String?; let daysOfWeek: [Int]? }`, `enum SlotStatus { case taken, skipped, upcoming, overdue }`, `struct ScheduleSlot { let medicationId: String; let expectedTime: Date; var status: SlotStatus; var matchedDoseId: String? }`, `enum TimingStatus { case ok, dueSoon, dueNow, overdue }`.
- `func computeScheduleSlots(medications:, schedulesByMedId:, todaysDoses:, lastTakenByMed:, dayStart: Date, dayEnd: Date, timeZone: TimeZone, now: Date) -> [String: [ScheduleSlot]]` — union of expected times per non-PRN rule; interval projects from last-taken anchor (or dayStart) stepping `intervalHours`, fast-forwarding an anchor before dayStart by `ceil((dayStart−anchor)/interval)` intervals and including the anchor itself if inside `[dayStart,dayEnd)`; fixed_time emits one instant per local date in the window resolved via `wallClockToUTC`, filtered by `daysOfWeek`; dedupe by exact instant; greedy match each slot to the earliest unused dose within ±1h; status per the rules in Global Constraints.
- `func computeTimingStatus(intervalHours: Decimal, lastEventAt: Date?, now: Date) -> (status: TimingStatus, minutesUntilDue: Int)` — the ±60s / 1h windows; never-handled → `(.overdue, -1)`.
- `func classifyHour(_ localHour: Int) -> TimeOfDayBucket` and `func groupSlotsByTimeOfDay(_ slots: [ScheduleSlot], timeZone: TimeZone) -> [(bucket: TimeOfDayBucket, slots: [ScheduleSlot])]`.

- [ ] **Step 1: Transcribe `schedule.test.ts`** into `ScheduleTests.swift` (all cases, exact expected values).
- [ ] **Step 2: ADD DST slot cases:** a `fixed_time` rule at `02:30` and at `08:00` across the NYC spring-forward and fall-back days (Task 3's dates), asserting the emitted UTC instants and that exactly one slot per local day is produced. A weekly `daysOfWeek` rule crossing a DST boundary to confirm the `0..6 → weekday 1..7` mapping still selects the right local days.
- [ ] **Step 3: Run red → implement `Schedule.swift` → run green.** Reuse `wallClockToUTC`/`localDayOfWeek` from Task 3. Keep the interval anchor math integer-exact (`ceil`), and the greedy one-dose-per-slot matching in ascending slot order.
- [ ] **Step 4: Commit** — `feat(core): schedule slot + timing-status computation`.

---

### Task 5: Inventory & refill forecasting

**Port from:** `src/lib/server/inventory.ts` (+ `expectedPerDayForSchedules` from `analytics.ts:17-30`; + legacy list-view `calculateDaysUntilRefill` from `time.ts:80-100`). **Transcribe:** `tests/unit/inventory.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Inventory.swift`, `Tests/MedTrackerCoreTests/InventoryTests.swift`.

**Interfaces:**

- `enum RefillSeverity { case critical, warning, watch, ok }`
- `func expectedPerDay(forSchedules rows: [ScheduleRow]) -> Double`
- `func dailyRateFor(scheduleRows: [ScheduleRow], legacyScheduleType: String?, legacyIntervalHours: Decimal?, thirtyDayTakenQuantity: Int) -> Double` — the 3-tier selection order (Global Constraints).
- `func classifyRefillSeverity(days: Int?) -> RefillSeverity` — `≤0`→critical; else 3/7/14 tiers; `nil`→ok.
- `func daysUntilRefill(inventoryCount: Int?, dailyRate: Double) -> Int?` — `floor(inventory/rate)`; nil when inventory nil or rate ≤ 0.

- [ ] **Steps:** transcribe `inventory.test.ts` → red → implement → green → commit `feat(core): refill forecasting + daily-rate selection`. Note the deliberate difference the tests encode: forecasting uses **taken-quantity** over 30 days, while the list-view avg (a separate legacy path) counts rows of any status — port both faithfully and keep them distinct.

---

### Task 6: Analytics math

**Port from:** `src/lib/server/analytics.ts` (adherence/overuse, `calculateStreak`, `calculateTrend`, distributions helpers) and `src/lib/server/analytics/lifecycle.ts` (`clampEffectiveDays`, `isActiveOn`). **Transcribe:** `tests/unit/analytics.test.ts`, `tests/unit/analytics-lifecycle.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Analytics.swift`, `Tests/MedTrackerCoreTests/AnalyticsTests.swift`, `.../AnalyticsLifecycleTests.swift`.

**Interfaces:**

- `func adherencePercent(taken: Int, expected: Int) -> Double` (1-decimal, cap 100), `func overusePercent(taken: Int, expected: Int) -> Double`.
- `func calculateStreak(dateStringsNewestFirst: [String], today: String) -> Int`.
- `func calculateTrend(current: Double, previous: Double) -> (direction: TrendDirection, percent: Int)` — `(0,0)`→flat/0; `prev==0`→up/100; else `jsRound(|Δ%|)`, 0→flat.
- `func clampEffectiveDays(rangeFrom: Date, rangeTo: Date, startedAt: Date, endedAt: Date?) -> Int`, `func isActiveOn(_ date: Date, startedAt: Date, endedAt: Date?) -> Bool`.

- [ ] **Steps:** transcribe both test files → red → implement (use `jsRound` and the exact `round(x*1000)/10` shape for 1-decimal) → green → commit `feat(core): adherence/streak/trend + lifecycle clamping`.

---

### Task 7: Insights engine

**Port from:** `src/lib/server/analytics.ts:buildInsights` (rules `:455-542`). **Transcribe:** the `buildInsights` cases in `tests/unit/analytics.test.ts` (or wherever they live — grep `buildInsights`).

**Files:** Create `Sources/MedTrackerCore/Insights.swift`, `Tests/MedTrackerCoreTests/InsightsTests.swift`.

**Interfaces:**

- `struct InsightInputs { ... }` — a plain struct holding the already-computed stats each rule reads (medStats with adherence/expectedTotal/name, avgAdherence, prevAvgAdherence, dayOfWeekCounts [7], hourCounts [24], sideEffectTotal, topSideEffectName, streak, refillCriticalCount). Mirror exactly what the TS function destructures.
- `struct Insight: Equatable { let id: String; let severity: InsightSeverity; let text: String }`
- `func buildInsights(_ inputs: InsightInputs) -> [Insight]` — the 7 predicates, sorted `warning(0)/positive(1)/info(2)`, truncated to 5.

- [ ] **Step 1: Transcribe the insight tests**, asserting the **exact strings** — copy them character-for-character, including the em dash `—` in `"{n} side effects logged — most common: {name}"` and the exact wording of each (`"Adherence improved 5% vs. previous period"`, `"Highest adherence: {name} ({adh}%)"`, `"Lowest adherence: {name} ({adh}%)"`, `"Fewest doses on {Weekday}"`, `"Most consistent dosing time is {HH}:00"`, `"1 medication needs a refill within 7 days"` / `"{n} medications need a refill within 7 days"`, `"Current streak: {n} days"`). Weekday names are full English (`Sunday…Saturday`) indexed by Postgres dow. Hour is zero-padded.
- [ ] **Step 2: red → implement → green → commit** `feat(core): deterministic insights engine (parity strings)`. Keep insight `id`s stable (they drive UI diffing/accessibility later).

---

### Task 8: Sparkline geometry

**Port from:** `src/lib/utils/sparkline.ts:buildSparklineShape`. **Transcribe:** `tests/unit/sparkline.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Sparkline.swift`, `Tests/MedTrackerCoreTests/SparklineTests.swift`.

**Interfaces:** `struct SparklineShape { let line: String; let area: String; let dotX: Double?; let dotY: Double? }`, `func buildSparklineShape(values: [Double], width: Double, height: Double, strokeWidth: Double = 1.5) -> SparklineShape` — n=0 → empty; n=1 → centered dot; else min/max-normalized polyline with `y = height − ((v−min)/range)*(height−strokeWidth) − strokeWidth/2` (flat midline when range 0), all coords rounded to **1 decimal**; `area = line + " L {lastX} {height} L {firstX} {height} Z"`.

- [ ] **Steps:** transcribe → red → implement (round to 1 decimal exactly as TS does) → green → commit `feat(core): sparkline path geometry`.

---

### Task 9: Medication style (contrast + patterns)

**Port from:** `src/lib/utils/medication-style.ts`. **Transcribe:** `tests/unit/medication-style.test.ts`.

**Files:** Create `Sources/MedTrackerCore/MedicationStyle.swift`, `Tests/MedTrackerCoreTests/MedicationStyleTests.swift`.

**Interfaces:**

- `enum ReadableTextColor { case dark, light }` with hex `#111111` / `#ffffff`.
- `func getReadableTextColor(colour: String, colourSecondary: String?, pattern: MedicationPattern) -> ReadableTextColor` — the WCAG worst-case-contrast picker (Global Constraints); invalid hex → luminance 0.
- `enum MedicationPattern: String { case solid, split, gradient, stripes, hStripes = "h-stripes", dots, checkerboard, radial }` and a pure description of each pattern's rendered colours (used by the picker and, later, by SwiftUI rendering in 1c). Pattern→SwiftUI fills are NOT in 1a; only the colour-set + contrast math is.

- [ ] **Steps:** transcribe → red → implement the sRGB linearization + luminance + ratio exactly (use `Double`, `pow`) → green → commit `feat(core): WCAG readable-text-colour picker`.

---

### Task 10: Reminder domain (pure parts)

**Port from:** `src/lib/server/reminders/domain.ts` (the `isOverdue`/slot + dedupe-key pure functions only — NOT the dispatch/DB/channel code). **Transcribe:** the relevant cases in `tests/unit/reminders-dedupe.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Reminders.swift`, `Tests/MedTrackerCoreTests/RemindersTests.swift`.

**Interfaces:**

- `func intervalOverdueSlot(intervalHours: Decimal, lastTakenAt: Date?, now: Date) -> Date?` — nil if never taken; overdue iff `now − lastTaken > interval` (strict); slot = `lastTaken + interval`.
- `func fixedTimeOverdueSlot(timeOfDay: String, daysOfWeek: [Int]?, now: Date, timeZone: TimeZone, hasTakenWithin1h: Bool) -> Date?` — today's slot in tz; nil if future, if weekday excluded, or if suppressed by a taken dose within ±1h.
- `func overdueDedupeKey(userId:medicationId:scheduleKind:scheduleId:slot: Date) -> String` = `"{userId}:{medicationId}:overdue:{kind}:{scheduleId}:{slotISO}"` (ISO-8601 with milliseconds). `func lowInventoryDedupeKey(userId:medicationId:count:) -> String`.

These dedupe-key strings become the `UNNotificationRequest` identifiers in Phase 2 — porting them now keeps the identifier format identical to the web's.

- [ ] **Steps:** transcribe → red → implement → green → commit `feat(core): reminder overdue + dedupe-key logic`.

---

### Task 11: CSV escaping (pure export helper)

**Port from:** `src/lib/server/export-csv.ts` (the pure `escapeCsvCell` + dose-row builder; NOT the DB query). **Transcribe:** `tests/unit/export-csv.test.ts`.

**Files:** Create `Sources/MedTrackerCore/Csv.swift`, `Tests/MedTrackerCoreTests/CsvTests.swift`.

**Interfaces:** `func escapeCsvCell(_ value: String?) -> String` — formula-injection guard (prefix `'` when the cell starts with `= + - @ TAB CR`), double internal quotes, wrap in quotes when it contains `" , CR LF`; and a `func doseCsvRows(...) -> String` producing the exact column order `Date,Time,Status,Medication,Dosage,Quantity,Notes,Side Effects` joined with `CRLF`. (PDF/CSV file _emission_ via `NSSavePanel` is Phase 2; only the pure string building is here.)

- [ ] **Steps:** transcribe → red → implement → green → commit `feat(core): CSV escaping + dose-row builder`.

---

### Task 12: Core coverage gate + lint

**Files:** Create `.swiftlint.yml`, `.swiftformat`; run the full core suite.

- [ ] **Step 1:** `cd Packages/MedTrackerCore && swift test` — the entire transcribed suite passes. Record the count (it should be in the ballpark of the ~358 web cases plus the DST additions).
- [ ] **Step 2:** add minimal `.swiftlint.yml` / `.swiftformat` (opt-in rules; don't fight the tool) and run `swiftformat --lint .` clean over `Packages/`.
- [ ] **Step 3: Commit** — `chore(core): lint config; full parity suite green`.

---

### Task 13: GRDB schema, migrations, and the timezone SQL function

**Files:** Create `Packages/MedTrackerData/Package.swift` (deps: GRDB.swift 7, MedTrackerCore), `Sources/MedTrackerData/{Schema,Migrations,LocalDateFunction,Database}.swift`, `Tests/MedTrackerDataTests/SchemaTests.swift`.

**Interfaces:**

- GRDB record types for: `medication`, `medication_schedule` (with the 3-way `CHECK` mirroring the TS discriminated union), `dose_log`, `inventory_event`, `audit_log`, `reminder_event`, `profile`, `settings`, plus local-only `outbox`, `sync_state`. IDs cuid2 `TEXT`; timestamps `UTC epoch` (Double or Date via GRDB); `dosageAmount`/`intervalHours` as `TEXT` decimal surfaced as `Decimal`; `side_effects`/`days_of_week` as JSON `TEXT`. `foreign_keys = ON`, `ON DELETE CASCADE`, WAL.
- `DatabaseMigrator` `v1` creating all tables + indexes (mirror the web's index set: `(user_id, updated_at)` etc. — though local is single-user, keep `userId` columns for sync-readiness).
- A registered `DatabaseFunction localDate(epochSeconds, tzIdentifier)` backed by a cached `Calendar`, so timezone-correct `GROUP BY` (daily counts, hourly/dow distributions) runs in SQL honoring the profile tz.

- [ ] **Step 1: Write a schema test** that opens an in-memory `DatabaseQueue`, runs the migrator, and asserts each table + the CHECK constraint rejects an invalid schedule row (e.g. an `interval` row with a `time_of_day`), and that `localDate(epoch, 'America/New_York')` returns the expected local date across a DST boundary.
- [ ] **Step 2: red → implement Schema/Migrations/LocalDateFunction/Database → green.**
- [ ] **Step 3: Commit** — `feat(data): GRDB schema v1 + tz-aware localDate SQL function`.

---

### Task 14: Repositories — the load-bearing transactions

**Files:** Create `Sources/MedTrackerData/Repositories/{DoseRepository,MedicationRepository,InventoryRepository}.swift`, `Tests/MedTrackerDataTests/RepositoryTests.swift`.

**Interfaces (each is ONE `db.write { }` transaction — this is the property that retires the web's "Neon HTTP best-effort atomic" caveat):**

- `logDose(...)`: insert dose_log (status taken) + `inventoryCount = max(0, count − quantity)` (only when tracking) + `dose_taken` inventory_event with the **clamped** delta (`newCount − previousCount`) + audit row — all in one transaction.
- `deleteDose(...)`: restore inventory **only when status == taken**, **unclamped** (`count + quantity`), + `dose_deleted` event + audit — one transaction.
- `updateDose(...)`: inventory diff only when `status == taken && quantity changed`; `dose_quantity_updated` event with clamped signed delta.
- `refill(...)` / `adjustInventory(...)`: `refill` seeds a nil count; `adjust` rejects a zero change; each with its inventory_event.
- `upsertMedicationWithSchedules(...)`: medication row + delete-then-insert all schedule rows + audit — one transaction.

- [ ] **Step 1: Write repository tests** asserting each invariant against an in-memory DB: the clamped-vs-unclamped restore, the "only taken restores", the one-event-per-mutation pairing, the atomic rollback (inject a failure mid-transaction and assert nothing committed). These transcribe the intent of `tests/unit/doses-inventory.test.ts` / `inventory-events.test.ts` but against real SQLite (stronger than the web's mocked-db tests).
- [ ] **Step 2: red → implement → green.**
- [ ] **Step 3: Commit** — `feat(data): transactional dose/inventory/medication repositories`.

---

### Task 15: CI

**Files:** Create `.github/workflows/ci.yml`.

- [ ] **Step 1:** a GitHub Actions macOS-15 runner job that runs `swift test` in both `Packages/MedTrackerCore` and `Packages/MedTrackerData`, plus `swiftformat --lint`. Cache SwiftPM. Fail on any test or lint failure.
- [ ] **Step 2:** push a branch, open a draft PR against the medtracker-mac repo, confirm the workflow goes green.
- [ ] **Step 3: Commit** — `ci: swift test + format lint for core/data packages`.

---

## Self-Review

**Spec coverage (design spec §8 "Domain parity contract" + §9 "Local data model"):**

- Every pure function named in §8.1 → a task: time/DST (3), schedule slots + timing (4), refill/daily-rate/severity (5), adherence/streak/trend/clamp (6), insights (7), sparkline (8), contrast/patterns (9), reminder overdue + dedupe keys (10), CSV escaping (11). ✅
- §9 persistence: GRDB schema + CHECK constraints + tz SQL function (13); load-bearing transactions with clamped/unclamped semantics (14). ✅
- The parity-test-first + DST-before-UI mandate → Task 3 written first, DST cases added in 3 and 4, pinned-value approach documented. ✅
- Numeric-as-Decimal, `0=Sunday` conversion, `jsRound`, profile-tz-not-ambient → Global Constraints, enforced per task. ✅

**Deferred to later plans (correctly out of 1a):** SwiftUI/app target and pattern _rendering_ (1c); API client + sync engine + outbox reconciliation (1b); notifications, export file emission, app lock (Phase 2). The `outbox`/`sync_state` tables are created in Task 13 (schema-ready) but not driven until 1b.

**Open confirmations for the implementer (resolve at task start, don't block):**

- Exact contents of `tests/unit/schedule.test.ts` / `analytics.test.ts` fixtures — open them; the transcription is mechanical but the fixtures carry the precise inputs.
- Whether to add `swift-crypto` for the cuid2 hash (Task 2) or hand-roll — either is fine; prefer no new dep if a simple generator suffices.
- GRDB 7's exact API for registering a `DatabaseFunction` and JSON columns — check GRDB docs (Context7) at Task 13.
