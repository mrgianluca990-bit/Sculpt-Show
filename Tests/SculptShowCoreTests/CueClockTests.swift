import XCTest
@testable import SculptShowCore

final class CueClockTests: XCTestCase {
    func testCueTimeIsHoursMinutesSecondsMilliseconds() {
        XCTAssertEqual(CueClock.format(90.25), "00:01:30:250")
        XCTAssertEqual(CueClock.parse("00:01:30:250"), 90.25)
        XCTAssertEqual(CueClock.parse("02:03:04:005"), 7384.005)
        XCTAssertEqual(CueClock.format(7384.005), "02:03:04:005")
        XCTAssertEqual(CueClock.format(86400), "24:00:00:000")
    }

    func testCueTimeRejectsInvalidAndOutOfRange() {
        for text in ["0:1:30:250", "00:00:00:1", "00:60:00:000", "00:00:60:000",
                     "24:00:00:001", "99:00:00:000", "00:01:00:1000", "hello", ""] {
            XCTAssertNil(CueClock.parse(text), "Unexpected valid time: \(text)")
        }
        XCTAssertEqual(CueClock.parse(" 00:00:00:001 "), 0.001)
    }

    func testMTCDecoderReads24FPSFrame() throws {
        var reader = MTCDecoder()
        // 01:02:03:04, 24 fps
        let payload: [UInt8] = [0x04, 0x10, 0x23, 0x30, 0x42, 0x50, 0x61, 0x70]
        for index in 0..<7 { XCTAssertNil(reader.ingestQuarterFrame(payload[index])) }
        let frame = try XCTUnwrap(reader.ingestQuarterFrame(payload[7]))
        XCTAssertEqual(frame.display, "01:02:03:04")
        XCTAssertEqual(frame.nominalFPS, 24)
        XCTAssertFalse(frame.dropFrame)
    }

    func testMTCDecoderReadsDropFrameMode() throws {
        var reader = MTCDecoder()
        // 01:00:00;12, 29.97 DF nominal frames 30.
        let payload: [UInt8] = [0x0C, 0x10, 0x20, 0x30, 0x40, 0x50, 0x61, 0x74]
        var value: MTCFrame?
        for byte in payload { value = reader.ingestQuarterFrame(byte) }
        let frame = try XCTUnwrap(value)
        XCTAssertEqual(frame.display, "01:00:00;12")
        XCTAssertEqual(frame.nominalFPS, 30)
        XCTAssertTrue(frame.dropFrame)
    }

    func testMTCInvalidStreamDoesNotProduceFalseLock() {
        var reader = MTCDecoder()
        for item in [UInt8(0x00), 0x10, 0x30, 0x40, 0x50, 0x60, 0x70] {
            XCTAssertNil(reader.ingestQuarterFrame(item))
        }
    }

    func testRelocateCueBetweenListsKeepsContentsRulesAndTiming() throws {
        var show = Show()
        let source = try XCTUnwrap(show.cueLists.first?.id)
        let destination = show.addList(name: "Effects")
        let id = try XCTUnwrap(show.addEmptyCue(to: source))
        let audioID = UUID()
        let ruleID = UUID()
        show.updateCue(id, in: source) { cue in
            cue.name = "A special cue"
            cue.durationSeconds = 123.456
            cue.elements.append(CueElement(id: audioID, kind: .audio, name: "ambience", sourcePath: "/tmp/ambient.wav"))
            cue.rules.append(InteractionRule(id: ruleID, event: .ending, action: .fire, target: .nextCue))
        }
        XCTAssertTrue(show.relocateCue(id, to: destination))
        XCTAssertNil(show.cueLists[0].cues.first(where: { $0.id == id }))
        let moved = try XCTUnwrap(show.cueLists[1].cues.first)
        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.elements.first?.id, audioID)
        XCTAssertEqual(moved.rules.first?.id, ruleID)
        XCTAssertEqual(moved.durationSeconds, 123.456)
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
        XCTAssertEqual(RulePlanner.effectiveRules(for: id, in: show).map(\.id), [ruleID])
    }

    func testReorderWithinListPersists() throws {
        var show = Show()
        let id = try XCTUnwrap(show.cueLists.first?.id)
        let a = try XCTUnwrap(show.addEmptyCue(to: id))
        let b = try XCTUnwrap(show.addEmptyCue(to: id))
        let c = try XCTUnwrap(show.addEmptyCue(to: id))
        XCTAssertTrue(show.relocateCue(a, to: id, before: c))
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [b, a, c])
        XCTAssertTrue(show.relocateCue(a, to: id))
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [b, c, a])
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }
}
