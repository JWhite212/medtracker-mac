# Parity divergences (Mac app vs. web app)

Running register of intentional, reviewed divergences between the macOS
port's domain-core logic and the web app's TypeScript behavior. This is the
Mac-side equivalent of the web spec's inherited-quirks register — a place to
record deliberate "we chose the correct behavior even though it doesn't
byte-for-byte match the web" decisions, so a future porting task doesn't
mistake a divergence for a bug and "fix" it back into parity.

Append new entries below as they're found. Each entry should record what
diverges, the concrete impact, the decision, and what tests cover it.

---

## 1. `startOfDay` on DST-transition days

**Where:** `Packages/MedTrackerCore/Sources/MedTrackerCore/Time.swift` —
`startOfDay(_:timeZone:)`, vs. web `src/lib/utils/time.ts:168-194`.

**What diverges:** On the two days per year a time zone's UTC offset changes
(DST spring-forward / fall-back), Foundation's `startOfDay` and the web's
`startOfDay` disagree on which instant is local midnight.

- The web's `startOfDay` samples the local UTC offset at _noon_ of the target
  day and applies that single offset uniformly to compute midnight. This is
  wrong exactly on transition days, because the offset at midnight is not
  necessarily the same as the offset at noon.
- Foundation's `startOfDay` (via `Calendar` with the target `TimeZone`) asks
  for actual local midnight, which is always correct regardless of any
  transition that happens later that day.

Confirmed for `America/New_York`, 2026:

| Day                       | Input (UTC)            | Foundation `startOfDay` (correct)  | Web `startOfDay` (buggy)                               |
| ------------------------- | ---------------------- | ---------------------------------- | ------------------------------------------------------ |
| Spring-forward 2026-03-08 | `2026-03-08T17:00:00Z` | `2026-03-08T05:00:00Z` (00:00 EST) | `2026-03-08T04:00:00Z` (23:00 the _prior_ day — wrong) |
| Fall-back 2026-11-01      | `2026-11-01T17:00:00Z` | `2026-11-01T04:00:00Z` (00:00 EDT) | `2026-11-01T05:00:00Z` (01:00 — wrong)                 |

**Impact:** A dose logged close to local midnight on one of these two days
per year can bucket into a different local calendar day on the Mac app than
it would in the web app's server-side day-bucketed analytics (e.g. adherence
stats, daily dose counts). This only affects doses logged within roughly the
first hour or so after local midnight on the two transition days each year —
not any other day, and not any other time of day.

**Decision:** Keep Foundation's correct behavior. Do not "fix" the Mac app to
match the web's buggy offset-sampling approach. The web's `startOfDay` should
itself be fixed separately (tracked on the web side, out of scope for this
port); this port does not intentionally reproduce known web bugs where the
correct behavior is easy and safe to provide instead.

**Tested by:** `Packages/MedTrackerCore/Tests/MedTrackerCoreTests/TimeTests.swift`
— `startOfDay_springForwardDay` and `startOfDay_fallBackDay`.

---

## 2. `update` audit row is gated on a real field change

**Where:**
`Packages/MedTrackerData/Sources/MedTrackerData/Repositories/DoseRepository.swift`
— `updateDose` / `computeChanges`, and
`Packages/MedTrackerData/Sources/MedTrackerData/Repositories/MedicationRepository.swift`
— `updateMedicationWithSchedules` / `computeChanges`, vs. web
`src/lib/server/audit.ts:19-28` (`computeChanges`) as consumed by
`doses.ts`/`medications.ts` update paths.

**What diverges:** The web's `computeChanges` loops `Object.keys(after)`, and
every update `.set(...)` includes a freshly-bumped `updatedAt: new Date()`.
`updatedAt` therefore _always_ differs from the before-value, so the web's
`computeChanges` is never `null` on a successful update and an `update` audit
row is written on **every** update — even a no-op edit that changed nothing a
user can see. The Swift `computeChanges` deliberately diffs only the
user-facing fields and **excludes `updatedAt`**, which produces three concrete
differences:

- **(i) No audit row on a no-op edit.** Re-saving a medication/dose with
  identical field values writes no `update` row on the Mac side, one on the web
  side.
- **(ii) The diff omits the `updatedAt` delta.** Even when a real field
  changed, the Swift diff object has no `updatedAt` key; the web's always does.
- **(iii) Diff timestamp values are epoch `Double`s, not ISO strings.** Where a
  changed field _is_ itself a timestamp (e.g. `takenAt`), the Swift diff records
  the epoch-seconds `Double` this schema stores; the web records the column's
  ISO-8601 string.

**Impact:** The Mac app produces leaner and differently-shaped audit rows.
Purely local, this is invisible; it only becomes observable at the Phase-1b
synced-ledger boundary, where Mac-originated audit rows will not line up
row-for-row (or key-for-key) with web-originated ones.

