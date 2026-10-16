import XCTest
@testable import SculptShowCore

final class ShowTests: XCTestCase {
    func testSaveAndLoadPreservesMultipleListsAndCueSettings() throws {
        var show = Show(name: "Opening Night")
        let firstID = try XCTUnwrap(show.cueLists.first?.id)
        let secondID = show.addList(name: "Ambience")
        let cueIDs = show.addAudio([
            URL(fileURLWithPath: "/tmp/intro.wav"),
            URL(fileURLWithPath: "/tmp/walk-in.aiff")
        ], to: firstID)
        show.addAudio([URL(fileURLWithPath: "/tmp/room.wav")], to: secondID)
        show.updateCue(cueIDs[0], in: firstID) { cue in
            cue.gain = 0.5
            cue.fadeOutSeconds = 3.5
        }

        let decoded = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(decoded, show)
        XCTAssertEqual(decoded.cueLists.count, 2)
        XCTAssertEqual(decoded.cueLists[0].cues[0].gain, 0.5)
        XCTAssertEqual(decoded.cueLists[0].cues[0].name, "intro")
    }

    func testCueTintPersistsDuplicatesAndDoesNotModifyAudio() throws {
        var show = Show(name: "Color test")
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/stem.wav")], to: list).first)
        let path = try XCTUnwrap(show.cue(id)?.mediaPath)
        show.updateCue(id, in: list) { $0.tint = .purple }
        let duplicated = try XCTUnwrap(show.duplicateCue(id, in: list))
        XCTAssertEqual(show.cue(duplicated)?.tint, .purple)
        XCTAssertEqual(show.cue(duplicated)?.mediaPath, path)
        let reopened = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(reopened.cue(id)?.tint, .purple)
        XCTAssertEqual(reopened.cue(duplicated)?.tint, .purple)
        XCTAssertEqual(reopened.cue(id)?.mediaPath, path)
    }

