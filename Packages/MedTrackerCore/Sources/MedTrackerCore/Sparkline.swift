import Foundation

// Ports `buildSparklineShape` (`src/lib/utils/sparkline.ts:12-47`) — the pure
// inline-SVG path-geometry builder behind `Sparkline.svelte`. No chart
// library on either side: the TS builds an `M`/`L`/`Z` path string by hand,
// and this is a byte-for-byte port of that string construction, including
// the exact JS number-to-string formatting the template literals produce
// (`40` not `40.0`, `0.8` not `0.80000000000000004`).

// MARK: - Shape

/// Ports the TS `SparklineShape` type (`sparkline.ts:1-6`). `line` is the
/// polyline `d` attribute; `area` is `line` plus the closing segment back
/// down to the baseline, used for the filled-area variant. `dotX`/`dotY` are
/// only non-nil for the single-value case, where no line/area is drawn at
/// all — just a centred dot.
public struct SparklineShape: Equatable, Sendable {
    public let line: String
    public let area: String
    public let dotX: Double?
    public let dotY: Double?

    public init(line: String, area: String, dotX: Double?, dotY: Double?) {
        self.line = line
        self.area = area
        self.dotX = dotX
        self.dotY = dotY
    }
}

// MARK: - Rounding

/// Ports the TS local `round` helper (`sparkline.ts:8-10`,
/// `Math.round(n * 10) / 10`) — every coordinate is rounded to 1 decimal
/// place. Built on the shared `jsRound` (`+∞`-rounding `Math.round` port) so
/// negative coordinates round the same way JS would, not the way Swift's
/// `Double.rounded()` would.
private func round1(_ n: Double) -> Double {
    Double(jsRound(n * 10)) / 10
}

// MARK: - buildSparklineShape

/// Ports `buildSparklineShape` (`sparkline.ts:12-47`).
///
/// - `values` empty → empty `line`/`area`, nil dot.
/// - `values.count == 1` → empty `line`/`area`, a single dot centred at
///   `(round(width/2), round(height/2))`.
/// - Otherwise: min/max-normalizes each value to an `(x, y)` point —
///   `x = round(i * width/(n-1))`; `y = round(height − ((v−min)/range) *
///   (height−strokeWidth) − strokeWidth/2)`, or a flat `round(height/2)`
///   midline when every value is equal (`range == 0`) — then joins them into
///   an SVG path (`M x y L x y …`) and appends the closing segment down to
///   the baseline and back to the start x (`L lastX height L firstX height
///   Z`) for the filled-area variant.
public func buildSparklineShape(
    values: [Double],
    width: Double,
    height: Double,
    strokeWidth: Double = 1.5
) -> SparklineShape {
    guard !values.isEmpty else {
        return SparklineShape(line: "", area: "", dotX: nil, dotY: nil)
    }

    let minV = values.min()!
    let maxV = values.max()!
    let range = maxV - minV
    let cy = height / 2

    if values.count == 1 {
        return SparklineShape(line: "", area: "", dotX: round1(width / 2), dotY: round1(cy))
    }

    let stepX = width / Double(values.count - 1)
    let points: [(x: Double, y: Double)] = values.enumerated().map { i, v in
        let x = round1(Double(i) * stepX)
        let y = range == 0
            ? round1(cy)
            : round1(height - ((v - minV) / range) * (height - strokeWidth) - strokeWidth / 2)
        return (x, y)
    }

    let line = points.enumerated()
        .map { i, p in
            let prefix = i == 0 ? "M" : "L"
            return "\(prefix) \(jsNumberString(p.x)) \(jsNumberString(p.y))"
        }
        .joined(separator: " ")

    let first = points[0]
    let last = points[points.count - 1]
    let heightStr = jsNumberString(height)
    let area = "\(line) L \(jsNumberString(last.x)) \(heightStr) L \(jsNumberString(first.x)) \(heightStr) Z"

    return SparklineShape(line: line, area: area, dotX: nil, dotY: nil)
}
