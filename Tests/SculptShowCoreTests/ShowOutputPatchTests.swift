import XCTest
@testable import SculptShowCore

final class ShowOutputPatchTests: XCTestCase {
    private func patch(_ outputs: [Int?], uid: String = "interface-A") -> ShowOutputPatch {
        var patch = ShowOutputPatch()
        patch.setProfile(.init(deviceUID: uid, deviceName: "Device", automatic: false,
            outputs: outputs + Array(repeating: nil, count: 64 - outputs.count)))
        return patch
    }
    private func destinations(_ patch: ShowOutputPatch, first: Int = 1, channels: Int = 1,
                              uid: String = "interface-A", capacity: Int = 8) throws -> [Int] {
        try patch.crosspoints(firstOutput: first, sourceChannels: channels,
            deviceUID: uid, deviceChannels: capacity).map { $0.deviceChannel + 1 }
    }
    func testLegacyShowWithoutPatchRetainsCyclicRouting() throws {
        let data = try JSONEncoder().encode(Show())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "outputPatch")
        let legacy = try JSONDecoder().decode(Show.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.outputPatch, ShowOutputPatch())
        for (first, expected) in [(1, 1), (2, 2), (3, 1), (4, 2)] {
            XCTAssertEqual(try destinations(legacy.outputPatch, first: first, capacity: 2), [expected])
        }
        XCTAssertEqual(try destinations(legacy.outputPatch, first: 64, channels: 2, capacity: 2), [1, 2])
    }
    func testDeviceUIDSelectsPatchAndNotDisplayNameOrNumericID() throws {
        var p = patch([5, 6])
        p.setProfile(.init(deviceUID: "interface-B", deviceName: "Device", automatic: false,
            outputs: [1, 2] + Array(repeating: nil, count: 62)))
        XCTAssertEqual(try destinations(p, channels: 2), [5, 6])
        XCTAssertEqual(try destinations(p, channels: 2, uid: "interface-B", capacity: 2), [1, 2])
        XCTAssertThrowsError(try destinations(p, uid: "unknown"))
        p.setProfile(.init(deviceUID: "unknown", deviceName: "Device", automatic: true,
            outputs: Array(repeating: nil, count: 64)))
        XCTAssertEqual(try destinations(p, first: 7, uid: "unknown", capacity: 2), [1])
    }
    func testCustomMappingNeverWrapsOrSilentlyReplacesMissingOutput() throws {
        let p = patch([7, 8, nil])
        XCTAssertEqual(try destinations(p, channels: 2), [7, 8])
        XCTAssertThrowsError(try destinations(p, capacity: 2))
        XCTAssertThrowsError(try destinations(p, first: 3))
        XCTAssertThrowsError(try destinations(p, first: 64, channels: 2))
    }
    func testStereoAllowsIndependentDistinctPhysicalOutputs() throws {
        XCTAssertEqual(try destinations(patch([3, 4]), channels: 2), [3, 4])
        for pair: [Int?] in [[3, 3]] {
            XCTAssertThrowsError(try destinations(patch(pair), channels: 2))
        }
        XCTAssertEqual(try destinations(patch([1, 4]), channels: 2), [1, 4])
        XCTAssertEqual(try destinations(patch([2, 1]), channels: 2), [2, 1])
        // Multiple logical mono paths may deliberately sum to one output.
        XCTAssertEqual(try destinations(patch([3, 3]), first: 2), [3])
    }
    func testNamesAndProfilesRoundTripWithoutChangingCueOrBridgeRoutes() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let cueID = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(cueID, in: list) { $0.elements.append(.audio(URL(fileURLWithPath: "/tmp/stem.wav"))) }
        let before = show.cue(cueID)
        show.outputPatch = patch([3, 4])
        show.outputPatch.rename(1, to: " Front\nLeft ")
        let decoded = try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show))
        XCTAssertEqual(decoded, show)
        XCTAssertEqual(decoded.cue(cueID), before)
        XCTAssertEqual(decoded.outputPatch.name(1), "Front Left")
        XCTAssertEqual(decoded.outputPatch.name(2), "OUT 2")
    }
    func testInvalidPersistedProfileIsRejectedInsteadOfUsingAutomaticFallback() throws {
        var show = Show()
        show.outputPatch = patch([1, 2])
        show.outputPatch.profiles[0].outputs = [1]
        XCTAssertThrowsError(try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show)))
        show.outputPatch.profiles[0].outputs = Array(repeating: 65, count: 64)
        XCTAssertThrowsError(try show.outputPatch.validate())
        show.outputPatch = patch([1, 2]); show.outputPatch.profiles.append(show.outputPatch.profiles[0])
        XCTAssertThrowsError(try show.outputPatch.validate())
    }
    func testPreflightUsesPhysicalPatchForLTCAndUnavailableRoutes() throws {
        let path = "/tmp/music.wav"
        var cue = Cue(name: "Music", mediaPath: path)
        var tc = CueElement.timecode()
        tc.ltcOutputChannel = 3
        cue.elements.append(tc)
        var show = Show(cueLists: [CueList(name: "List", cues: [cue])])
        show.outputPatch = patch([3, 4])
        let media = [path: PreflightAudioInfo(channelCount: 2, duration: 10, sampleRate: 48000)]
        var report = ShowPreflight.check(show, outputChannels: 8, media: media, deviceUID: "interface-A")
        XCTAssertTrue(report.issues.contains { $0.code == "ltc-route-collision" })
        report = ShowPreflight.check(show, outputChannels: 2, media: media, deviceUID: "interface-A")
        XCTAssertTrue(report.issues.contains { $0.code == "bad-route" && $0.severity == .blocking })
        report = ShowPreflight.check(show, outputChannels: 8, media: media, deviceUID: "unknown")
        XCTAssertTrue(report.issues.contains { $0.code == "bad-route" && $0.message.contains("another interface") })
    }
    func testProjectSaveAndReopenPreservesPatchAndDeviceProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patch-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var show = Show(name: "Patch Show")
        show.outputPatch = patch([5, 6])
        show.outputPatch.rename(1, to: "Front Left")
        let saved = try ShowProjectPackage.create(show, requestedDocumentURL: root.appendingPathComponent("Patch Show.scshow"))
        let reopened = try ShowProjectPackage.resolve(ShowCodec.decode(contentsOf: saved.documentURL), documentURL: saved.documentURL)
        XCTAssertEqual(reopened.outputPatch, show.outputPatch)
        XCTAssertEqual(try destinations(reopened.outputPatch, channels: 2), [5, 6])
    }

}
