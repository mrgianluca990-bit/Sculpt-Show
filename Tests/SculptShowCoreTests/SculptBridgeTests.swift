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
        let script = try SculptBridge.dawImportScript(manifest, sampleRate: 48000,
                                                     destination: "/tmp/Cue A.scdaw")
        let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(commands.count, 3)
        for row in commands {
            let bits = row.split(separator: " ", maxSplits: 1)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(bits[1].utf8)) as? [String: Any])
        }
        let importLine = try XCTUnwrap(commands.first(where: { $0.hasPrefix("file.import_audio ") }))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(importLine.dropFirst("file.import_audio ".count).utf8)) as? [String: Any])
        XCTAssertEqual((json["paths"] as? [String])?.count, 2)
        XCTAssertEqual((json["at"] as? [String: Int])?["seconds"], 0)
        XCTAssertThrowsError(try SculptBridge.dawImportScript(manifest, sampleRate: 0, destination: "bad"))
    }

    func testBridgeRejectsWrongCueAndEmptyAudio() throws {
        let (show, list, _) = try makeShow()
        XCTAssertThrowsError(try SculptBridge.manifest(show: show, listID: list, cueID: UUID()))
        var empty = Show()
        let listID = try XCTUnwrap(empty.cueLists.first?.id)
        let cueID = try XCTUnwrap(empty.addEmptyCue(to: listID))
        XCTAssertThrowsError(try SculptBridge.manifest(show: empty, listID: listID, cueID: cueID))
    }
}
