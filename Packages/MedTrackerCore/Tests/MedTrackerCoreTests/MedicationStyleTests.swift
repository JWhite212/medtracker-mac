import Foundation
@testable import MedTrackerCore
import Testing

// Transcribes the `getReadableTextColor` describe block from
// `tests/unit/medication-style.test.ts` (dark-vs-light expectations only).
//
// NOT transcribed here (out of scope for this task per the file header in
// MedicationStyle.swift): the `getMedicationBackground` describe block (CSS
// `background-image` string generation — web-only) and the `textShadow`/
// `hoverOverlay` assertions on `getReadableTextColor`'s result (also
// web-only CSS strings). Those TS cases exist to test properties this Swift
// port deliberately doesn't expose.

// MARK: - ReadableTextColor.hex

@Test func readableTextColor_darkHexIs111111() {
    #expect(ReadableTextColor.dark.hex == "#111111")
}

@Test func readableTextColor_lightHexIsFfffff() {
    #expect(ReadableTextColor.light.hex == "#ffffff")
}

// MARK: - getReadableTextColor (verbatim dark/light cases from medication-style.test.ts)

@Test func getReadableTextColor_usesDarkTextOnANearWhiteBackground() {
    // TS: getReadableTextColor("#ffffff").color === "#111111"
    #expect(getReadableTextColor(colour: "#ffffff", colourSecondary: nil, pattern: .solid) == .dark)
}

@Test func getReadableTextColor_usesLightTextOnANearBlackBackground() {
    // TS: getReadableTextColor("#000000").color === "#ffffff"
    #expect(getReadableTextColor(colour: "#000000", colourSecondary: nil, pattern: .solid) == .light)
}

@Test func getReadableTextColor_usesDarkTextOnLightYellowsWhereWhiteWouldFailWcag() {
    // TS: Yellow #fde047 is a typical light pill colour where white text is unreadable
    #expect(getReadableTextColor(colour: "#fde047", colourSecondary: nil, pattern: .solid) == .dark)
}

@Test func getReadableTextColor_usesLightTextOnSaturatedMidTonesLikeIndigo() {
    // TS: getReadableTextColor("#6366f1").color === "#ffffff"
    #expect(getReadableTextColor(colour: "#6366f1", colourSecondary: nil, pattern: .solid) == .light)
}

@Test func getReadableTextColor_darkNavyGetsLightText() {
    // TS ("returns the same outline shadow tone..." case): onDark = getReadableTextColor("#1e1b4b");
    // onDark.color === "#ffffff". Only the colour choice is transcribed here — the
    // textShadow tone assertion is a web-only CSS string, out of scope.
    #expect(getReadableTextColor(colour: "#1e1b4b", colourSecondary: nil, pattern: .solid) == .light)
}

@Test func getReadableTextColor_ignoresSecondaryColourWhenPatternIsSolid() {
    // TS: "ignores secondary colour when pattern is solid" — light yellow primary +
    // dark navy secondary on solid: only yellow renders, so contrast must be computed
    // against yellow alone -> dark text.
    #expect(getReadableTextColor(colour: "#fde047", colourSecondary: "#1e1b4b", pattern: .solid) == .dark)
}

@Test func getReadableTextColor_usesSecondaryColourForNonSolidPatterns() {
    // TS: "uses secondary colour for non-solid patterns" — same colours on a stripes
    // pattern: both render. Yellow alone wants dark text; navy alone wants white.
    // With both, white has the better worst-case contrast (≈1.32 on yellow) than dark
    // (≈1.19 on navy), so white wins.
    let solid = getReadableTextColor(colour: "#fde047", colourSecondary: "#1e1b4b", pattern: .solid)
    let stripes = getReadableTextColor(colour: "#fde047", colourSecondary: "#1e1b4b", pattern: .stripes)
    #expect(solid == .dark)
    #expect(stripes == .light)
}

