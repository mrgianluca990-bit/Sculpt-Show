import XCTest
@testable import SculptShowCore

final class CueTriggerTests: XCTestCase {
    func testLegacyDefaultsAndProjectRoundTrip() throws {
        var show = Show(); var cue = Cue(name: "Trigger")
        cue.triggers.midi = .init(channel: 2, status: 0x90, number: 60)
        cue.triggers.key = .init(keyCode: 0, modifiers: 2, label: "⌥A")
        cue.triggers.oscAlias = "/sculpt/trigger/intro"
        show.cueLists[0].cues = [cue]
        let data = try JSONEncoder().encode(show)
        XCTAssertEqual(try JSONDecoder().decode(Show.self, from: data), show)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cue)) as? [String: Any])
        json.removeValue(forKey: "triggers")
        let old = try JSONDecoder().decode(Cue.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.triggers, CueTriggers())
    }
    func testStableResolutionAndDisabledCue() {
        var show = Show(); var cue = Cue(name: "One")
        cue.triggers.midi = .init(channel: 0, status: 0xB0, number: 8)
        cue.triggers.key = .init(keyCode: 0, modifiers: 2, label: "⌥A")
        cue.triggers.oscAlias = "/sculpt/trigger/one"
        show.cueLists[0].cues = [Cue(name: "Other"), cue]
        XCTAssertEqual(CueTriggerResolver.matching(in: show, midi: cue.triggers.midi), cue.id)
        XCTAssertEqual(CueTriggerResolver.matching(in: show, keyCode: 0, modifiers: 2), cue.id)
        XCTAssertNil(CueTriggerResolver.matching(in: show, keyCode: 0, modifiers: 0))
        XCTAssertEqual(CueTriggerResolver.matching(in: show, oscAlias: "/sculpt/trigger/one"), cue.id)
        show.cueLists[0].cues.reverse()
        XCTAssertEqual(CueTriggerResolver.matching(in: show, midi: cue.triggers.midi), cue.id)
        show.cueLists[0].cues[0].enabled = false
        XCTAssertNil(CueTriggerResolver.matching(in: show, midi: cue.triggers.midi))
    }
    func testConflictsAreRejectedAndAmbiguityNeverFires() {
        var show = Show(); var first = Cue(name: "First"), second = Cue(name: "Second")
        first.triggers.key = .init(keyCode: 0, modifiers: 0, label: "A")
        first.triggers.midi = .init(channel: 0, status: 0x90, number: 60)
        first.triggers.oscAlias = "/sculpt/trigger/intro"
        second.triggers = first.triggers
        show.cueLists[0].cues = [first, second]
        XCTAssertNotNil(CueTriggerResolver.conflict(second.triggers, cueID: second.id, in: show))
        XCTAssertNil(CueTriggerResolver.matching(in: show, midi: first.triggers.midi))
        XCTAssertNil(CueTriggerResolver.matching(in: show, oscAlias: first.triggers.oscAlias))
    }
    func testReservedKeysMalformedMIDIAndAlias() {
        var value = CueTriggers()
        for key: UInt16 in [49,48,53,126,125,35,3,46,45,51,117] {
            value.key = .init(keyCode: key, modifiers: 0, label: "reserved")
            XCTAssertNotNil(value.validationError)
            value.key = .init(keyCode: key, modifiers: 2, label: "option")
            XCTAssertNil(value.validationError)
        }
        value.key = nil; value.midi = .init(channel: 16, status: 0x90, number: 60)
        XCTAssertNotNil(value.validationError)
        value.midi = nil
        for alias in ["/go", "/sculpt/trigger/", "/sculpt/trigger/a*b", "/sculpt/trigger/two words"] {
            value.oscAlias = alias; XCTAssertNotNil(value.validationError)
        }
    }
    func testDuplicateGetsIndependentUnassignedTriggers() throws {
        var show = Show(); var cue = Cue(name: "One")
        cue.triggers.key = .init(keyCode: 0, modifiers: 0, label: "A")
        cue.triggers.oscAlias = "/sculpt/trigger/intro"
        show.cueLists[0].cues = [cue]
        let id = try XCTUnwrap(show.duplicateCue(cue.id, in: show.cueLists[0].id))
        XCTAssertEqual(show.cue(id)?.triggers, CueTriggers())
        XCTAssertEqual(show.cue(cue.id)?.triggers, cue.triggers)
    }
    func testOSCAliasPacketAndRelease() throws {
        func padded(_ s: String) -> Data { var d = Data(s.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; return d }
        let address = padded("/sculpt/trigger/intro")
        XCTAssertEqual(try OSCControlPacket.decode(address + padded(",")), [.trigger("/sculpt/trigger/intro")])
        XCTAssertEqual(try OSCControlPacket.decode(address + padded(",i") + Data([0,0,0,0])), [])
        XCTAssertThrowsError(try OSCControlPacket.decode(padded("/sculpt/trigger/a*b") + padded(",")))
    }
}
