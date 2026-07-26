import Foundation

// Ports `buildInsights` and its `InsightInputs`/`Insight` types from
// `src/lib/server/analytics.ts:428-543`. This is the deterministic insights
// engine surfaced on the Analytics page (`InsightsCard.svelte`) — the whole
// point of this port is EXACT-STRING parity with the web app, including
// punctuation (the period after "vs" in "vs. previous period") and the em
// dash (U+2014, not a hyphen) in the side-effects string.
//
// `InsightInputs` mirrors the TS type's full shape, including `totalDoses`
// and `prevTotalDoses` — present on the TS type but never read inside
// `buildInsights` itself (dead fields on the source type). Kept here anyway
// for faithful shape parity with callers that may rely on the complete
// struct.

// MARK: - Severity

/// Mirrors the TS `Insight["severity"]` union (`"info" | "positive" |
/// "warning"`, re-exported from `$lib/types`). Case order here follows the
/// TS union's declaration order; the *sort* order used by `buildInsights`
/// (warning, then positive, then info) is independent of this declaration
/// order and implemented separately via `severityRank`.
public enum InsightSeverity: Equatable {
    case info
    case positive
    case warning
}

/// Sort rank used by `buildInsights`' final ordering (`analytics.ts:541`:
/// `{ warning: 0, positive: 1, info: 2 }`).
private func severityRank(_ severity: InsightSeverity) -> Int {
    switch severity {
    case .warning: return 0
    case .positive: return 1
    case .info: return 2
    }
}

// MARK: - Insight

/// Ports the TS `Insight` interface (`$lib/types`). `id`s are stable and
/// exact — they drive UI diffing/accessibility in the web app and must be
/// preserved verbatim for any future shared behaviour.
public struct Insight: Equatable {
    public let id: String
    public let severity: InsightSeverity
    public let text: String

    public init(id: String, severity: InsightSeverity, text: String) {
        self.id = id
        self.severity = severity
        self.text = text
    }
}

// MARK: - Inputs

/// One medication's adherence stat, as consumed by the highest/lowest-
/// adherence rules. Ports the TS `medStats` array element
/// (`analytics.ts:433`).
public struct MedAdherenceStat: Equatable {
    public let medicationName: String
    public let adherence: Double
    public let expectedTotal: Int

    public init(medicationName: String, adherence: Double, expectedTotal: Int) {
        self.medicationName = medicationName
        self.adherence = adherence
        self.expectedTotal = expectedTotal
    }
}

/// One day-of-week's dose count. Ports the TS `dayOfWeek` array element
/// (`analytics.ts:434`). `dayOfWeek` is a Postgres `dow` index: `0` = Sunday
/// … `6` = Saturday.
public struct DayOfWeekCount: Equatable {
    public let dayOfWeek: Int
    public let count: Int

    public init(dayOfWeek: Int, count: Int) {
        self.dayOfWeek = dayOfWeek
        self.count = count
    }
}

/// One hour-of-day's dose count. Ports the TS `hourly` array element
/// (`analytics.ts:435`). `hour` is 0-23.
public struct HourCount: Equatable {
    public let hour: Int
    public let count: Int

    public init(hour: Int, count: Int) {
        self.hour = hour
        self.count = count
    }
}

/// Ports the TS `InsightInputs` type (`analytics.ts:428-440`) — the
/// already-computed stats each `buildInsights` rule reads. All fields
/// default to the TS test suite's `baseInputs` fixture's empty/zero values,
/// so callers only need to specify what a given scenario varies.
public struct InsightInputs {
    public let totalDoses: Int
    public let prevTotalDoses: Int
    public let avgAdherence: Double
    public let prevAvgAdherence: Double
    public let medStats: [MedAdherenceStat]
    public let dayOfWeek: [DayOfWeekCount]
    public let hourly: [HourCount]
    public let sideEffectsCount: Int
    public let topSideEffect: String?
    public let refillCriticalCount: Int
    public let streak: Int

    public init(
        totalDoses: Int = 0,
        prevTotalDoses: Int = 0,
        avgAdherence: Double = 0,
        prevAvgAdherence: Double = 0,
        medStats: [MedAdherenceStat] = [],
        dayOfWeek: [DayOfWeekCount] = [],
        hourly: [HourCount] = [],
        sideEffectsCount: Int = 0,
        topSideEffect: String? = nil,
        refillCriticalCount: Int = 0,
        streak: Int = 0
    ) {
        self.totalDoses = totalDoses
        self.prevTotalDoses = prevTotalDoses
        self.avgAdherence = avgAdherence
        self.prevAvgAdherence = prevAvgAdherence
        self.medStats = medStats
        self.dayOfWeek = dayOfWeek
        self.hourly = hourly
        self.sideEffectsCount = sideEffectsCount
        self.topSideEffect = topSideEffect
        self.refillCriticalCount = refillCriticalCount
        self.streak = streak
    }
}

// MARK: - Day labels

/// Full English weekday names indexed by Postgres `dow` (`0` = Sunday …
/// `6` = Saturday). Ports the TS `DAY_LABEL_FULL` constant
/// (`analytics.ts:442-450`).
private let dayLabelFull: [String] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
]

// MARK: - JS-style number-to-string

