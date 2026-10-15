import XCTest
@testable import SculptShowCore

final class StemPlaybackTests: XCTestCase {
    func testAlignedMultitrackIgnoresLegacyOffsetAndTrims() throws {
        var cue = Cue(name: "Playback", durationSeconds: 40)
        let first = CueElement(kind: .audio, name: "Kick", sourcePath: "/tmp/kick.wav",
                               startSeconds: 4, inSeconds: 3, outSeconds: 15,
                               gain: 0.6, muted: true)
        let second = CueElement(kind: .audio, name: "Bass", sourcePath: "/tmp/bass.wav",
                                startSeconds: 1.5, inSeconds: 2, outSeconds: 17,
                                gain: 0.8)
        cue.elements = [first, second]
        let aligned = cue.alignedAudioElements
        XCTAssertEqual(aligned.count, 2)
        for track in aligned {
            XCTAssertEqual(track.startSeconds, 0)
            XCTAssertEqual(track.inSeconds, 0)
            XCTAssertNil(track.outSeconds)
        }
        XCTAssertEqual(aligned[0].id, first.id)
        XCTAssertEqual(aligned[1].gain, 0.8)
        XCTAssertTrue(aligned[0].muted)
        // Data remains readable and lossless for previously saved projects.
        XCTAssertEqual(cue.elements[0].inSeconds, 3)
        XCTAssertEqual(cue.elements[0].startSeconds, 4)
    }

    func testSingleAudioUsesContainerTimelineWithoutHiddenTrim() {
        var cue = Cue(name: "Solo", mediaPath: "/tmp/solo.wav",
                      inPointSeconds: 4, outPointSeconds: 8, durationSeconds: 10)
        cue.elements[0].startSeconds = 2
        let audio = cue.alignedAudioElements[0]
        XCTAssertEqual(audio.startSeconds, 0)
        XCTAssertEqual(audio.inSeconds, 0)
        XCTAssertNil(audio.outSeconds)
        XCTAssertEqual(cue.durationSeconds, 10)
    }

    func testTimecodeOffsetRemainsIndependent() {
        var cue = Cue(name: "Mixed")
        var tc = CueElement.timecode()
        tc.startSeconds = 12
        cue.elements = [CueElement.audio(URL(fileURLWithPath: "/tmp/track.wav")), tc]
        XCTAssertEqual(cue.alignedAudioElements.count, 1)
        XCTAssertEqual(cue.elements[1].startSeconds, 12)
    }

    func testDocumentDecoderReadsSavedFileURL() throws {
        var show = Show(name: "Finder open – prova")
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let cue = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(cue, in: list) { $0.durationSeconds = 90.250 }
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }
        let url = tempFolder.appendingPathComponent("Prova concerto.scshow")
        try ShowCodec.encode(show).write(to: url)
        let restored = try ShowCodec.decode(contentsOf: url)
        XCTAssertEqual(restored, show)
        XCTAssertEqual(restored.cue(cue)?.durationSeconds, 90.250)
    }

    func testDocumentDecoderRejectsInvalidContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scshow")
        try Data("not a Sculpt Show".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ShowCodec.decode(contentsOf: url))
    }
}
