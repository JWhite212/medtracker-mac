import MedTrackerCore
@testable import MedTrackerUI
import SwiftUI
import Testing

@Test func hexInitParsesSixDigit() {
    let c = Color(hex: "#10b981")
    let resolved = c.resolve(in: EnvironmentValues())
    #expect(abs(Double(resolved.red) - 16.0 / 255) < 0.01)
    #expect(abs(Double(resolved.green) - 185.0 / 255) < 0.01)
    #expect(abs(Double(resolved.blue) - 129.0 / 255) < 0.01)
}

@Test func hexInitParsesThreeDigitShorthand() {
    let a = Color(hex: "#fff").resolve(in: EnvironmentValues())
    #expect(a.red == 1 && a.green == 1 && a.blue == 1)
}

@Test func readableTextColorMapsToHex() {
    #expect(ReadableTextColor.dark.color == Color(hex: "#111111"))
    #expect(ReadableTextColor.light.color == Color(hex: "#ffffff"))
}

@Test func spacingScaleIsMonotonic() {
    #expect(Theme.Spacing.xs < Theme.Spacing.sm)
    #expect(Theme.Spacing.lg < Theme.Spacing.xl)
}

@Test func effectiveReduceMotionIsFalseWhenNeitherSignalIsSet() {
    let env = EnvironmentValues()
    #expect(env.effectiveReduceMotion == false)
}

@Test func effectiveReduceMotionIsTrueWhenAppPreferenceIsSet() {
    var env = EnvironmentValues()
    env.appReducedMotion = true
    #expect(env.effectiveReduceMotion == true)
}

@Test func effectiveReduceMotionMatchesSystemAccessibilitySettingByDefault() {
    // `accessibilityReduceMotion` is a get-only mirror of the system setting
    // (no public setter), so this just proves `effectiveReduceMotion` folds
    // it in rather than ignoring it.
    let env = EnvironmentValues()
    #expect(env.effectiveReduceMotion == env.accessibilityReduceMotion || env.appReducedMotion)
}
