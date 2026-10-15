import XCTest
@testable import SculptShowCore

final class MTCGeneratorTests: XCTestCase {
    func testQuarterFrameEncoderRoundTripAcrossRates() throws {
        for rate in MTCGeneratorRate.allCases {
            let seconds = try XCTUnwrap(MTCGeneratorModel.parsePosition(
                rate == .fps2997Drop ? "01:02:03;14" : "01:02:03:14", rate: rate))
            let position = MTCGeneratorModel.frame(at: seconds, rate: rate)
            var decoder = MTCDecoder()
            var result: MTCFrame?
            for phase in 0..<8 {
                result = decoder.ingestQuarterFrame(
                    MTCGeneratorModel.quarterFrameData(position, rate: rate, phase: phase))
            }
            XCTAssertEqual(result, position)
            XCTAssertEqual(result?.dropFrame, rate == .fps2997Drop)
        }
    }

    func testSMPTEFullFrameLocateAndQuarterFrames() throws {
        let frame = MTCGeneratorModel.frame(at: 3_723.16, rate: .fps25)
        XCTAssertEqual(frame.display, "01:02:03:04")
        XCTAssertEqual(MTCGeneratorModel.fullFrameLocate(frame, rate: .fps25),
                       [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x21, 0x02, 0x03, 0x04, 0xF7])
        XCTAssertEqual((0..<8).map { MTCGeneratorModel.quarterFrameData(frame, rate: .fps25, phase: $0) },
                       [0x04, 0x10, 0x23, 0x30, 0x42, 0x50, 0x61, 0x72])
    }

    func testDropFrameTimeAndIllegalLabels() throws {
        XCTAssertNil(MTCGeneratorModel.parsePosition("00:01:00;00", rate: .fps2997Drop))
        XCTAssertNil(MTCGeneratorModel.parsePosition("00:01:00;01", rate: .fps2997Drop))
        XCTAssertNotNil(MTCGeneratorModel.parsePosition("00:01:00;02", rate: .fps2997Drop))
        XCTAssertNotNil(MTCGeneratorModel.parsePosition("00:10:00;00", rate: .fps2997Drop))
        XCTAssertEqual(MTCGeneratorModel.frame(at: 0, rate: .fps2997Drop).display, "00:00:00;00")
    }

    func testInvalidPositionAndWrappedTime() {
        XCTAssertNil(MTCGeneratorModel.parsePosition("00:00:60:00", rate: .fps25))
        XCTAssertNil(MTCGeneratorModel.parsePosition("00:00:00:25", rate: .fps25))
        XCTAssertNil(MTCGeneratorModel.parsePosition("nonsense", rate: .fps25))
        XCTAssertEqual(MTCGeneratorModel.frame(at: 86_400, rate: .fps25).display, "00:00:00:00")
    }
}
