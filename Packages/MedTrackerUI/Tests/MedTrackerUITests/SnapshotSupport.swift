import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import MedTrackerUI

/// Deterministic dark-only host wrapper for every MedTrackerUI snapshot (§7.2):
/// forced `.darkAqua` appearance + `\.colorScheme == .dark`, a fixed pixel frame,
/// and an explicit Dynamic Type size. Recording is env-driven
/// (`SNAPSHOT_TESTING_RECORD=all` records/overwrites references).
@MainActor
func assertViewSnapshot(
    _ view: some View,
    size: CGSize,
    dynamicType: DynamicTypeSize = .large,
    named name: String? = nil,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
) {
    let root = view
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(dynamicType)
        .frame(width: size.width, height: size.height)
        .background(Theme.surface)

    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()

    assertSnapshot(
        of: host,
        as: .image(precision: 0.98, perceptualPrecision: 0.98),
        named: name,
        file: file, testName: testName, line: line
    )
}
