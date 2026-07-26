import SwiftUI
import XCTest
@testable import MedTrackerUI
import MedTrackerCore

final class OutlinedTextSnapshotTests: XCTestCase {
    @MainActor
    func testOutlinedLabelOverPattern() {
        let colour = "#f59e0b"
        let readable = getReadableTextColor(colour: colour, colourSecondary: nil, pattern: .solid)
        let view = ZStack {
            MedicationPatternFill(colour: colour, colourSecondary: nil, pattern: .stripes)
            OutlinedText.forContrast("Ibuprofen", textColor: readable)
        }
        assertViewSnapshot(view, size: CGSize(width: 160, height: 44))
    }
}
