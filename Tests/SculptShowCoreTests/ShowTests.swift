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
}
