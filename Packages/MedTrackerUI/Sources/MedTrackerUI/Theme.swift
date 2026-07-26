import SwiftUI
import MedTrackerCore

/// Dark-only design tokens (master §10.2, spec §6). Fixed sRGB hex; the App
/// target's Assets.xcassets mirrors these exact values (Task 25).
public enum Theme {
    public static let surface       = Color(hex: "#0a0a0f")
    public static let raised        = Color(hex: "#12121a")
    public static let textPrimary   = Color(hex: "#f0f0f5")
    public static let textSecondary = Color(hex: "#8888a0")
    public static let success       = Color(hex: "#10b981")
    public static let warning       = Color(hex: "#f59e0b")
    public static let danger        = Color(hex: "#ef4444")
    public static let accent        = Color(hex: "#6366f1")   // fixed in 1c; preset picker is Phase 2

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }
    public enum Radius {
        public static let card: CGFloat = 14
        public static let pill: CGFloat = 8
        public static let swatch: CGFloat = 6
    }
}

public extension Color {
    /// Parses `#rgb` / `#rrggbb` (case-insensitive) into an sRGB colour.
    /// Unparseable input degrades to opaque black, never crashes.
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let r, g, b: Double
        if raw.count == 3 {
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

public extension ReadableTextColor {
    /// The concrete SwiftUI colour for the WCAG-picked foreground candidate.
    var color: Color { Color(hex: hex) }
}

// MARK: - Reduce motion

/// The user's synced in-app "reduce motion" preference (`Settings.reducedMotion`),
/// independent of the system-wide accessibility setting. Screens inject this from
/// `AppModel.settings?.reducedMotion` via `.environment(\.appReducedMotion, ...)`;
/// defaults to `false` (matches `Settings`' own default) until the value lands.
private struct AppReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var appReducedMotion: Bool {
        get { self[AppReducedMotionKey.self] }
        set { self[AppReducedMotionKey.self] = newValue }
    }

    /// Motion should be suppressed when EITHER the system accessibility setting
    /// OR the synced app preference requests it (reconciliation §, AUTHORITATIVE).
    /// Animated views read this to gate transitions/flash; NEVER used to gate
    /// informational live counters, which must keep ticking regardless.
    var effectiveReduceMotion: Bool {
        accessibilityReduceMotion || appReducedMotion
    }
}
