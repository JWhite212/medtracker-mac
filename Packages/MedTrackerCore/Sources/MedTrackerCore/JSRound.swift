import Foundation

/// Replicates JavaScript `Math.round` semantics: rounds half **up**, toward
/// `+∞`. This differs from Swift's built-in `Double.rounded()`, which uses
/// `.toNearestOrAwayFromZero` and so disagrees for negative half-values:
///
/// | x     | `Math.round` (JS) | `x.rounded()` (Swift) | `jsRound(x)` |
/// |-------|-------------------|-----------------------|--------------|
/// | 2.5   | 3                 | 3                     | 3            |
/// | 2.4   | 2                 | 2                     | 2            |
/// | -0.5  | 0                 | -1                    | 0            |
/// | -2.5  | -2                | -3                    | -2           |
///
/// Most call sites here feed non-negative values, but trend deltas can be
/// negative — so anywhere the TS uses `Math.round`, use `jsRound` to keep
/// byte-for-byte parity. Implemented as `floor(x + 0.5)`, which matches JS
/// `Math.round` for all realistic inputs (integer/percent deltas); it differs
/// only at the `0.49999999999999994` floating-point corner the ECMAScript
/// spec calls out (JS rounds that to `0`, `floor(x + 0.5)` rounds it to `1`
/// because `x + 0.5` rounds up to `1.0` before flooring) — a value that
/// cannot arise from real call sites here.
public func jsRound(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}

// MARK: - JS-style number-to-string

/// Renders a `Double` the way a JS template literal (`${x}`) would: whole
/// values print with no trailing `.0` (`40` not `40.0`), matching
/// `Number.prototype.toString()`. Non-whole values fall through to Swift's
/// own `Double` description, which — like JS's `Number::toString` — is a
/// shortest-round-trip decimal representation, so for any double value
/// produced by identical IEEE 754 arithmetic the two already agree digit for
/// digit (e.g. `0.1 + 0.2` prints `0.30000000000000004` in both).
///
/// Shared by `Insights.swift` (adherence percentages, trend deltas — used
/// as-is with no additional rounding, to keep any floating-point artifact in
/// exact parity with the TS source) and `Sparkline.swift` (path coordinates,
/// always pre-rounded via `round1` before reaching here). Was previously
/// duplicated file-scoped-`private` in both files; consolidated since the
/// two implementations were byte-for-byte identical.
func jsNumberString(_ x: Double) -> String {
    if x.isFinite, x == x.rounded() {
        return String(Int(x))
    }
    return String(x)
}
