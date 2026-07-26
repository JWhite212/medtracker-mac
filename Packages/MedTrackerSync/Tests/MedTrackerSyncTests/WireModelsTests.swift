import Foundation
@testable import MedTrackerSync
import MedTrackerTestSupport
import Testing

private let dec = JSONDecoder()

@Test func decodesSessionUser() throws {
    let r = try dec.decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    #expect(r.epoch == 2)
    #expect(r.fullResync == false)
    #expect(r.cursor == "2026-07-26T10:00:00.000Z")
    #expect(r.medications.count == 1)
    #expect(r.medications[0].dosageAmount == "50") // numeric-as-string preserved
    #expect(r.medications[0].scheduleIntervalHours == nil)
    #expect(r.medications[0].schedules[0].intervalHours == "8")
    #expect(r.medications[0].inventoryCount == 30)
    #expect(r.doseLogs[0].status == "taken")
    #expect(r.tombstones[0].entityType == "dose_log")
    #expect(r.tombstones[0].entityId == "dOld")
    #expect(r.preferences == nil)
}

@Test func decodesLoginOutcomes() throws {
    let s = try dec.decode(LoginOutcome.self, from: Data(Fixtures.loginSession.utf8))
    guard case let .session(token, user) = s else { Issue.record("expected session"); return }
    #expect(token == "sess_abc")
    #expect(user.timezone == "Europe/London")
    let t = try dec.decode(LoginOutcome.self, from: Data(Fixtures.loginTotp.utf8))
    #expect(t == .totpChallenge(preAuthToken: "pre_xyz"))
}

@Test func jsonValueDeepReplace() {
    let v = JSONValue.object(["medicationId": .string("X"), "n": .number(1),
                              "kids": .array([.string("X"), .string("Y")])])
    let out = v.replacing("X", with: "Z")
    #expect(out["medicationId"]?.stringValue == "Z")
    #expect(out["kids"] == .array([.string("Z"), .string("Y")]))
}

@Test func encodesCommandEnvelope() throws {
    let cmd = WireCommand(id: "k1", type: "log_dose",
                          payload: .object(["medicationId": .string("m1")]))
    let data = try JSONEncoder().encode(CommandEnvelope(commands: [cmd]))
    let back = try dec.decode(CommandEnvelope.self, from: data)
    #expect(back.commands[0].payload["medicationId"]?.stringValue == "m1")
}
