import Foundation
import XCTest
@testable import SculptShowCore

final class SculptBridgeReturnTests: XCTestCase {
    private func fixture(mode: String = "updateCue") throws -> (Show, URL, Data) {
        var show = Show(name: "Live")
        var cue = Cue(name: "Music", mediaPath: "/old.wav")
        cue.elements[0].pan = -0.4
        cue.elements[0].sendToMonitor = false
        cue.elements.append(.timecode())
        cue.markers = [CueMarker(name: "Verse", positionSeconds: 1)]
        cue.loop = true
        show.cueLists[0].cues = [cue]
        let manifest = try SculptBridge.manifest(show: show, listID: show.cueLists[0].id, cueID: cue.id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SculptBridge.encode(manifest)) as? [String: Any])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("Audio/mono.wav")
        try Data([1, 2, 3]).write(to: audio) // Codec preflight is deliberately app-side.
        json["publicationID"] = UUID().uuidString
        json["publishMode"] = mode
        json["originSessionPath"] = "/Session.scdaw"
        json["durationSeconds"] = 3.0
        json["stems"] = [["elementID": cue.audioElements[0].id.uuidString, "name": "Edited", "sourcePath": audio.path,
                          "outputStartChannel": 64, "gain": 1.0, "muted": true]]
        if mode == "newCue" { json["cueID"] = UUID().uuidString }
        return (show, folder.appendingPathComponent("publication.sculptbridge"), try JSONSerialization.data(withJSONObject: json))
    }

    func testUpdatePreservesCueIdentityShowControlsAndLTC() throws {
        let (show, url, data) = try fixture()
        let packet = try SculptBridgeReturn.decode(data, at: url)
        let updated = try SculptBridgeReturn.applying(packet, to: show)
        let cue = updated.cueLists[0].cues[0]
        XCTAssertEqual(cue.id, show.cueLists[0].cues[0].id)
        XCTAssertEqual(cue.audioElements[0].id, show.cueLists[0].cues[0].audioElements[0].id)
        XCTAssertEqual(cue.audioElements[0].outputStartChannel, 64)
        XCTAssertTrue(cue.audioElements[0].muted)
        XCTAssertEqual(cue.audioElements[0].pan, -0.4)
        XCTAssertFalse(cue.audioElements[0].sendToMonitor)
        XCTAssertTrue(cue.loop)
        XCTAssertTrue(cue.hasTimecode)
        XCTAssertEqual(cue.durationSeconds, 3)
        XCTAssertEqual(show.cueLists[0].cues[0].audioElements[0].sourcePath, "/old.wav")
    }

    func testNewCueDoesNotReplaceOriginalAndRejectsSecondApplication() throws {
        let (show, url, data) = try fixture(mode: "newCue")
        let packet = try SculptBridgeReturn.decode(data, at: url)
        let updated = try SculptBridgeReturn.applying(packet, to: show)
        XCTAssertEqual(updated.cueLists[0].cues.count, 2)
        XCTAssertEqual(updated.cueLists[0].cues[0], show.cueLists[0].cues[0])
        XCTAssertThrowsError(try SculptBridgeReturn.applying(packet, to: updated))
    }

    func testStaleCueAndWrongListAreRejectedAtomically() throws {
        let (show, url, data) = try fixture()
        let packet = try SculptBridgeReturn.decode(data, at: url)
        var changed = show
        changed.cueLists[0].cues[0].markers[0].positionSeconds = 2
        XCTAssertThrowsError(try SculptBridgeReturn.applying(packet, to: changed))
        XCTAssertThrowsError(try SculptBridgeReturn.applying(packet, to: Show()))
        // Changes to Show-only controls may coexist with the edit.
        changed = show
        changed.cueLists[0].cues[0].gain = 0.5
        XCTAssertEqual(try SculptBridgeReturn.applying(packet, to: changed).cueLists[0].cues[0].gain, 0.5)
    }

    func testStandalonePublicationRequiresAnExplicitSelectedList() throws {
        let (show, url, data) = try fixture(mode: "newCue")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["targetSelection"] = true
        json["cueListID"] = UUID().uuidString
        let packet = try SculptBridgeReturn.decode(JSONSerialization.data(withJSONObject: json), at: url)
        XCTAssertThrowsError(try SculptBridgeReturn.applying(packet, to: show))
        let next = try SculptBridgeReturn.applying(packet, to: show, destinationListID: show.cueLists[0].id)
        XCTAssertEqual(next.cueLists[0].cues.count, 2)
    }

    func testSaveAndReopenAllowsAnotherUpdateButRejectsChangedAudio() throws {
        var (show, url, data) = try fixture()
        let audio = url.deletingLastPathComponent().appendingPathComponent("Audio/mono.wav")
        show.cueLists[0].cues[0].elements[0].sourcePath = audio.path
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["originCue"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(show.cueLists[0].cues[0]))
        data = try JSONSerialization.data(withJSONObject: json)
        let packet = try SculptBridgeReturn.decode(data, at: url)
        let applied = try SculptBridgeReturn.applying(packet, to: show)
        let saved = try ShowProjectPackage.create(applied, requestedDocumentURL: url.deletingLastPathComponent().appendingPathComponent("Saved.scshow"))
        let stored = try ShowCodec.decode(Data(contentsOf: saved.documentURL))
        let reopened = try ShowProjectPackage.resolve(stored, documentURL: saved.documentURL)
        let snapshot = applied.cueLists[0].cues[0]
        let packagedCue = reopened.cueLists[0].cues[0]
        XCTAssertNotEqual(packagedCue.audioElements[0].sourcePath, snapshot.audioElements[0].sourcePath)
        XCTAssertTrue(SculptBridgeReturn.matchesSnapshot(packagedCue, snapshot))
        // The next DAW packet carries the acknowledged pre-save snapshot.
        json["originCue"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        json["publicationID"] = UUID().uuidString
        let next = try SculptBridgeReturn.decode(JSONSerialization.data(withJSONObject: json), at: url)
        XCTAssertNoThrow(try SculptBridgeReturn.applying(next, to: reopened))
        try Data([9, 8, 7]).write(to: URL(fileURLWithPath: packagedCue.audioElements[0].sourcePath))
        XCTAssertFalse(SculptBridgeReturn.matchesSnapshot(packagedCue, snapshot))
        XCTAssertThrowsError(try SculptBridgeReturn.applying(next, to: reopened))
    }

    func testWrongVersionUnsafePathsAndInvalidOutputsAreRejected() throws {
        let (_, url, data) = try fixture()
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var json = source
        json["version"] = 2
        XCTAssertThrowsError(try SculptBridgeReturn.decode(JSONSerialization.data(withJSONObject: json), at: url))
        for (key, value) in [("sourcePath", "/etc/passwd" as Any), ("outputStartChannel", 65 as Any)] {
            json = source
            var stems = try XCTUnwrap(json["stems"] as? [[String: Any]])
            stems[0][key] = value
            json["stems"] = stems
            XCTAssertThrowsError(try SculptBridgeReturn.decode(JSONSerialization.data(withJSONObject: json), at: url))
        }
        json = source
        json["publicationID"] = "invalid"
        XCTAssertThrowsError(try SculptBridgeReturn.decode(JSONSerialization.data(withJSONObject: json), at: url))
    }
}
