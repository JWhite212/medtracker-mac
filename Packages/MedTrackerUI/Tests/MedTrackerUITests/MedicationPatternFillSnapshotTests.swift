import MedTrackerCore
@testable import MedTrackerUI
import SwiftUI
import XCTest

final class MedicationPatternFillSnapshotTests: XCTestCase {
    private let primary = "#6366f1"
    private let secondary = "#f59e0b"

    @MainActor
    func testAllEightPatternsAtSwatchSize() {
        for pattern in MedicationPattern.allCases {
            let fill = MedicationPatternFill(colour: primary, colourSecondary: secondary, pattern: pattern)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.swatch))
            assertViewSnapshot(fill, size: CGSize(width: 64, height: 64), named: pattern.rawValue)
        }
    }

    @MainActor
    func testSubTwentyPointDegradesToGradient() {
        // A checkerboard rendered below the 20pt threshold must fall back to a
        // 2-stop gradient (no geometric detail that would alias at swatch scale).
        let tiny = MedicationPatternFill(colour: primary, colourSecondary: secondary, pattern: .checkerboard)
            .frame(width: 14, height: 14)
        assertViewSnapshot(tiny, size: CGSize(width: 14, height: 14), named: "checkerboard-degraded")
    }

    @MainActor
    func testSolidPatternIgnoresSecondaryColour() {
        // renderedColours drops secondary for .solid → single-colour fill.
        let fill = MedicationPatternFill(colour: primary, colourSecondary: secondary, pattern: .solid)
        assertViewSnapshot(fill, size: CGSize(width: 64, height: 64), named: "solid-secondary-ignored")
    }
}
