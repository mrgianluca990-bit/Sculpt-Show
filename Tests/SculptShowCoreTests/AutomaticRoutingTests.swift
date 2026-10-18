import XCTest
@testable import SculptShowCore

final class AutomaticRoutingTests: XCTestCase {
    func testFourMonoStemsWrapOnTwoOutputs() {
        XCTAssertEqual(AudioRoutePlan.automaticOutputs(channelCounts: [1, 1, 1, 1], deviceChannels: 2), [1, 2, 1, 2])
    }
    func testStereoPairsAndOddDeviceCapacity() {
        XCTAssertEqual(AudioRoutePlan.automaticOutputs(channelCounts: [2, 2, 2], deviceChannels: 4), [1, 3, 1])
        XCTAssertEqual(AudioRoutePlan.automaticOutputs(channelCounts: [1, 2, 2], deviceChannels: 3), [1, 2, 1])
    }
    func testOldProjectRoutesWrapToConnectedOutputs() {
        XCTAssertEqual(AudioRoutePlan.wrappedOutput(17, sourceChannels: 1, deviceChannels: 2), 1)
        XCTAssertEqual(AudioRoutePlan.wrappedOutput(18, sourceChannels: 1, deviceChannels: 2), 2)
        XCTAssertEqual(AudioRoutePlan.wrappedOutput(4, sourceChannels: 2, deviceChannels: 4), 1)
        XCTAssertNil(AudioRoutePlan.crosspoints(firstOutput: 1, sourceChannels: 2, deviceChannels: 1))
    }
}
