import Foundation
import XCTest
@testable import SculptShowCore

final class CueDurationEditGuardTests: XCTestCase {
    func testOldFocusedDraftCannotOverwriteNewSelectedCue() {
        let a = UUID(), b = UUID(), list = UUID()
        XCTAssertNil(CueDurationEditGuard.confirmedValue("01:00:00:000", ownerCueID: a,
            ownerListID: list, selectedCueID: b, selectedListID: list))
        XCTAssertNil(CueDurationEditGuard.confirmedValue("01:00:00:000", ownerCueID: a,
            ownerListID: list, selectedCueID: a, selectedListID: UUID()))
        XCTAssertEqual(CueDurationEditGuard.confirmedValue("00:00:09:500", ownerCueID: a,
            ownerListID: list, selectedCueID: a, selectedListID: list), 9.5)
    }
    func testInvalidDraftRejectedEvenForOwner() {
        let cue = UUID(), list = UUID()
        XCTAssertNil(CueDurationEditGuard.confirmedValue("NOT VALID", ownerCueID: cue,
            ownerListID: list, selectedCueID: cue, selectedListID: list))
    }
}
