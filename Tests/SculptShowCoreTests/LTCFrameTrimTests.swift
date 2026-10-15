import XCTest
@testable import SculptShowCore

final class LTCFrameTrimTests: XCTestCase {
    func testSignedFrameOffsetsAcrossRates() {
        for rate in LTCFrameRate.allCases {
            XCTAssertEqual(LTCFrameTrim(text: "+00:00:00:01", rate: rate)?.frames, 1)
            XCTAssertEqual(LTCFrameTrim(text: "-00:00:00:01", rate: rate)?.frames, -1)
            XCTAssertEqual(LTCFrameTrim(text: "00:00:00:00", rate: rate)?.frames, 0)
            XCTAssertEqual(LTCFrameTrim(text: "+00:00:10:00", rate: rate)?.frames,
                           Int64((10 * rate.actual).rounded()))
        }
    }

    func testTrimChangesLTCWithoutMovingTimeline() {
        let address = LTCTimecode(text: "01:00:00:00", rate: .fps25)!
        let trim = LTCFrameTrim(text: "-00:00:01:12", rate: .fps25)!
        XCTAssertEqual(trim.frames, -37)
        XCTAssertEqual(LTCTimecode.at(frameNumber: address.absoluteFrames + trim.frames,
                                      rate: .fps25).display, "00:59:58:13")
    }

    func testTrimInputValidation() {
        XCTAssertNil(LTCFrameTrim(text: "+00:00:00:25", rate: .fps25))
        XCTAssertNil(LTCFrameTrim(text: "-00:60:00:00", rate: .fps25))
        XCTAssertNil(LTCFrameTrim(text: "blah", rate: .fps25))
        XCTAssertEqual(LTCFrameTrim(text: "-00:01:00:00", rate: .fps2997DF)?.frames, -1798)
    }

    func testNegativeOffsetByDefaultForNewTimecode() {
        let cue = CueElement.timecode()
        XCTAssertEqual(cue.ltcTrim, "-00:00:00:00")
        XCTAssertEqual(LTCFrameTrim(text: cue.ltcTrim, rate: .fps25)?.frames, 0)
        XCTAssertEqual(LTCFrameTrim.address(frames: 0, rate: .fps25), "-00:00:00:00")
    }

    func testFrameNudgeRoundTripIncludingDropFrame() {
        for rate in LTCFrameRate.allCases {
            for frames: Int64 in [-100_000, -1798, -75, -1, 0, 1, 29, 30, 75, 1798, 100_000] {
                let rendered = LTCFrameTrim.address(frames: frames, rate: rate)
                let parsed = LTCFrameTrim(text: rendered, rate: rate)
                XCTAssertEqual(parsed?.frames, frames, "Rate \(rate) value \(frames) address \(rendered)")
            }
        }
    }

    func testExplicitPositiveExistingOffsetIsPreserved() throws {
        let element = CueElement(kind: .timecode, name: "LTC", ltcTrim: "+00:00:00:12")
        let restored = try JSONDecoder().decode(CueElement.self, from: JSONEncoder().encode(element))
        XCTAssertEqual(restored.ltcTrim, "+00:00:00:12")
    }

    func testGainTrimClampsToSafeNominalHeadroom() {
        XCTAssertEqual(CueElement(kind: .timecode, name: "LTC", ltcLevelTrimDB: 20).ltcLevelTrimDB, 12)
        XCTAssertEqual(CueElement(kind: .timecode, name: "LTC", ltcLevelTrimDB: -99).ltcLevelTrimDB, -36)
    }

    func testSchemaBackwardCompatibility() throws {
        let old = CueElement.timecode()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "ltcTrim")
        json.removeValue(forKey: "ltcLevelTrimDB")
        let data = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(CueElement.self, from: data)
        XCTAssertEqual(restored.ltcTrim, "-00:00:00:00")
        XCTAssertEqual(restored.ltcLevelTrimDB, 0)

        var edited = restored
        edited.ltcTrim = "-00:00:00:12"
        edited.ltcLevelTrimDB = -6
        let roundtrip = try JSONDecoder().decode(CueElement.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundtrip.ltcTrim, "-00:00:00:12")
        XCTAssertEqual(roundtrip.ltcLevelTrimDB, -6)
    }
}
