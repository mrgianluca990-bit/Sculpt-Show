import XCTest
@testable import SculptShowCore

final class CueControlMessageTests: XCTestCase {
    private func tc(_ text: String, _ rate: LTCFrameRate = .fps25) -> LTCTimecode { LTCTimecode(text: text, rate: rate)! }
    private func show(_ address: String = "00:00:01:00", rate: LTCFrameRate = .fps25) -> Show {
        var cue = Cue(name: "TC"); cue.triggers.timecode = .init(address: address, rate: rate)
        var show = Show(); show.cueLists[0].cues = [cue]; return show
    }
    func testCrossedFramesAndNoDuplicateWhileHolding() {
        let show = show(); let id = show.cueLists[0].cues[0].id; var scheduler = TimecodeCueScheduler()
        XCTAssertEqual(scheduler.consume(tc("00:00:00:24"), at: 0, in: show), [])
        XCTAssertEqual(scheduler.consume(tc("00:00:01:01"), at: 0.08, in: show), [id])
        XCTAssertEqual(scheduler.consume(tc("00:00:01:01"), at: 0.1, in: show), [])
        XCTAssertEqual(scheduler.consume(tc("00:00:01:02"), at: 0.12, in: show), [])
    }
    func testLocateBackwardsLossAndRearm() {
        let show = show(); let id = show.cueLists[0].cues[0].id; var scheduler = TimecodeCueScheduler()
        _ = scheduler.consume(tc("00:00:00:00"), at: 0, in: show)
        XCTAssertEqual(scheduler.consume(tc("00:00:02:00"), at: 0.08, in: show), [])
        XCTAssertEqual(scheduler.consume(tc("00:00:00:24"), at: 0.12, in: show), [])
        XCTAssertEqual(scheduler.consume(tc("00:00:01:00"), at: 0.16, in: show), [id])
        scheduler.reset()
        _ = scheduler.consume(tc("00:00:00:24"), at: 1, in: show)
        XCTAssertEqual(scheduler.consume(tc("00:00:01:02"), at: 2, in: show), [])
        scheduler.reset(); XCTAssertEqual(scheduler.consume(tc("00:00:01:00"), at: 3, in: show), [id])
    }
    func testMidnightDropFrameDisabledAndSameAddressMultipleCues() {
        var show = show("00:00:00:00", rate: .fps2997DF)
        var second = show.cueLists[0].cues[0]; second.id = UUID(); show.cueLists[0].cues.append(second)
        var scheduler = TimecodeCueScheduler()
        _ = scheduler.consume(tc("23:59:59;29", .fps2997DF), at: 0, in: show)
        XCTAssertEqual(scheduler.consume(tc("00:00:00;01", .fps2997DF), at: 0.06, in: show).count, 2)
        scheduler.reset(); show.cueLists[0].cues[0].enabled = false
        XCTAssertEqual(scheduler.consume(tc("00:00:00:00", .fps25), at: 1, in: show), [])
        XCTAssertEqual(scheduler.consume(tc("00:00:00;00", .fps2997DF), at: 1.1, in: show), [second.id])
    }
    func testMIDIPacketFormatsAndValidation() {
        var m = CueMIDIMessage(destination: 1, status: 0x90, channel: 15, number: 60, value: 100)
        XCTAssertEqual(m.bytes, [0x9f,60,100]); m.status = 0x80; XCTAssertEqual(m.bytes,[0x8f,60,100])
        m.status = 0xC0; XCTAssertEqual(m.bytes,[0xcf,60]); m.channel = 16; XCTAssertFalse(m.isValid); XCTAssertEqual(m.bytes, [])
        m.channel = 0; m.destination = 0; XCTAssertFalse(m.isValid)
    }
    func testOSCWireEncoding() {
        var m = CueOSCMessage(); m.address = "/sculpt/go"
        XCTAssertEqual(try OSCControlPacket.decode(XCTUnwrap(m.packet)), [.global("go")])
        m.argument = .integer; m.value = "1"
        XCTAssertEqual(try OSCControlPacket.decode(XCTUnwrap(m.packet)), [.global("go")])
        m.argument = .float; m.value = "0"
        XCTAssertEqual(try OSCControlPacket.decode(XCTUnwrap(m.packet)), [])
        m.argument = .string; m.value = "hello"
        XCTAssertEqual(m.packet?.suffix(8), Data([104,101,108,108,111,0,0,0]))
    }
    func testInvalidOSCAndMessageLimits() {
        for host in ["localhost", "1.2.3.999", "", "::1"] { var m = CueOSCMessage(); m.host = host; XCTAssertFalse(m.isValid) }
        var m = CueOSCMessage(); m.address = "/wild*"; XCTAssertNil(m.packet)
        m.address = "/cue"; m.argument = .float; m.value = "nan"; XCTAssertNil(m.packet)
        m.argument = .integer; m.value = "2147483648"; XCTAssertNil(m.packet)
        var t = CueTriggers(); t.oscMessages = Array(repeating: CueOSCMessage(), count: 17); XCTAssertNotNil(t.validationError)
        t.oscMessages = nil; t.timecode = .init(address: "00:01:00;00", rate: .fps2997DF); XCTAssertNotNil(t.validationError)
    }
    func testLegacyDecodingRoundTripAndDuplicateOutputs() throws {
        let legacy = Data("{\"oscEnabled\":true,\"oscAlias\":\"\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(CueTriggers.self, from: legacy), CueTriggers())
        var show = show(); show.cueLists[0].cues[0].triggers.midiMessages = [.init(destination: 123)]
        show.cueLists[0].cues[0].triggers.oscMessages = [CueOSCMessage()]
        XCTAssertEqual(try JSONDecoder().decode(Show.self, from: JSONEncoder().encode(show)), show)
        let original = show.cueLists[0].cues[0]
        let copy = try XCTUnwrap(show.duplicateCue(original.id, in: show.cueLists[0].id))
        XCTAssertNil(show.cue(copy)?.triggers.timecode)
        XCTAssertEqual(show.cue(copy)?.triggers.oscMessages, original.triggers.oscMessages)
    }
    func testCropMaskChangesWithoutDistortion() {
        var m = CueVideo(sourcePath: "video", duration: 1); m.framing = .fill; m.widthScale = 0.5; m.heightScale = 0.7
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(m.viewportFrame(in: canvas).width, 960)
        let content = m.contentFrame(source: CGSize(width: 1920, height: 1080), in: canvas)
        XCTAssertEqual(content.width / content.height, 16.0 / 9, accuracy: 0.0001)
    }
}