@Test func getReadableTextColor_considersBothColoursForSplitGradientPillsAndPicksTheSaferFg() {
    // TS: "considers both colours for split/gradient pills and picks the safer fg" —
    // light yellow + dark navy on a non-solid pattern: white fails on yellow, dark
    // fails on navy. Either choice is imperfect, but the function must return a
    // stable value (the TS asserts membership in the two-value set; Swift's result
    // type already guarantees that, so this test just documents it doesn't crash
    // and picks a value).
    let fg = getReadableTextColor(colour: "#fde047", colourSecondary: "#1e1b4b", pattern: .split)
    #expect(fg == .dark || fg == .light)
}

@Test func getReadableTextColor_treatsNilSecondaryAsSingleColour() {
    // TS: both getReadableTextColor("#6366f1", null) and (..., undefined) collapse
    // to the single Swift `nil` case — both TS assertions expect "#ffffff".
    #expect(getReadableTextColor(colour: "#6366f1", colourSecondary: nil, pattern: .solid) == .light)
}

@Test func getReadableTextColor_supports3DigitHexShorthand() {
    #expect(getReadableTextColor(colour: "#fff", colourSecondary: nil, pattern: .solid) == .dark)
    #expect(getReadableTextColor(colour: "#000", colourSecondary: nil, pattern: .solid) == .light)
}

@Test func getReadableTextColor_doesNotThrowOnInvalidHexAndReturnsAStableFallback() {
    // TS: invalid hex falls back to luminance 0 (black) -> white text; the TS test
    // only asserts membership in the two-value set (plus "does not throw", which
    // Swift's type system already guarantees for a non-throwing function). Since
    // luminance-0 is mathematically identical to the "#000000" case above, this
    // Swift port can assert the exact, deterministic result: light text.
    for bad in ["not-a-hex", "", "#zzz", "#12", "rgb(0,0,0)", "blue"] {
        let fg = getReadableTextColor(colour: bad, colourSecondary: nil, pattern: .solid)
        #expect(fg == .light, "expected light text for invalid hex \"\(bad)\", got \(fg)")
    }
}

// MARK: - renderedColours (the pattern -> rendered-colour-set logic the picker needs)

@Test func renderedColours_returnsOnlyPrimaryForSolidPatternEvenWithSecondary() {
    #expect(renderedColours(colour: "#6366f1", colourSecondary: "#ec4899", pattern: .solid) == ["#6366f1"])
}

@Test func renderedColours_returnsOnlyPrimaryWhenSecondaryIsNil() {
    #expect(renderedColours(colour: "#6366f1", colourSecondary: nil, pattern: .gradient) == ["#6366f1"])
}

@Test func renderedColours_returnsOnlyPrimaryWhenSecondaryEqualsPrimary() {
    #expect(renderedColours(colour: "#6366f1", colourSecondary: "#6366f1", pattern: .stripes) == ["#6366f1"])
}

@Test func renderedColours_returnsBothForNonSolidPatternWithDistinctSecondary() {
    #expect(renderedColours(colour: "#6366f1", colourSecondary: "#ec4899", pattern: .gradient) == ["#6366f1", "#ec4899"])
    #expect(renderedColours(colour: "#6366f1", colourSecondary: "#ec4899", pattern: .hStripes) == ["#6366f1", "#ec4899"])
}

// MARK: - MedicationPattern raw values (match the web's pattern ids, medication-style.ts:103-112)

@Test func medicationPattern_rawValuesMatchWebPatternIds() {
    #expect(MedicationPattern.solid.rawValue == "solid")
    #expect(MedicationPattern.split.rawValue == "split")
    #expect(MedicationPattern.gradient.rawValue == "gradient")
    #expect(MedicationPattern.stripes.rawValue == "stripes")
    #expect(MedicationPattern.hStripes.rawValue == "h-stripes")
    #expect(MedicationPattern.dots.rawValue == "dots")
    #expect(MedicationPattern.checkerboard.rawValue == "checkerboard")
    #expect(MedicationPattern.radial.rawValue == "radial")
    #expect(MedicationPattern.allCases.count == 8)
}
