import XCTest
@testable import SculptShowCore

final class AudioRoutePlanTests: XCTestCase {
    func testMonoRouteToChannel8() {
        XCTAssertEqual(AudioRoutePlan.crosspoints(firstOutput: 8, sourceChannels: 1, deviceChannels: 16),
                       [.init(sourceChannel: 0, deviceChannel: 7)])
    }
    func testStereoRouteToPair15And16() {
        XCTAssertEqual(AudioRoutePlan.crosspoints(firstOutput: 15, sourceChannels: 2, deviceChannels: 16),
                       [.init(sourceChannel: 0, deviceChannel: 14), .init(sourceChannel: 1, deviceChannel: 15)])
    }
    func testInvalidStereoRouteFailsInsteadOfMisrouting() {
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 16, sourceChannels: 2, deviceChannels: 16))
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 1, sourceChannels: 2, deviceChannels: 1))
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 0, sourceChannels: 1, deviceChannels: 8))
    }
    func testChannel64AndTooManyChannels() {
        XCTAssertEqual(AudioRoutePlan.crosspoints(firstOutput: 64, sourceChannels: 1, deviceChannels: 64), [.init(sourceChannel: 0, deviceChannel: 63)])
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 64, sourceChannels: 2, deviceChannels: 64))
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 1, sourceChannels: 3, deviceChannels: 64))
    }
    func testRoutesSurviveProjectRoundTrip() throws {
        var show = Show()
        let listID = try XCTUnwrap(show.cueLists.first?.id)
        let cueID = try XCTUnwrap(show.addAudio([URL(fileURLWithPath: "/tmp/demo.wav")], to: listID).first)
        show.updateCue(cueID, in: listID) { $0.elements[0].outputStartChannel = 29 }
        let reopened = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(reopened.cue(cueID)?.audioElements.first?.outputStartChannel, 29)
    }
    func testOldProjectDefaultsToChannelOne() throws {
        let original = CueElement.audio(URL(fileURLWithPath: "/tmp/legacy.wav"))
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        dict.removeValue(forKey: "outputStartChannel")
        let legacy = try JSONDecoder().decode(CueElement.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(legacy.outputStartChannel, 1)
    }
    func testIndependentElementRoutes() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: list))
        XCTAssertTrue(show.appendAudio([URL(fileURLWithPath: "/tmp/a.wav"),URL(fileURLWithPath: "/tmp/b.wav")],to: id))
        show.updateCue(id, in: list) { $0.elements[0].outputStartChannel = 3; $0.elements[1].outputStartChannel = 7 }
        XCTAssertEqual(show.cue(id)?.audioElements.map(\.outputStartChannel), [3,7])
    }
}
