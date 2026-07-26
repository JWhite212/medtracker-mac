import Foundation
import Testing
@testable import MedTrackerCore

// Transcribes `describe("buildSparklineShape", ...)` from
// `tests/unit/sparkline.test.ts:4-49` verbatim, including the exact expected
// path strings (spacing, "M"/"L"/"Z", and JS-style decimal rendering).

@Test func buildSparklineShape_returnsEmptyShapeForEmptyValues() {
    let s = buildSparklineShape(values: [], width: 80, height: 24)
    #expect(s.line == "")
    #expect(s.area == "")
    #expect(s.dotX == nil)
    #expect(s.dotY == nil)
}

@Test func buildSparklineShape_returnsACentredDotForASingleValue() {
    let s = buildSparklineShape(values: [5], width: 80, height: 24)
    #expect(s.line == "")
    #expect(s.area == "")
    #expect(s.dotX == 40)
    #expect(s.dotY == 12)
}

@Test func buildSparklineShape_drawsAFlatHorizontalLineWhenAllValuesEqual() {
    let s = buildSparklineShape(values: [5, 5, 5], width: 80, height: 24)
    #expect(s.line == "M 0 12 L 40 12 L 80 12")
    #expect(s.area.contains("L 80 24 L 0 24 Z"))
    #expect(s.dotX == nil)
    #expect(s.dotY == nil)
}

@Test func buildSparklineShape_drawsAVaryingLineForDistinctValues() {
    let s = buildSparklineShape(values: [1, 5, 3, 8, 2], width: 80, height: 24)
    #expect(s.line.hasPrefix("M 0 "))
    #expect(s.line.contains("L 20 "))
    #expect(s.line.contains("L 40 "))
    #expect(s.line.contains("L 60 "))
    #expect(s.line.contains("L 80 "))
    // Max value (8) lands near the top of the SVG (y close to strokeWidth/2).
    #expect(s.line.contains("L 60 0.8"))
}

@Test func buildSparklineShape_appendsAClosingAreaPathThatReturnsToTheBottom() {
    let s = buildSparklineShape(values: [1, 5, 3, 8, 2], width: 80, height: 24)
    #expect(s.area.hasSuffix("L 80 24 L 0 24 Z"))
}

@Test func buildSparklineShape_respectsCustomWidthAndHeight() {
    let s = buildSparklineShape(values: [0, 10], width: 100, height: 40)
    #expect(s.line == "M 0 39.3 L 100 0.8")
}
