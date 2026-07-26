import Testing
@testable import MedTrackerCore

@Test func idShape() {
    let id = createId()
    #expect(id.count == 24)
    #expect(id.first!.isLetter)
    #expect(id.allSatisfy { $0.isLowercase || $0.isNumber })
}
@Test func idsAreUnique() {
    let ids = Set((0..<10_000).map { _ in createId() })
    #expect(ids.count == 10_000)
}
