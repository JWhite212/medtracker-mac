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

Future divergences discovered while porting later tasks get appended here as
new numbered entries, following the same shape (where / what diverges /
impact / decision / tested-by).
