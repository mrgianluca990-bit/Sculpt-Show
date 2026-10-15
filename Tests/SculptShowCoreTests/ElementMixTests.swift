import XCTest
@testable import SculptShowCore

final class ElementMixTests: XCTestCase {
    func testNewAudioElementDefaultsToUnityAndNotMuted() {
        let element = CueElement.audio(URL(fileURLWithPath: "/tmp/audio.wav"))
        XCTAssertEqual(element.gain, 1)
        XCTAssertFalse(element.muted)
    }

    func testElementMixIsIndependentAndSavedInsideCue() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let cueID = try XCTUnwrap(show.addEmptyCue(to: listID))
        XCTAssertTrue(show.appendAudio([
            URL(fileURLWithPath: "/tmp/music.wav"),
            URL(fileURLWithPath: "/tmp/voice.wav")
        ], to: cueID))
        show.updateCue(cueID, in: listID) { cue in
            cue.elements[0].gain = 0.45
            cue.elements[0].muted = true
        }
        let saved = try ShowCodec.decode(ShowCodec.encode(show))
        let elements = try XCTUnwrap(saved.cue(cueID)).audioElements
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].gain, 0.45)
        XCTAssertTrue(elements[0].muted)
        XCTAssertEqual(elements[1].gain, 1)
        XCTAssertFalse(elements[1].muted)
    }

    func testLegacyElementJSONDefaultsMixWithoutFailing() throws {
        let original = CueElement.audio(URL(fileURLWithPath: "/tmp/old.wav"))
        let originalData = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        json.removeValue(forKey: "gain")
        json.removeValue(forKey: "muted")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CueElement.self, from: legacy)
        XCTAssertEqual(decoded.gain, 1)
        XCTAssertFalse(decoded.muted)
    }

    func testInitialGainIsBounded() {
        XCTAssertEqual(CueElement(kind: .audio, name: "test", gain: 500).gain, 1)
        XCTAssertEqual(CueElement(kind: .audio, name: "test", gain: -3).gain, 0)
        XCTAssertEqual(CueElement(kind: .audio, name: "test", gain: .nan).gain, 1)
    }

    func testDuplicatedCuePreservesMixButChangesElementIdentity() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: listID))
        XCTAssertTrue(show.appendAudio([URL(fileURLWithPath: "/tmp/audio.wav")], to: id))
        show.updateCue(id, in: listID) { cue in
            cue.elements[0].gain = 0.25
            cue.elements[0].muted = true
        }
        let cloneID = try XCTUnwrap(show.duplicateCue(id, in: listID))
        let original = try XCTUnwrap(show.cue(id)?.elements.first)
        let clone = try XCTUnwrap(show.cue(cloneID)?.elements.first)
        XCTAssertNotEqual(original.id, clone.id)
        XCTAssertEqual(original.gain, clone.gain)
        XCTAssertEqual(original.muted, clone.muted)
    }
}
