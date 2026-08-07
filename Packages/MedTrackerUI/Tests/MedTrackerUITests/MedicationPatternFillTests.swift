import Foundation
import MedTrackerCore
@testable import MedTrackerUI
import Testing

/// Deterministic assertions for the pattern-fill *semantics* (§6).
///
/// These replace what pixel snapshots were previously the only witness to. Image
/// comparison drifts across toolchain/OS releases (see `SnapshotSupport.swift`),
/// so the load-bearing rules — the `<20pt` degradation threshold and the
/// colour-selection contract — are asserted directly here and hold on any machine.

@Test func degradationThresholdIsTwentyPoints() {
    #expect(MedicationPatternFill.degradationThreshold == 20)
}

@Test func swatchesBelowThresholdDegradeToGradient() {
    #expect(MedicationPatternFill.isDegraded(minDimension: 0))
    #expect(MedicationPatternFill.isDegraded(minDimension: 14))
    #expect(MedicationPatternFill.isDegraded(minDimension: 19.99))
}

@Test func swatchesAtOrAboveThresholdRenderFullPattern() {
    #expect(!MedicationPatternFill.isDegraded(minDimension: 20))
    #expect(!MedicationPatternFill.isDegraded(minDimension: 64))
}

/// The fill defers colour choice to Core, so a saved-but-unused secondary must not
/// reach the renderer for `.solid` (parity with the web contrast picker).
@Test func solidPatternDropsSecondaryColour() {
    let colours = renderedColours(colour: "#6366f1", colourSecondary: "#f59e0b", pattern: .solid)
    #expect(colours == ["#6366f1"])
}

@Test func twoColourPatternsKeepBothColours() {
    for pattern in [MedicationPattern.split, .gradient, .radial] {
        let colours = renderedColours(colour: "#6366f1", colourSecondary: "#f59e0b", pattern: pattern)
        #expect(colours.count == 2, "\(pattern.rawValue) should render two colours")
        #expect(colours.first == "#6366f1")
    }
}

/// Every pattern must produce at least one colour — the fill indexes `colours[0]`
/// unconditionally, so an empty result would trap at render time.
@Test func everyPatternYieldsAtLeastOneColour() {
    for pattern in MedicationPattern.allCases {
        let withSecondary = renderedColours(colour: "#6366f1", colourSecondary: "#f59e0b", pattern: pattern)
        let withoutSecondary = renderedColours(colour: "#6366f1", colourSecondary: nil, pattern: pattern)
        #expect(!withSecondary.isEmpty, "\(pattern.rawValue) returned no colours")
        #expect(!withoutSecondary.isEmpty, "\(pattern.rawValue) returned no colours without a secondary")
    }
}
