import XCTest
@testable import SculptShowCore

final class LTCTimecodeTests: XCTestCase {
    func testRoundtripTimecode() {
        for rate in LTCFrameRate.allCases {
            let values: [Int64] = [0, 1, 24, 25, 30, 1_800, 17_982, 108_000, 800_000]
            for value in values {
                let tc = LTCTimecode.at(frameNumber: value, rate: rate)
                XCTAssertEqual(LTCTimecode(text: tc.display, rate: rate)?.absoluteFrames, value)
            }
        }
    }
    func testDropFrameMinuteBoundaryAndSkippedLabels() {
        let df: LTCFrameRate = .fps2997DF
        XCTAssertEqual(LTCTimecode.at(frameNumber: 1800, rate: df).display, "00:01:00;02")
        XCTAssertEqual(LTCTimecode.at(frameNumber: 17982, rate: df).display, "00:10:00;00")
        XCTAssertNil(LTCTimecode(text: "00:01:00;00", rate: df))
        XCTAssertNil(LTCTimecode(text: "00:01:00;01", rate: df))
        XCTAssertNotNil(LTCTimecode(text: "00:10:00;00", rate: df))
    }
    func test24HourRollover() {
        XCTAssertEqual(LTCTimecode.at(frameNumber: 2_589_408, rate: .fps2997DF).display, "00:00:00;00")
        XCTAssertEqual(LTCTimecode.at(frameNumber: 25*86400, rate: .fps25).display, "00:00:00:00")
    }
    func testOldAndNewCueElementsAreCompatible() throws {
        let element = CueElement.timecode()
        XCTAssertNil(element.ltcOutputChannel)
        var modified = element
        modified.ltcOutputChannel = 16
        modified.timecodeDropFrame = true
        modified.frameRate = 30
        modified.timecodeStart = "01:00:00:00"
        let roundtrip = try JSONDecoder().decode(CueElement.self, from: JSONEncoder().encode(modified))
        XCTAssertEqual(roundtrip, modified)
    }
}
