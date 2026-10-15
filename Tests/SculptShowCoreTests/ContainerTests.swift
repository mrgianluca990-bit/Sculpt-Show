import XCTest
@testable import SculptShowCore

final class ContainerTests: XCTestCase {
    func testEveryNewCueStartsAsIndependentEmptyTimeline() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: listID))
        let cue = try XCTUnwrap(show.cue(id))
        XCTAssertTrue(cue.isEmpty)
        XCTAssertFalse(cue.hasAudio)
        XCTAssertEqual(cue.durationMode, .fixed)
        XCTAssertEqual(cue.durationSeconds, 5)
        XCTAssertEqual(cue.timelineLength(audioEnds: []), 5)
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }

    func testContainerCanHoldSeveralAudioElementsWithOffsetsAndTrim() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: listID))
        XCTAssertTrue(show.appendAudio([
            URL(fileURLWithPath: "/tmp/music.wav"),
            URL(fileURLWithPath: "/tmp/ambience.wav")
        ], to: id))
        show.updateCue(id, in: listID) { cue in
            cue.durationSeconds = 27
            cue.elements[0].startSeconds = 2
            cue.elements[0].inSeconds = 4
            cue.elements[0].outSeconds = 8
            cue.elements[1].startSeconds = 8
            cue.rules.append(InteractionRule(event: .ending, action: .fire))
        }
        let cue = try XCTUnwrap(show.cue(id))
        XCTAssertEqual(cue.audioElements.count, 2)
        XCTAssertEqual(cue.durationSeconds, 27)
        XCTAssertEqual(cue.timelineLength(audioEnds: [6, 20]), 27)
        XCTAssertEqual(cue.elements[0].inSeconds, 4)
        XCTAssertEqual(cue.elements[1].startSeconds, 8)
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }

    func testRulesOnlyAndTimecodeMetadataInsideSameTypeOfCue() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: listID))
        show.updateCue(id, in: listID) { cue in
            cue.rules.append(InteractionRule(event: .starting, action: .fire))
        }
        XCTAssertTrue(try XCTUnwrap(show.cue(id)).isEmpty)
        show.updateCue(id, in: listID) { cue in
            var tc = CueElement.timecode()
            tc.timecodeStart = "01:23:00:00"
            tc.startSeconds = 3.5
            cue.elements.append(tc)
        }
        let restored = try ShowCodec.decode(ShowCodec.encode(show))
        let cue = try XCTUnwrap(restored.cue(id))
        XCTAssertTrue(cue.hasTimecode)
        XCTAssertFalse(cue.hasAudio)
        XCTAssertEqual(cue.elements[0].timecodeStart, "01:23:00:00")
        XCTAssertEqual(cue.elements[0].startSeconds, 3.5)
        XCTAssertEqual(cue.rules.count, 1)
    }

    func testDragReorderWithinListAndMoveBetweenListsPreservesCueIdentityAndRules() throws {
        var show = Show()
        let a = try XCTUnwrap(show.cueLists.first?.id)
        let b = show.addList(name: "Backstage")
        let first = try XCTUnwrap(show.addEmptyCue(to: a))
        let second = try XCTUnwrap(show.addEmptyCue(to: a))
        let third = try XCTUnwrap(show.addEmptyCue(to: a))
        show.updateCue(second, in: a) { cue in
            cue.durationSeconds = 11
            cue.rules.append(InteractionRule(event: .starting, action: .dim, target: .itself))
        }
        XCTAssertTrue(show.relocateCue(third, to: a, before: first))
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [third, first, second])
        XCTAssertTrue(show.relocateCue(second, to: b))
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [third, first])
        XCTAssertEqual(show.cueLists[1].cues.map(\.id), [second])
        XCTAssertEqual(show.cue(second)?.rules.count, 1)
        XCTAssertEqual(show.cue(second)?.durationSeconds, 11)
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }

    func testInvalidDropDoesNotChangeShow() throws {
        var show = Show()
        let a = try XCTUnwrap(show.cueLists.first?.id)
        let c = try XCTUnwrap(show.addEmptyCue(to: a))
        let previous = show
        XCTAssertFalse(show.relocateCue(c, to: a, before: c))
        XCTAssertFalse(show.relocateCue(c, to: UUID()))
        XCTAssertFalse(show.relocateCue(c, to: a, before: UUID()))
        XCTAssertFalse(show.relocateCue(UUID(), to: a))
        XCTAssertEqual(show, previous)
    }

    func testLegacyAudioCueMigratesToElementsAndRetainsNaturalDurationMode() throws {
        let id = UUID()
        let text = """
        {"id":"\(id.uuidString)","name":"Old soundtrack","mediaPath":"/tmp/old.wav",
         "gain":0.7,"fadeOutSeconds":2.0,"enabled":true,
         "inPointSeconds":5.5,"outPointSeconds":12.5,"durationSeconds":5.0}
        """
        let old = try JSONDecoder().decode(Cue.self, from: Data(text.utf8))
        XCTAssertEqual(old.durationMode, .mediaEnd)
        XCTAssertEqual(old.mediaPath, "/tmp/old.wav")
        XCTAssertEqual(old.audioElements.count, 1)
        XCTAssertEqual(old.playbackWindow(sourceDuration: 30).duration, 7)
        let restored = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(restored, old)
    }

    func testTimecodeValidation() {
        XCTAssertTrue(CueElement.isValidTimecode("01:23:45:24", frameRate: 25))
        XCTAssertFalse(CueElement.isValidTimecode("01:23:45:25", frameRate: 25))
        XCTAssertFalse(CueElement.isValidTimecode("23:60:00:00", frameRate: 30))
        XCTAssertFalse(CueElement.isValidTimecode("bogus", frameRate: 24))
    }

    func testDuplicateContainerGetsNewCueAndElementIDs() throws {
        var show = Show()
        let a = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: a))
        XCTAssertTrue(show.appendAudio([URL(fileURLWithPath: "/tmp/first.wav")], to: id))
        let copied = try XCTUnwrap(show.duplicateCue(id, in: a))
        XCTAssertNotEqual(copied, id)
        XCTAssertNotEqual(show.cue(id)?.elements[0].id, show.cue(copied)?.elements[0].id)
    }
}
