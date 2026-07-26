import Foundation

// Ports the WCAG readable-text-colour picker from
// `src/lib/utils/medication-style.ts` (`relativeLuminance`, `contrastRatio`,
// `getReadableTextColor`, lines 1-67), plus the pattern -> rendered-colour-set
// logic the picker depends on (mirrored from `getMedicationBackground`'s
// "secondary only renders on non-solid patterns" rule, lines 69-101).
//
// Deliberately NOT ported here: the CSS `background-image` string generation
// in `getMedicationBackground` (linear/radial/conic gradients, stripe/dot/
// checkerboard geometry) and the `textShadow`/`hoverOverlay` CSS strings from
// `getReadableTextColor`'s return value. Those are web-rendering concerns;
// SwiftUI's own per-pattern fills arrive in Phase 1c. Only the colour math
// (luminance, contrast, dark-vs-light decision) and the pure colour-set
// description each pattern renders — the two things the contrast picker
// itself needs — are in scope for this task.

// MARK: - Pattern

/// Mirrors the TS `PATTERN_OPTIONS` ids (`medication-style.ts:103-112`).
/// Raw values match the web's pattern ids exactly (used as the wire/storage
/// format, and later as SwiftUI fill selectors in Phase 1c).
public enum MedicationPattern: String, Equatable, Hashable, CaseIterable, Sendable {
    case solid
    case split
    case gradient
    case stripes
    case hStripes = "h-stripes"
    case dots
    case checkerboard
    case radial
}

// MARK: - Readable text colour

/// The two candidate foreground colours the picker chooses between. Mirrors
/// `READABLE_DARK` / `READABLE_LIGHT` (`medication-style.ts:29-30`).
public enum ReadableTextColor: Equatable, Hashable, Sendable {
    case dark
    case light

    /// The hex string the web app uses for this candidate.
    public var hex: String {
        switch self {
        case .dark: return "#111111"
        case .light: return "#ffffff"
        }
    }
}

// MARK: - Rendered colour set

/// The colours actually rendered on-screen for a medication pill, given its
/// pattern. Ports the "secondary is ignored unless the pattern uses it" rule
/// applied by `getMedicationBackground` (`medication-style.ts:69-101`) — a
/// saved-but-unused secondary colour (e.g. a solid-pattern medication that
/// still has a `colourSecondary` on file from a prior pattern choice) never
/// contributes to the rendered colour set, so it must never skew the
/// contrast decision either.
///
/// Secondary renders only when the pattern is not `.solid` AND a secondary
/// colour is present AND it differs from the primary colour.
public func renderedColours(
    colour: String,
    colourSecondary: String?,
    pattern: MedicationPattern
) -> [String] {
    guard pattern != .solid, let secondary = colourSecondary, secondary != colour else {
        return [colour]
    }
    return [colour, secondary]
}

// MARK: - sRGB relative luminance

private func isASCIIHexDigit(_ c: Character) -> Bool {
    guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else { return false }
    switch scalar.value {
    case 0x30 ... 0x39, 0x41 ... 0x46, 0x61 ... 0x66: // 0-9, A-F, a-f
        return true
    default:
        return false
    }
}

/// Parses a `#rgb` or `#rrggbb` hex colour (case-insensitive), matching the
/// TS `HEX_RE` (`medication-style.ts:3`). Returns `nil` for anything else —
/// callers treat that as luminance 0, exactly like the TS's defensive
/// fallback (`medication-style.ts:6-11`).
private func parseHexRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
    guard hex.hasPrefix("#") else { return nil }
    let body = Array(hex.dropFirst())
    guard body.count == 3 || body.count == 6 else { return nil }
    guard body.allSatisfy(isASCIIHexDigit) else { return nil }

    let expanded: [Character] = body.count == 3
        ? body.flatMap { [$0, $0] }
        : body

    func componentValue(_ chars: ArraySlice<Character>) -> Double? {
        guard let byte = UInt8(String(chars), radix: 16) else { return nil }
        return Double(byte)
    }

    guard let r = componentValue(expanded[0 ..< 2]),
          let g = componentValue(expanded[2 ..< 4]),
          let b = componentValue(expanded[4 ..< 6])
    else { return nil }

    return (r, g, b)
}

/// WCAG relative luminance of a hex colour. Ports `relativeLuminance`
/// (`medication-style.ts:5-22`). Invalid hex → `0` (parsed defensively,
/// exactly like the TS fallback — no `console.warn`-equivalent here since
/// this is a pure Swift function with no dev-only logging path).
private func relativeLuminance(_ hex: String) -> Double {
    guard let rgb = parseHexRGB(hex) else { return 0 }
    func linearize(_ component: Double) -> Double {
        let s = component / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    let r = linearize(rgb.r)
    let g = linearize(rgb.g)
    let b = linearize(rgb.b)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// WCAG contrast ratio between two relative luminances. Ports
/// `contrastRatio` (`medication-style.ts:24-27`).
private func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
    let hi = max(l1, l2)
    let lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}

private let lightLuminance: Double = 1 // relativeLuminance("#ffffff"), computed once (medication-style.ts:32)
private let darkLuminance: Double = relativeLuminance("#111111") // medication-style.ts:31

/// Picks a foreground colour with the best worst-case contrast against the
/// colours actually rendered for the given pattern. Ports
/// `getReadableTextColor` (`medication-style.ts:45-67`), minus the
/// `textShadow`/`hoverOverlay` CSS strings (web-rendering concerns, out of
/// scope here — see file header).
///
/// For each candidate (`.dark`, `.light`), takes its minimum (worst-case)
/// contrast ratio across every rendered colour, then picks the candidate
/// with the greater worst-case ratio. Ties favour `.dark`, matching the TS's
/// `darkMin >= whiteMin` comparison.
public func getReadableTextColor(
    colour: String,
    colourSecondary: String?,
    pattern: MedicationPattern
) -> ReadableTextColor {
    let colours = renderedColours(colour: colour, colourSecondary: colourSecondary, pattern: pattern)
    let lums = colours.map(relativeLuminance)

    let whiteMin = lums.map { contrastRatio(lightLuminance, $0) }.min() ?? 0
    let darkMin = lums.map { contrastRatio(darkLuminance, $0) }.min() ?? 0

    return darkMin >= whiteMin ? .dark : .light
}
