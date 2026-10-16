import Foundation
import XCTest
@testable import SculptShowCore

final class SculptBridgeTests: XCTestCase {
    private func makeShow() throws -> (Show, UUID, UUID) {
        var show = Show(name: "Production")
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(id, in: list) { cue in
            cue.name = "Cue \"A\""
            cue.elements = [CueElement(kind: .audio, name: "L/R", sourcePath: "/tmp/audio \"1\".wav", outputStartChannel: 5),
                            CueElement(kind: .audio, name: "FX", sourcePath: "/tmp/fx.wav", outputStartChannel: 7),
                            CueElement.timecode()]
            cue.markers = [CueMarker(name: "Outro", positionSeconds: 8), CueMarker(name: "Intro", positionSeconds: 2)]
            cue.durationSeconds = 12.5
        }
        return (show, list, id)
    }

    func testCueManifestRoundtripIncludesIdentityAndTiming() throws {
        let (show, list, id) = try makeShow()
        let value = try SculptBridge.manifest(show: show, listID: list, cueID: id)
        XCTAssertEqual(value.format, SculptBridge.format)
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.cueID, id)
        XCTAssertEqual(value.stems.count, 2)
        XCTAssertEqual(value.stems[0].outputStartChannel, 5)
        XCTAssertEqual(value.markers.map(\.name), ["Intro", "Outro"])
        XCTAssertNotNil(value.timecode)
        let encoded = try SculptBridge.encode(value)
        let decoded = try JSONDecoder().decode(SculptBridge.Manifest.self, from: encoded)
        XCTAssertEqual(value, decoded)
    }

    func testDAWImportCommandsAlignedToZeroAndSafelyEscaped() throws {
        let (show, list, id) = try makeShow()
        let manifest = try SculptBridge.manifest(show: show, listID: list, cueID: id)
        let counts = [manifest.stems[0].elementID: 2, manifest.stems[1].elementID: 1]
        let script = try SculptBridge.dawImportScript(manifest, sampleRate: 48000,
                                                     destination: "/tmp/Cue A.scdaw",
                                                     channelCounts: counts)
        let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(commands.filter { $0.hasPrefix("file.import_audio ") }.count, 2)
        XCTAssertEqual(commands.filter { $0.hasPrefix("track.rename ") }.count, 2)
        XCTAssertEqual(commands.filter { $0.hasPrefix("track.comments ") }.count, 2)
        XCTAssertEqual(commands.filter { $0.hasPrefix("track.output ") }.count, 0)
        XCTAssertEqual(commands.filter { $0.hasPrefix("setup.io ") }.count, 2)
        XCTAssertEqual(commands.filter { $0.hasPrefix("markers.add ") }.count, 2)
        XCTAssertEqual(commands.count, 13)
        for row in commands {
            let bits = row.split(separator: " ", maxSplits: 1)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(bits[1].utf8)) as? [String: Any])
        }
        let importLine = try XCTUnwrap(commands.first(where: { $0.hasPrefix("file.import_audio ") }))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(importLine.dropFirst("file.import_audio ".count).utf8)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, manifest.stems[0].sourcePath)
        XCTAssertEqual((json["at"] as? [String: Int])?["seconds"], 0)
        let routes = commands.filter { $0.hasPrefix("track.comments ") }.map(String.init)
        XCTAssertTrue(routes[0].contains("SCULPT HW STEREO 05-06"))
        XCTAssertTrue(routes[1].contains("SCULPT HW MONO 07"))
        XCTAssertTrue(routes[0].contains("DAW monitoring uses Main"))
        XCTAssertTrue(script.contains("\"first_channel\":4"))
        XCTAssertTrue(script.contains("\"first_channel\":6"))
        XCTAssertThrowsError(try SculptBridge.dawImportScript(manifest, sampleRate: 0, destination: "bad", channelCounts: counts))
        XCTAssertThrowsError(try SculptBridge.dawImportScript(manifest, sampleRate: 44100, destination: "bad", channelCounts: [:]))
    }

    func testPhysicalRoutingAndMarkersSurviveMultipleStemNames() throws {
        let (show, list, id) = try makeShow()
        let manifest = try SculptBridge.manifest(show: show, listID: list, cueID: id)
        let counts = [manifest.stems[0].elementID: 1, manifest.stems[1].elementID: 1]
        let script = try SculptBridge.dawImportScript(manifest, sampleRate: 44100,
                                                     destination: "/tmp/show.scraft", channelCounts: counts)
        let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let outputLines = commands.filter { $0.hasPrefix("setup.io ") }
        XCTAssertEqual(outputLines.count, 2)
        XCTAssertTrue(outputLines[0].contains("SCULPT HW MONO 05"))
        let marks = commands.filter { $0.hasPrefix("markers.add ") }
        XCTAssertEqual(marks.count, 2)
        XCTAssertTrue(marks[0].contains("\"seconds\":2"))
        XCTAssertTrue(marks[1].contains("\"seconds\":8"))
        XCTAssertTrue(script.contains("track.rename"))
        XCTAssertTrue(script.contains("session.save"))
    }

    func testBridgeRejectsWrongCueAndEmptyAudio() throws {
        let (show, list, _) = try makeShow()
        XCTAssertThrowsError(try SculptBridge.manifest(show: show, listID: list, cueID: UUID()))
        var empty = Show()
        let listID = try XCTUnwrap(empty.cueLists.first?.id)
        let cueID = try XCTUnwrap(empty.addEmptyCue(to: listID))
        XCTAssertThrowsError(try SculptBridge.manifest(show: empty, listID: listID, cueID: cueID))
    }

    func testBridgeWorkspaceFilenameIsSafeAndDeterministic() {
        XCTAssertEqual(SculptBridge.safeFilename("  Scene/42: LX\\Q?  "), "Scene-42- LX-Q")
        XCTAssertEqual(SculptBridge.safeFilename("../\\"), "Untitled Cue")
        XCTAssertEqual(SculptBridge.safeFilename(" \n "), "Untitled Cue")
        XCTAssertEqual(SculptBridge.safeFilename(String(repeating: "z", count: 100)).count, 70)
    }

    func testNativeSculptDAWSessionScriptHasExplicitOrigin() throws {
        let (show, list, id) = try makeShow()
        let manifest = try SculptBridge.manifest(show: show, listID: list, cueID: id)
        let destination = "/tmp/Sculpt Bridge/Cue A.scraft"
        let counts = [manifest.stems[0].elementID: 2, manifest.stems[1].elementID: 1]
        let script = try SculptBridge.dawImportScript(manifest, sampleRate: 44100,
                                                     destination: destination, channelCounts: counts)
        let saveLine = try XCTUnwrap(script.split(separator: "\n").first(where: { $0.hasPrefix("session.save ") }))
        let save = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(saveLine.dropFirst("session.save ".count).utf8)) as? [String: Any])
        XCTAssertEqual(save["path"] as? String, destination)
        XCTAssertEqual(save["replace"] as? Bool, false)
        XCTAssertTrue(script.contains("\"seconds\":0"))
    }

}
