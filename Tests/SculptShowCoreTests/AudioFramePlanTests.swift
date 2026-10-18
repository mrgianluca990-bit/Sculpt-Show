import XCTest
@testable import SculptShowCore

final class AudioFramePlanTests: XCTestCase {
    func testSeeksAreBoundedBeforeIntegerConversion() {
        XCTAssertEqual(AudioFramePlan.position(seconds: 0.5, sampleRate: 48000, fileLength: 48000), 24000)
        XCTAssertEqual(AudioFramePlan.position(seconds: 2, sampleRate: 48000, fileLength: 48000), 48000)
        XCTAssertEqual(AudioFramePlan.position(seconds: .greatestFiniteMagnitude, sampleRate: 48000, fileLength: 48000), 48000)
        XCTAssertEqual(AudioFramePlan.position(seconds: .nan, sampleRate: 48000, fileLength: 48000), 0)
        XCTAssertEqual(AudioFramePlan.position(seconds: -1, sampleRate: 48000, fileLength: 48000), 0)
        XCTAssertEqual(AudioFramePlan.position(seconds: 1, sampleRate: .infinity, fileLength: 48000), 0)
    }
}
