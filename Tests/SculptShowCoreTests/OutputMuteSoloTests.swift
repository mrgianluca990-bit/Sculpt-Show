import XCTest
@testable import SculptShowCore

final class OutputMuteSoloTests: XCTestCase {
    func testMonoOutputAndMultiSoloAcross64Channels() {
        var state = OutputMuteSoloState(channelCount: 64)
        XCTAssertTrue((1...64).allSatisfy(state.isAudible))
        state.toggleMute(1)
        XCTAssertFalse(state.isAudible(1))
        XCTAssertTrue(state.isAudible(64))
        state.toggleSolo(63)
        state.toggleSolo(64)
        XCTAssertTrue(state.isAudible(63))
        XCTAssertTrue(state.isAudible(64))
        XCTAssertFalse(state.isAudible(2))
        state.toggleMute(63)
        XCTAssertFalse(state.isAudible(63), "Mute prevails over solo")
        state.clear()
        XCTAssertTrue((1...64).allSatisfy(state.isAudible))
    }

    func testInvalidChannelsIgnoredAndDeviceChangeClearsState() {
        var state = OutputMuteSoloState(channelCount: 16)
        state.toggleMute(0)
        state.toggleSolo(17)
        XCTAssertEqual(state.mutedCount, 0)
        XCTAssertEqual(state.soloCount, 0)
        state.toggleMute(16)
        XCTAssertFalse(state.isAudible(16))
        state = OutputMuteSoloState(channelCount: 2)
        XCTAssertTrue(state.isAudible(1))
        XCTAssertTrue(state.isAudible(2))
        XCTAssertFalse(state.isAudible(16))
    }

    func testAllBanksCover64WithoutMissingChannels() {
        XCTAssertEqual(OutputMixerBanks.banks(channelCount: 64), [0, 1, 2, 3, 4])
        XCTAssertEqual(OutputMixerBanks.channels(channelCount: 64, bank: 4), Array(49...64))
        XCTAssertEqual(OutputMixerBanks.banks(channelCount: 2), [0, 1])
        XCTAssertEqual((1...4).flatMap { OutputMixerBanks.channels(channelCount: 64, bank: $0) }, Array(1...64))
        XCTAssertTrue(OutputMixerBanks.channels(channelCount: 0, bank: 0).isEmpty)
    }
}
