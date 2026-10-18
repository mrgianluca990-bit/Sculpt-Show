import XCTest
@testable import SculptShowCore

final class ShowPreflightTests: XCTestCase {
    func testMissingMediaAndNoDeviceAreBlocking() {
        var show = Show()
        let id = show.cueLists[0].id
        show.addAudio([URL(fileURLWithPath: "/tmp/missing-show-test.wav")], to: id)
        let result = ShowPreflight.check(show, outputChannels: 0, media: [:])
        XCTAssertFalse(result.ready)
        XCTAssertTrue(result.issues.contains { $0.code == "media-missing" })
        XCTAssertTrue(result.issues.contains { $0.code == "no-device" })
    }

    func testStereoNeedsTwoOutputsAndMonoNeedsOne() {
        var show = Show()
        let id = show.cueLists[0].id
        show.addAudio([URL(fileURLWithPath: "/audio/stereo.wav")], to: id)
        let cueID = show.cueLists[0].cues[0].id
        show.updateCue(cueID, in: id) { $0.elements[0].outputStartChannel = 2 }
        let path = "/audio/stereo.wav"
        let stereo = PreflightAudioInfo(channelCount: 2, duration: 5, sampleRate: 48000)
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 2, media: [path: stereo]).ready)
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 3, media: [path: stereo]).ready)
        let mono = PreflightAudioInfo(channelCount: 1, duration: 5, sampleRate: 48000)
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 2, media: [path: mono]).ready)
    }

    func testUnsupportedSourceIsBlocking() {
        var show = Show()
        let id = show.cueLists[0].id
        let path = "/audio/multi.wav"
        show.addAudio([URL(fileURLWithPath: path)], to: id)
        let metadata = PreflightAudioInfo(channelCount: 6, duration: 20, sampleRate: 48000)
        let result = ShowPreflight.check(show, outputChannels: 16, media: [path: metadata])
        XCTAssertEqual(result.issues.first?.code, "source-channels")
        XCTAssertFalse(result.ready)
    }

    func testEmptyShowIsReady() {
        XCTAssertTrue(ShowPreflight.check(Show(), outputChannels: 0, media: [:]).ready)
    }
}

extension ShowPreflightTests {
    func testMarkerAfterFixedDurationIsWarningOnly() {
        var show = Show()
        let list = show.cueLists[0].id
        guard let cueID = show.addEmptyCue(to: list) else { XCTFail("Cannot create cue"); return }
        show.updateCue(cueID, in: list) { cue in
            cue.durationSeconds = 5
            cue.markers = [CueMarker(name: "Late", positionSeconds: 7)]
        }
        let report = ShowPreflight.check(show, outputChannels: 2, media: [:])
        XCTAssertTrue(report.ready)
        XCTAssertEqual(report.warningCount, 1)
        XCTAssertEqual(report.issues[0].code, "unreachable-marker")
    }

    func testRelinkPreservesElementIdentityAndRoutingAfterSave() throws {
        var show = Show()
        let list = show.cueLists[0].id
        let original = URL(fileURLWithPath: "/old/lead.wav")
        let replacement = URL(fileURLWithPath: "/new/lead.wav")
        show.addAudio([original], to: list)
        let cueID = try XCTUnwrap(show.cueLists[0].cues.first?.id)
        let elementID = try XCTUnwrap(show.cue(cueID)?.elements.first?.id)
        show.updateCue(cueID, in: list) { cue in
            cue.elements[0].outputStartChannel = 9
            cue.elements[0].gain = 0.35
            cue.elements[0].sourcePath = replacement.path
        }
        let data = try ShowCodec.encode(show)
        let decoded = try ShowCodec.decode(data)
        let element = try XCTUnwrap(decoded.cue(cueID)?.elements.first)
        XCTAssertEqual(element.id, elementID)
        XCTAssertEqual(element.sourcePath, replacement.path)
        XCTAssertEqual(element.outputStartChannel, 9)
        XCTAssertEqual(element.gain, 0.35)
    }
}

extension ShowPreflightTests {
    func testLTCRequiresDedicatedOutputAndValidSMPTE() throws {
        var show = Show()
        let list = show.cueLists[0].id
        let id = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(id, in: list) { cue in
            cue.elements.append(.timecode())
            cue.durationSeconds = 10
        }
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 16, media: [:])
            .issues.contains { $0.code == "ltc-output" })
        show.updateCue(id, in: list) { cue in
            cue.elements[0].ltcOutputChannel = 16
            cue.elements[0].frameRate = 30
            cue.elements[0].timecodeDropFrame = true
            cue.elements[0].timecodeStart = "00:01:00:00"
        }
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 16, media: [:])
            .issues.contains { $0.code == "ltc-start" })
        show.updateCue(id, in: list) { $0.elements[0].timecodeStart = "00:01:00:02" }
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 16, media: [:]).ready)
    }

    func testLTCPhysicalOutputCannotOverlapAudioStereoStem() throws {
        var show = Show()
        let list = show.cueLists[0].id
        let path = "/audio/score.wav"
        show.addAudio([URL(fileURLWithPath: path)], to: list)
        let id = try XCTUnwrap(show.cueLists[0].cues.first?.id)
        show.updateCue(id, in: list) { cue in
            cue.elements[0].outputStartChannel = 1
            var tc = CueElement.timecode()
            tc.ltcOutputChannel = 2
            cue.elements.append(tc)
        }
        let audio = PreflightAudioInfo(channelCount: 2, duration: 20, sampleRate: 48000)
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 16, media: [path: audio])
            .issues.contains { $0.code == "ltc-route-collision" })
        show.updateCue(id, in: list) { $0.elements[1].ltcOutputChannel = 16 }
        XCTAssertTrue(ShowPreflight.check(show, outputChannels: 16, media: [path: audio]).ready)
    }
}
