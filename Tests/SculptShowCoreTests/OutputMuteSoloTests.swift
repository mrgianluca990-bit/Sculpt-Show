import XCTest
@testable import SculptShowCore

final class OutputMuteSoloTests: XCTestCase {
    func testMuteSoloAndResetAcross64Channels() {
        var state = OutputMuteSoloState(channelCount: 64)
        XCTAssertTrue((1...64).allSatisfy(state.isAudible))
        state.toggleMute(1)
        XCTAssertFalse(state.isAudible(1))
        state.toggleSolo(63)
        state.toggleSolo(64)
        XCTAssertTrue(state.isAudible(63))
        XCTAssertTrue(state.isAudible(64))
        XCTAssertFalse(state.isAudible(2))
        state.toggleMute(63)
        XCTAssertFalse(state.isAudible(63))
        state.clear()
        XCTAssertTrue((1...64).allSatisfy(state.isAudible))
    }

    func testDeviceChangeClearsState() {
        var state = OutputMuteSoloState(channelCount: 16)
        state.toggleMute(16)
        XCTAssertFalse(state.isAudible(16))
        state = OutputMuteSoloState(channelCount: 2)
        XCTAssertTrue(state.isAudible(1))
        XCTAssertTrue(state.isAudible(2))
        XCTAssertFalse(state.isAudible(16))
    }

    func testOutputGainFollowsMuteSolo() {
        var state = OutputMuteSoloState(channelCount: 16)
        XCTAssertEqual(state.outputGain(3), 1)
        state.toggleMute(3)
        XCTAssertEqual(state.outputGain(3), 0)
        state.toggleSolo(5)
        XCTAssertEqual(state.outputGain(5), 1)
        XCTAssertEqual(state.outputGain(1), 0)
        state.clear()
        XCTAssertEqual(state.outputGain(3), 1)
    }

    func testInvalidChannelIgnoredAndBanksCover64() {
        var state = OutputMuteSoloState(channelCount: 16)
        state.toggleSolo(17)
        state.toggleMute(0)
        XCTAssertFalse(state.anySolo)
        XCTAssertEqual(state.mutedCount, 0)
        XCTAssertEqual(OutputMixerBanks.banks(channelCount: 64), [0, 1, 2, 3, 4])
        XCTAssertEqual(OutputMixerBanks.channels(channelCount: 64, bank: 4), Array(49...64))
        XCTAssertEqual(OutputMixerBanks.channels(channelCount: 2, bank: 0), [1,2])
    }
}
