import XCTest
@testable import SculptShowCore

final class MonitorMixerTests: XCTestCase {
    private func monitor(left: Int = 5, right: Int = 6) -> ShowMonitorSettings {
        var m = ShowMonitorSettings(); m.enabled = true; m.deviceUID = "test-interface"
        m.leftOutput = left; m.rightOutput = right
        return m
    }
    private func points(first: Int = 1, channels: Int = 1) throws -> [AudioRoutePlan.Crosspoint] {
        try XCTUnwrap(AudioRoutePlan.crosspoints(firstOutput: first, sourceChannels: channels, deviceChannels: 8))
    }
    func testLegacyDefaultsPreserveProgramAndAutomaticallySendWhenActivated() throws {
        var show = Show(cueLists: [CueList(name: "List", cues: [Cue(name: "Audio", mediaPath: "/tmp/test.wav")])])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ShowCodec.encode(show)) as? [String: Any])
        json.removeValue(forKey: "monitor")
        let legacy = try ShowCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.monitor.enabled)
        XCTAssertEqual(legacy.cueLists[0].cues[0].audioElements[0].pan, 0)
        XCTAssertTrue(legacy.cueLists[0].cues[0].audioElements[0].sendToMonitor)
        show.monitor = monitor(); show.monitor.pan = -0.3; show.monitor.gain = 0.45
        show.cueLists[0].cues[0].elements[0].pan = 0.7
        show.cueLists[0].cues[0].elements[0].sendToMonitor = false
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }
    func testAutomaticProgramSkipsMonitorWithoutFixedStereoPairs() throws {
        let m = monitor(left: 2, right: 4)
        let reserved = m.reservedOutputs(deviceUID: "test-interface", channels: 6)
        let patch = ShowOutputPatch()
        let mono = try patch.crosspoints(firstOutput: 1, sourceChannels: 1, deviceUID: "test-interface", deviceChannels: 6, excluding: reserved)
        let stereo = try patch.crosspoints(firstOutput: 2, sourceChannels: 2, deviceUID: "test-interface", deviceChannels: 6, excluding: reserved)
        XCTAssertEqual(mono.map(\.deviceChannel), [0])
        XCTAssertEqual(stereo.map(\.deviceChannel), [2, 4])
        let wrapped = try patch.crosspoints(firstOutput: 5, sourceChannels: 1, deviceUID: "test-interface", deviceChannels: 6, excluding: reserved)
        XCTAssertEqual(wrapped.map(\.deviceChannel), [0])
    }
    func testMonitorOnlyDoesNotDuplicateProgramOnSamePhysicalOutputs() throws {
        let patch = ShowOutputPatch()
        let m = monitor(left: 1, right: 2)
        let program = try patch.crosspoints(firstOutput: 1, sourceChannels: 2, deviceUID: "test-interface", deviceChannels: 2, excluding: m.reservedOutputs(deviceUID: "test-interface", channels: 2))
        XCTAssertTrue(program.isEmpty)
        let gains = MonitorMixPlan.gains(channels: 2, program: program, pan: 0, send: true, monitor: m)
        XCTAssertEqual(gains, [.init(source: 0, output: 0, value: 1), .init(source: 1, output: 1, value: 1)])
    }
    func testCustomRoutesCannotFeedReservedMonitorOutputs() throws {
        var patch = ShowOutputPatch()
        patch.setProfile(.init(deviceUID: "test-interface", deviceName: "Device", automatic: false,
            outputs: [2, 4] + Array(repeating: nil, count: 62)))
        XCTAssertThrowsError(try patch.crosspoints(firstOutput: 1, sourceChannels: 2, deviceUID: "test-interface", deviceChannels: 6, excluding: [2, 4]))
        XCTAssertEqual(try patch.crosspoints(firstOutput: 1, sourceChannels: 2, deviceUID: "test-interface", deviceChannels: 6).map(\.deviceChannel), [1, 3])
    }
    func testMonitorAvailabilityUsesUIDAndRejectsDuplicatePair() throws {
        var m = monitor(left: 2, right: 4)
        XCTAssertTrue(m.isAvailable(deviceUID: "test-interface", channels: 4))
        XCTAssertFalse(m.isAvailable(deviceUID: "other-interface", channels: 4))
        XCTAssertFalse(m.isAvailable(deviceUID: "test-interface", channels: 2))
        XCTAssertEqual(m.reservedOutputs(deviceUID: "other-interface", channels: 8), [])
        m.leftOutput = 4
        XCTAssertThrowsError(try m.validate())
    }
    func testMonoPanAffectsMonitorButPreservesDirectMonoOutput() throws {
        let p = try points()
        let centered = MonitorMixPlan.gains(channels: 1, program: p, pan: 0, send: true, monitor: monitor())
        XCTAssertEqual(centered[0], .init(source: 0, output: 0, value: 1))
        XCTAssertEqual(centered[1].value, Float(1 / sqrt(2)), accuracy: 0.00001)
        XCTAssertEqual(centered[2].value, Float(1 / sqrt(2)), accuracy: 0.00001)
        let right = MonitorMixPlan.gains(channels: 1, program: p, pan: 1, send: true, monitor: monitor())
        XCTAssertEqual(right[0].value, 1)
        XCTAssertEqual(right[1].value, 0, accuracy: 0.00001)
        XCTAssertEqual(right[2].value, 1)
    }
    func testStereoBalanceAndMonitorMasterRemainIndependent() throws {
        var m = monitor(); m.gain = 0.5; m.pan = -1
        let gains = MonitorMixPlan.gains(channels: 2, program: try points(channels: 2), pan: 0.5, send: true, monitor: m)
        XCTAssertEqual(gains.map(\.value), [0.5, 1, 0.25, 0])
        XCTAssertEqual(gains.map(\.source), [0, 1, 0, 1])
    }
    func testSendAndMonitorMuteNeverChangeProgramWeights() throws {
        let p = try points(channels: 2)
        var m = monitor()
        let noSend = MonitorMixPlan.gains(channels: 2, program: p, pan: 0, send: false, monitor: m)
        XCTAssertEqual(noSend.count, 2)
        m.muted = true
        XCTAssertEqual(MonitorMixPlan.gains(channels: 2, program: p, pan: 0, send: true, monitor: m), noSend)
    }
    func testPostFaderGainIncludesFadeMuteAndCueTrim() {
        XCTAssertEqual(AudioGainPlan.linear(cue: 0.5, element: 0.4, fade: 0.5, trim: 0.5, muted: false), 0.05, accuracy: 0.00001)
        XCTAssertEqual(AudioGainPlan.linear(cue: 0.5, element: 0.4, fade: 0.5, trim: 0.5, muted: true), 0)
    }
    func testMuteAllCanExcludeMonitorAndRestoreIndividualMutes() {
        var controls = OutputMuteSoloState(channelCount: 8)
        controls.toggleMute(3)
        controls.setSoloExempt([7, 8])
        controls.setAllMuted(true, excluding: [7, 8])
        XCTAssertFalse(controls.isAudible(1)); XCTAssertTrue(controls.isAudible(7)); XCTAssertTrue(controls.isAudible(8))
        controls.setAllMuted(true, excluding: [])
        XCTAssertFalse(controls.isAudible(7))
        controls.setAllMuted(false, excluding: [7, 8])
        XCTAssertTrue(controls.isAudible(1)); XCTAssertFalse(controls.isAudible(3))
        controls.toggleSolo(1)
        XCTAssertTrue(controls.isAudible(7)); XCTAssertFalse(controls.isAudible(2))
        controls.toggleMute(7)
        XCTAssertFalse(controls.isAudible(7))
        controls.clear()
        XCTAssertTrue((1...8).allSatisfy(controls.isAudible))
    }
    func testPreflightReportsWrongDeviceAndLTCMonitorCollision() {
        var cue = Cue(name: "Audio", mediaPath: "/tmp/test.wav")
        var tc = CueElement.timecode(); tc.ltcOutputChannel = 5; cue.elements.append(tc)
        var show = Show(cueLists: [CueList(name: "List", cues: [cue])]); show.monitor = monitor()
        let media = ["/tmp/test.wav": PreflightAudioInfo(channelCount: 1, duration: 5, sampleRate: 48000)]
        var report = ShowPreflight.check(show, outputChannels: 8, media: media, deviceUID: "test-interface")
        XCTAssertTrue(report.issues.contains { $0.code == "ltc-monitor-collision" })
        report = ShowPreflight.check(show, outputChannels: 8, media: media, deviceUID: "other-interface")
        XCTAssertTrue(report.issues.contains { $0.code == "monitor-unavailable" })
    }
}