    func testLegacyCueWithoutTintDecodesAsNone() throws {
        let original = Cue(name: "old", mediaPath: "/tmp/old.wav")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "tint")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(Cue.self, from: legacy)
        XCTAssertEqual(restored.tint, .none)
    }

    func testListCannotRemoveLastList() {
        var show = Show()
        show.removeList(show.cueLists[0].id)
        XCTAssertEqual(show.cueLists.count, 1)
    }

    func testEditAndRemoveCue() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let cueID = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/audio.mp3")], to: listID).first)
        show.updateCue(cueID, in: listID) { $0.name = "New Name" }
        XCTAssertEqual(show.cue(cueID)?.name, "New Name")
        show.removeCue(cueID, from: listID)
        XCTAssertNil(show.cue(cueID))
    }

    func testRejectUnsupportedVersion() throws {
        var show = Show()
        show.formatVersion = 99
        XCTAssertThrowsError(try ShowCodec.decode(ShowCodec.encode(show)))
    }

    func testGainAndFadeAreBounded() {
        let cue = Cue(name: "T", mediaPath: "/tmp/x.wav", gain: 5, fadeOutSeconds: -1)
        XCTAssertEqual(cue.gain, 1)
        XCTAssertEqual(cue.fadeOutSeconds, 0)
    }

    func testNewCueOptionsRoundTrip() throws {
        let cue = Cue(name: "Room tone", mediaPath: "/tmp/room.wav", gain: 0.6,
                      fadeOutSeconds: 4, fadeInSeconds: 1.5, loop: true, followOnFinish: true)
        let encoded = try JSONEncoder().encode(cue)
        let decoded = try JSONDecoder().decode(Cue.self, from: encoded)
        XCTAssertEqual(decoded, cue)
        XCTAssertEqual(decoded.fadeInSeconds, 1.5)
        XCTAssertTrue(decoded.loop)
        XCTAssertTrue(decoded.followOnFinish)
    }

    func testOldShowWithoutNewFieldsStillOpens() throws {
        var show = Show(name: "Old Show")
        let id = try XCTUnwrap(show.cueLists.first?.id)
        _ = show.addAudio([URL(fileURLWithPath: "/tmp/old.wav")], to: id)
        let originalData = try ShowCodec.encode(show)
        // This simulates the exact v1 JSON structure (the new fields did not exist).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        var lists = try XCTUnwrap(json["cueLists"] as? [[String: Any]])
        var cues = try XCTUnwrap(lists[0]["cues"] as? [[String: Any]])
        cues[0].removeValue(forKey: "loop")
        cues[0].removeValue(forKey: "fadeInSeconds")
        cues[0].removeValue(forKey: "followOnFinish")
        lists[0]["cues"] = cues
        json["cueLists"] = lists
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let opened = try ShowCodec.decode(legacyData)
        XCTAssertEqual(opened.cueLists[0].cues[0].fadeInSeconds, 0)
        XCTAssertFalse(opened.cueLists[0].cues[0].loop)
        XCTAssertFalse(opened.cueLists[0].cues[0].followOnFinish)
    }

    func testMovingCueReordersWithoutChangingIDsOrParameters() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let ids = show.addAudio([
            URL(fileURLWithPath: "/tmp/first.wav"),
            URL(fileURLWithPath: "/tmp/second.wav"),
            URL(fileURLWithPath: "/tmp/third.wav")
        ], to: list)
        show.updateCue(ids[1], in: list) { $0.gain = 0.32 }
        show.moveCue(ids[1], in: list, by: -1)
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [ids[1],ids[0],ids[2]])
        XCTAssertEqual(show.cueLists[0].cues[0].gain, 0.32)
        show.moveCue(ids[1], in: list, by: -1) // Out of bounds ignored.
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [ids[1],ids[0],ids[2]])
    }

    func testFollowingCueSkipsDisabledWithoutWrapping() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let ids = show.addAudio([
            URL(fileURLWithPath: "/tmp/first.wav"),
            URL(fileURLWithPath: "/tmp/disabled.wav"),
            URL(fileURLWithPath: "/tmp/third.wav")
        ], to: list)
        show.updateCue(ids[1], in: list) { $0.enabled = false }
        XCTAssertEqual(show.followingCue(after: ids[0])?.id, ids[2])
        XCTAssertNil(show.followingCue(after: ids[2]))
        XCTAssertNil(show.followingCue(after: UUID()))
    }

    func testAdditionalOptionsBoundedInInitializer() {
        let cue = Cue(name: "test", mediaPath: "/tmp/test.wav", fadeInSeconds: -22)
        XCTAssertEqual(cue.fadeInSeconds, 0)
    }

    func testPreWaitPersistsAndIsBounded() throws {
        let original = Cue(name: "Waited", mediaPath: "/tmp/wait.wav", preWaitSeconds: 4.5)
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.preWaitSeconds, 4.5)
        XCTAssertEqual(Cue(name: "negative", mediaPath: "n", preWaitSeconds: -12).preWaitSeconds, 0)
        XCTAssertEqual(Cue(name: "limit", mediaPath: "n", preWaitSeconds: 9999).preWaitSeconds, 600)
    }

    func testDuplicateCueCopiesSettingsButNotIdentity() throws {
        var show = Show(name: "Demo")
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let ids = show.addAudio([URL(fileURLWithPath: "/tmp/intro.wav"),
                                 URL(fileURLWithPath: "/tmp/outro.wav")], to: listID)
        show.updateCue(ids[0], in: listID) { cue in
            cue.gain = 0.3
            cue.loop = true
            cue.preWaitSeconds = 3
            cue.followOnFinish = false
        }
        let copiedID = try XCTUnwrap(show.duplicateCue(ids[0], in: listID))
        XCTAssertNotEqual(ids[0], copiedID)
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [ids[0], copiedID, ids[1]])
        let duplicate = try XCTUnwrap(show.cue(copiedID))
        XCTAssertEqual(duplicate.name, "intro copy")
        XCTAssertEqual(duplicate.mediaPath, "/tmp/intro.wav")
        XCTAssertEqual(duplicate.preWaitSeconds, 3)
        XCTAssertTrue(duplicate.loop)
        XCTAssertEqual(duplicate.gain, 0.3)
        XCTAssertNil(show.duplicateCue(UUID(), in: listID))
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }

    func testOldProjectWithoutPreWaitDefaultsToZero() throws {
        var show = Show(name: "Legacy v0.2")
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        show.addAudio([URL(fileURLWithPath: "/tmp/test.wav")], to: listID)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ShowCodec.encode(show)) as? [String: Any])
        var lists = try XCTUnwrap(json["cueLists"] as? [[String: Any]])
        var cues = try XCTUnwrap(lists[0]["cues"] as? [[String: Any]])
        cues[0].removeValue(forKey: "preWaitSeconds")
        lists[0]["cues"] = cues
        json["cueLists"] = lists
        let old = try ShowCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.cueLists[0].cues[0].preWaitSeconds, 0)
    }

    func testRenameShowAndListPersistAcrossSave() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        show.name = "Concerto primavera"
        show.renameList(listID, to: "Ambienti")
        let restored = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(restored.name, "Concerto primavera")
        XCTAssertEqual(restored.cueLists[0].name, "Ambienti")
    }

}
