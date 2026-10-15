import XCTest
@testable import SculptShowCore

final class OutputPeakHoldTests: XCTestCase {
    func testPeakHoldAcrossAll64Outputs() {
        var state = OutputPeakHoldState(channelCount: 64)
        XCTAssertEqual(state.channelCount, 64)
        state.observe(Array(repeating: 0.2, count: 63) + [0.95])
        state.observe(Array(repeating: 0.1, count: 64))
        XCTAssertEqual(state.peak(channel: 64), 0.95, accuracy: 0.00001)
        XCTAssertEqual(state.peak(channel: 1), 0.2, accuracy: 0.00001)
        state.reset()
        XCTAssertEqual(state.peak(channel: 64), 0)
    }

    func testClipLatchesUntilReset() {
        var state = OutputPeakHoldState(channelCount: 2)
        state.observe([1.02, 0.5])
        XCTAssertTrue(state.clipped(channel: 1))
        XCTAssertFalse(state.clipped(channel: 2))
        state.observe([0, 0])
        XCTAssertTrue(state.clipped(channel: 1))
        state.reset()
        XCTAssertFalse(state.clipped(channel: 1))
    }

    func testInvalidAndNonfiniteValuesAreIgnored() {
        var state = OutputPeakHoldState(channelCount: 1)
        state.observe([.nan])
        state.observe([.infinity])
        state.observe([-5])
        XCTAssertEqual(state.peak(channel: 1), 0)
        XCTAssertEqual(state.peak(channel: 0), 0)
        XCTAssertEqual(state.peak(channel: 2), 0)
        state.observe([0.75, 1.0])
        XCTAssertEqual(state.peak(channel: 1), 0.75, accuracy: 0.00001)
    }
}
