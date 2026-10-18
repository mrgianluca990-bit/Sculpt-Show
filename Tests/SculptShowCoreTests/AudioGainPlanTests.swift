import XCTest
@testable import SculptShowCore

final class AudioGainPlanTests: XCTestCase {
    func testPositiveTrimIsNotClampedToUnity() {
        XCTAssertEqual(AudioGainPlan.linear(cue: 2, element: 1.5, fade: 0.5, trim: 2, muted: false), 3)
    }
    func testMuteAndInvalidInputAreSilent() {
        XCTAssertEqual(AudioGainPlan.linear(cue: 2, element: 1, fade: 1, trim: 1, muted: true), 0)
        XCTAssertEqual(AudioGainPlan.linear(cue: .nan, element: 1, fade: 1, trim: 1, muted: false), 0)
        XCTAssertEqual(AudioGainPlan.linear(cue: 1, element: 1, fade: .infinity, trim: 1, muted: false), 0)
    }
}
