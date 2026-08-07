import MedTrackerCore
import SwiftUI

/// A text label with a 1px outline in each of the four cardinal directions,
/// used to keep medication labels legible over arbitrary user colours/patterns
/// (§6). Pairs with `getReadableTextColor` for the fill choice.
public struct OutlinedText: View {
    private let text: String
    private let fill: Color
    private let outline: Color
    private let font: Font

    public init(_ text: String, fill: Color, outline: Color, font: Font = .body.weight(.semibold)) {
        self.text = text
        self.fill = fill
        self.outline = outline
        self.font = font
    }

    /// Fill = the WCAG-picked candidate; outline = the opposite candidate.
    public static func forContrast(_ text: String, textColor: ReadableTextColor,
                                   font: Font = .body.weight(.semibold)) -> OutlinedText
    {
        let opposite: ReadableTextColor = textColor == .dark ? .light : .dark
        return OutlinedText(text, fill: textColor.color, outline: opposite.color, font: font)
    }

    private static let offsets: [CGSize] = [
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1), CGSize(width: 0, height: 1),
    ]

    public var body: some View {
        let base = Text(text).font(font)
        ZStack {
            ForEach(0 ..< Self.offsets.count, id: \.self) { i in
                base.foregroundStyle(outline).offset(Self.offsets[i])
            }
            base.foregroundStyle(fill)
        }
    }
}
