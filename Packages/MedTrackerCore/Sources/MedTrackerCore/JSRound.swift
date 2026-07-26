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
/// byte-for-byte parity. Implemented as `floor(x + 0.5)`, exactly matching
/// the JS spec's definition.
public func jsRound(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}
