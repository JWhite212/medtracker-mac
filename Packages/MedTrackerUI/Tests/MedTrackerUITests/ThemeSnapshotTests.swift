@testable import MedTrackerUI
import SwiftUI
import XCTest

final class ThemeSnapshotTests: XCTestCase {
    @MainActor
    func testTokenSwatches() {
        let swatches = VStack(spacing: Theme.Spacing.sm) {
            ForEach(Array([
                Theme.surface, Theme.raised, Theme.textPrimary, Theme.textSecondary,
                Theme.success, Theme.warning, Theme.danger, Theme.accent,
            ].enumerated()), id: \.offset) { _, colour in
                RoundedRectangle(cornerRadius: Theme.Radius.pill)
                    .fill(colour)
                    .frame(height: 22)
            }
        }
        .padding(Theme.Spacing.md)
        assertViewSnapshot(swatches, size: CGSize(width: 200, height: 260))
    }
}
