import XCTest
@testable import SculptShowCore

final class TimingTests: XCTestCase {
    func testEmptyCueInsertionAfterSelectionAndRoundTrip() throws {
        var show = Show(name: "Scene 2")
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let firstID = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/a.wav")], to: listID).first)
        let lastID = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/b.wav")], to: listID).first)
        let emptyID = try XCTUnwrap(show.addEmptyCue(to: listID, after: firstID))
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [firstID, emptyID, lastID])
        let empty = try XCTUnwrap(show.cue(emptyID))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.durationSeconds, 5)
        let decoded = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(show, decoded)
    }

    func testEmptyCueCanTriggerRulesAndFollow() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let emptyID = try XCTUnwrap(show.addEmptyCue(to: listID))
        let audioID = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/next.wav")], to: listID).first)
        show.updateCue(emptyID, in: listID) { $0.rules.append(InteractionRule(event: .ending, action: .fire, target: .nextCue)) }
        let commands = RulePlanner.commands(for: .ending, source: emptyID, in: show, states: [:])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].targets, [audioID])
    }

    func testTrimCalculatesEffectiveLength() {
        let cue = Cue(name: "trim", mediaPath: "/tmp/recording.wav", inPointSeconds: 8, outPointSeconds: 22)
        let r = cue.playbackWindow(sourceDuration: 60)
        XCTAssertEqual(r.start, 8)
        XCTAssertEqual(r.end, 22)
        XCTAssertEqual(r.duration, 14)
    }

    func testTrimWindowClampedAtSourceBoundaries() {
        let cue = Cue(name: "trim", mediaPath: "x", inPointSeconds: 3, outPointSeconds: 90)
        XCTAssertEqual(cue.playbackWindow(sourceDuration: 10).duration, 7)
        let reversed = Cue(name: "trim", mediaPath: "x", inPointSeconds: 8, outPointSeconds: 2)
        XCTAssertEqual(reversed.playbackWindow(sourceDuration: 10).duration, 0)
    }

    func testEmptyDurationIndependentOfMediaWindow() {
        let cue = Cue(name: "silent", mediaPath: "", durationSeconds: 9.5)
        XCTAssertEqual(cue.playbackWindow(sourceDuration: 400).duration, 9.5)
        XCTAssertEqual(Cue(name: "silent", mediaPath: "", durationSeconds: -4).durationSeconds, 0)
        XCTAssertEqual(Cue(name: "silent", mediaPath: "", durationSeconds: 90000).durationSeconds, 86400)
    }

    func testTrimPersistenceAndDuplicateIndependence() throws {
        var show = Show()
        let listID = show.cueLists[0].id
        let id = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/music.wav")], to: listID).first)
        show.updateCue(id, in: listID) { $0.inPointSeconds = 2.5; $0.outPointSeconds = 7.0 }
        let copyID = try XCTUnwrap(show.duplicateCue(id, in: listID))
        XCTAssertEqual(show.cue(copyID)?.outPointSeconds, 7.0)
        show.updateCue(copyID, in: listID) { $0.outPointSeconds = 12 }
        XCTAssertEqual(show.cue(id)?.outPointSeconds, 7.0)
        let reopened = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(reopened.cue(id)?.playbackWindow(sourceDuration: 20).duration, 4.5)
        XCTAssertEqual(reopened.cue(copyID)?.playbackWindow(sourceDuration: 20).duration, 9.5)
    }

    func testLegacyProjectWithoutTrimFieldsStillOpens() throws {
        var show = Show()
        let id = show.cueLists[0].id
        _ = show.addAudio([URL(fileURLWithPath: "/tmp/a.wav")], to: id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ShowCodec.encode(show)) as? [String: Any])
        var lists = try XCTUnwrap(json["cueLists"] as? [[String: Any]])
        var cues = try XCTUnwrap(lists[0]["cues"] as? [[String: Any]])
        cues[0].removeValue(forKey: "inPointSeconds")
        cues[0].removeValue(forKey: "outPointSeconds")
        cues[0].removeValue(forKey: "durationSeconds")
        lists[0]["cues"] = cues
        json["cueLists"] = lists
        let reopened = try ShowCodec.decode(JSONSerialization.data(withJSONObject: json))
        let cue = reopened.cueLists[0].cues[0]
        XCTAssertEqual(cue.inPointSeconds, 0)
        XCTAssertNil(cue.outPointSeconds)
        XCTAssertEqual(cue.durationSeconds, 5)
    }
}