/// Renders a `Double` the way a JS template literal (`${x}`) would: whole
/// values print with no trailing `.0` (`15` not `15.0`), matching
/// `Number.prototype.toString()`. Non-whole values fall through to Swift's
/// own `Double` description, which — like JS's `Number::toString` — is a
/// shortest-round-trip decimal representation, so for any double value
/// produced by identical IEEE 754 arithmetic the two already agree digit for
/// digit (e.g. `0.1 + 0.2` prints `0.30000000000000004` in both). Adherence
/// percentages and trend deltas are the only two call sites here that need
/// this — the TS source interpolates them with no additional rounding, so
/// this deliberately does not round either, to keep any floating-point
/// artifact in exact parity with the source.
private func jsNumberString(_ x: Double) -> String {
    if x.isFinite, x == x.rounded() {
        return String(Int(x))
    }
    return String(x)
}

// MARK: - buildInsights

/// Ports `buildInsights` (`analytics.ts:452-543`). Runs each rule in source
/// order, then sorts the emitted insights by severity (`warning` first,
/// then `positive`, then `info` — a stable sort, matching JS's
/// guaranteed-stable `Array.prototype.sort`), truncated to the first 5.
public func buildInsights(_ input: InsightInputs) -> [Insight] {
    var out: [Insight] = []

    // Adherence trend: needs 2+ meds with data and a real previous-period
    // baseline, and a delta of at least 5 percentage points either way.
    if input.medStats.count >= 2, input.prevAvgAdherence > 0 {
        let delta = input.avgAdherence - input.prevAvgAdherence
        if abs(delta) >= 5 {
            out.append(
                Insight(
                    id: "adherence-trend",
                    severity: delta > 0 ? .positive : .warning,
                    text: "Adherence \(delta > 0 ? "improved" : "declined") \(jsNumberString(abs(delta)))% vs. previous period"
                )
            )
        }
    }

    // Highest / lowest adherence: needs 2+ meds with expectedTotal > 0.
    // Lowest only fires when the bottom med is below 80%.
    if input.medStats.count >= 2 {
        let sorted = input.medStats
            .filter { $0.expectedTotal > 0 }
            .sorted { $0.adherence > $1.adherence }
        if sorted.count >= 2 {
            let top = sorted[0]
            out.append(
                Insight(
                    id: "highest-adherence-med",
                    severity: .positive,
                    text: "Highest adherence: \(top.medicationName) (\(jsNumberString(top.adherence))%)"
                )
            )
            let bottom = sorted[sorted.count - 1]
            if bottom.adherence < 80 {
                out.append(
                    Insight(
                        id: "lowest-adherence-med",
                        severity: .warning,
                        text: "Lowest adherence: \(bottom.medicationName) (\(jsNumberString(bottom.adherence))%)"
                    )
                )
            }
        }
    }

    // Worst day-of-week: needs a full week's worth of data (>= 7 total
    // doses across the 7 dow buckets) and a day notably below the mean.
    let totalDow = input.dayOfWeek.reduce(0) { $0 + $1.count }
    if totalDow >= 7 {
        let avg = Double(totalDow) / 7
        let worst = input.dayOfWeek.sorted { $0.count < $1.count }.first
        if let worst, Double(worst.count) < avg * 0.7, worst.count >= 0 {
            out.append(
                Insight(
                    id: "worst-day",
                    severity: .info,
                    text: "Fewest doses on \(dayLabelFull[worst.dayOfWeek])"
                )
            )
        }
    }

    // Peak dosing hour: needs at least 5 total hourly-bucketed doses and a
    // single hour holding at least 30% of them.
    let totalHour = input.hourly.reduce(0) { $0 + $1.count }
    if totalHour >= 5 {
        let peak = input.hourly.sorted { $0.count > $1.count }.first
        if let peak, Double(peak.count) >= Double(totalHour) * 0.3 {
            let hh = String(format: "%02d", peak.hour)
            out.append(
                Insight(
                    id: "peak-hour",
                    severity: .info,
                    text: "Most consistent dosing time is \(hh):00"
                )
            )
        }
    }

    // Refill warning: fires whenever at least one medication is critical.
    // Singular/plural wording transcribed verbatim from the source.
    if input.refillCriticalCount > 0 {
        let text = input.refillCriticalCount == 1
            ? "1 medication needs a refill within 7 days"
            : "\(input.refillCriticalCount) medications need a refill within 7 days"
        out.append(Insight(id: "refill-warning", severity: .warning, text: text))
    }

    // Side effects: needs 3+ logged occurrences and a most-common name.
    // NOTE the em dash (U+2014) below, not a hyphen — exact parity with the
    // source string.
    if input.sideEffectsCount >= 3, let topSideEffect = input.topSideEffect {
        out.append(
            Insight(
                id: "side-effects",
                severity: .info,
                text: "\(input.sideEffectsCount) side effects logged — most common: \(topSideEffect)"
            )
        )
    }

    // Streak: needs 3+ consecutive days.
    if input.streak >= 3 {
        out.append(
            Insight(
                id: "streak",
                severity: .positive,
                text: "Current streak: \(input.streak) days"
            )
        )
    }

    let sorted = out.sorted { severityRank($0.severity) < severityRank($1.severity) }
    return Array(sorted.prefix(5))
}