**Decision:** Keep the Swift behavior — it is forward-correct. The web itself
plans to stop auditing no-op edits (an `updatedAt`-only diff is noise), so
matching the web's always-write behavior would mean porting a known wart.
Reconciliation of the two audit-row shapes is a Phase-1b sync concern, tracked
there rather than papered over here. See the reworded `computeChanges` doc
comments in both repositories.

**Tested by:**
`Packages/MedTrackerData/Tests/MedTrackerDataTests/RepositoryTests.swift` —
`updateDose_noActualChanges_writesNoAuditRow`,
`updateDose_takenStatus_quantityUnchanged_recordsNoInventoryEventButAuditsOtherChanges`,
and `updateMedicationWithSchedules_replacesScheduleSetAndAuditsOnlyIfChanged`.

---

## 3. Archive / unarchive guard existence and record the real prior state

**Where:**
`Packages/MedTrackerData/Sources/MedTrackerData/Repositories/MedicationRepository.swift`
— `archiveMedication` / `unarchiveMedication` (via `setArchived`), vs. web
`src/lib/server/medications.ts:276-294`.

**What diverges:** The web issues an unconditional blind `UPDATE ... WHERE id
AND userId` followed by an always-written `logAudit(...)`, even when no row
matched (non-existent or non-owned id) — a phantom audit row for a write that
touched nothing. It also **hardcodes** the audit `from` value (`false` for
archive, `true` for unarchive) rather than reading the row's actual prior
`isArchived`. The Swift version:

- **Guards existence:** `setArchived` fetches the owned medication first and
  returns `false` with no write and no audit row when it doesn't exist.
- **Records the real prior value:** the audit diff's `from` is the row's actual
  `isArchived` before the change, not a hardcoded constant (so archiving an
  already-archived row would honestly record `from: true`).

**Impact:** No phantom audit rows for no-op archive/unarchive calls, and
truthful `isArchived` transitions in the ones that do fire. Same Phase-1b
ledger-shape caveat as entry #2.

**Decision:** Keep the Swift (stricter, more honest) behavior.

**Tested by:**
`Packages/MedTrackerData/Tests/MedTrackerDataTests/RepositoryTests.swift` —
`archiveMedication_returnsFalseWhenMedicationDoesNotExist`,
`archiveMedication_setsFlagsAndWritesAuditRow`,
`unarchiveMedication_clearsFlagsAndWritesAuditRow`.

---

## 4. `fixed_time` wall-clock → UTC on DST-transition days

**Where:** `Packages/MedTrackerCore/Sources/MedTrackerCore/Time.swift` —
`wallClockToUTC`, as used by `Schedule.swift`'s `expectedTimesForFixedTime`
and `Reminders.swift`'s `fixedTimeOverdueSlot`, vs. web
`localTimeOnDateToUtc` (`src/lib/utils/schedule.ts:74-101`). Parallel to
entry #1, but for resolving a fixed wall-clock time on a date (rather than
local midnight).

**What diverges:** Foundation's `Calendar.date(from:)` resolves a `fixed_time`
wall-clock (`year-month-day hh:mm` in the user's zone) correctly across DST
transitions. The web's `localTimeOnDateToUtc` samples a single UTC offset and
subtracts it, which is off by one hour for local times that fall just after a
transition:

- **Spring-forward day** (e.g. `America/New_York` 2026-03-08): local
  `03:00–06:59` → the web result is **+1h** vs. the correct instant.
- **Fall-back day** (e.g. `America/New_York` 2026-11-01): local `02:00–05:59`
  → the web result is **−1h** vs. the correct instant.

Confirmed for `America/New_York`, 2026:

| Local time (that day)  | Foundation `wallClockToUTC` (correct) | Web `localTimeOnDateToUtc` (buggy) |
| ---------------------- | ------------------------------------- | ---------------------------------- |
| 2026-03-08 06:00 (EDT) | `2026-03-08T10:00:00Z`                | `2026-03-08T11:00:00Z` (+1h)       |
| 2026-11-01 05:30 (EST) | `2026-11-01T10:30:00Z`                | `2026-11-01T09:30:00Z` (−1h)       |

**Impact:** A `fixed_time` schedule slot (and any overdue-reminder slot derived
from it) whose configured time lands in one of those two narrow local bands
resolves to a different UTC instant on the Mac app than on the web — but only
on the two transition days each year, and only for times in those bands. Every
other time and day resolves identically on both sides.

**Decision:** Keep Foundation's correct behavior. As with entry #1, do not
reproduce the web's offset-subtraction bug; it should be fixed on the web side
separately (out of scope for this port).

**Tested by:**
`Packages/MedTrackerCore/Tests/MedTrackerCoreTests/ScheduleTests.swift` —
`dstFixedTime_0600_springForward_inBand_divergesFromWeb` and
`dstFixedTime_0530_fallBack_inBand_divergesFromWeb` (plus the existing
gap/ambiguous-hour `dstFixedTime_*` slot cases, which happen to land outside
the divergent bands and so agree byte-for-byte with the web).

---

Future divergences discovered while porting later tasks get appended here as
new numbered entries, following the same shape (where / what diverges /
impact / decision / tested-by).
