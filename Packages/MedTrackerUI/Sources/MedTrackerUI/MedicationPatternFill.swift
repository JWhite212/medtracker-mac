import SwiftUI
import MedTrackerCore

/// SwiftUI port of the web's per-pattern `background-image` geometry
/// (`getMedicationBackground`), with the `<20pt → gradient` degradation (§6).
/// Colour selection defers to Core's `renderedColours` so a saved-but-unused
/// secondary never renders (parity with the contrast picker).
public struct MedicationPatternFill: View {
    public static let degradationThreshold: CGFloat = 20

    /// Whether a swatch of this size renders the simplified gradient instead of
    /// the full pattern geometry. Pure so the §6 threshold is verifiable without
    /// pixel comparison (image snapshots drift across toolchain/OS releases).
    public static func isDegraded(minDimension: CGFloat) -> Bool {
        minDimension < degradationThreshold
    }

    private let pattern: MedicationPattern
    private let colours: [Color]   // 1 or 2 entries, per renderedColours

    public init(colour: String, colourSecondary: String?, pattern: MedicationPattern) {
        self.pattern = pattern
        self.colours = renderedColours(colour: colour, colourSecondary: colourSecondary, pattern: pattern)
            .map(Color.init(hex:))
    }

    private var primary: Color { colours[0] }
    private var secondary: Color { colours.count > 1 ? colours[1] : colours[0] }
    private var overlay: Color { colours.count > 1 ? secondary : Color.white.opacity(0.28) }

    public var body: some View {
        GeometryReader { geo in
            if Self.isDegraded(minDimension: min(geo.size.width, geo.size.height)) {
                degraded
            } else {
                fullPattern(geo.size)
            }
        }
    }

    /// Small-size fallback: a 2-stop diagonal gradient (a single colour when no
    /// secondary renders), avoiding sub-pixel stripe/dot aliasing at swatch scale.
    private var degraded: some View {
        LinearGradient(colors: colours.count > 1 ? colours : [primary, primary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private func fullPattern(_ size: CGSize) -> some View {
        switch pattern {
        case .solid:
            primary
        case .split:
            HStack(spacing: 0) { primary; secondary }
        case .gradient:
            LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .radial:
            RadialGradient(colors: [primary, secondary], center: .center,
                           startRadius: 0, endRadius: max(size.width, size.height) / 2)
        case .stripes, .hStripes, .dots, .checkerboard:
            Canvas { ctx, canvasSize in geometric(ctx, canvasSize) }
        }
    }

    private func geometric(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(primary))
        switch pattern {
        case .stripes:
            var x = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(line, with: .color(overlay), lineWidth: 4)
                x += 10
            }
        case .hStripes:
            var y = 0.0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 4)), with: .color(overlay))
                y += 10
            }
        case .dots:
            let step = 12.0
            var y = 6.0
            while y < size.height {
                var x = 6.0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(overlay))
                    x += step
                }
                y += step
            }
        case .checkerboard:
            let cell = 10.0
            var row = 0
            var y = 0.0
            while y < size.height {
                var col = 0
                var x = 0.0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(overlay))
                    }
                    x += cell; col += 1
                }
                y += cell; row += 1
            }
        default:
            break
        }
    }
}
