import XCTest
@testable import SculptShowCore

final class ProjectionDisplayPolicyTests: XCTestCase {
    func testOneDisplayIsNeverAProjectionTarget() {
        for saved in ["", "primary", "old-external"] {
            XCTAssertNil(ProjectionDisplayPolicy.target(connected: ["primary"], operatorDisplay: "primary", preferred: saved))
        }
        XCTAssertEqual(ProjectionDisplayPolicy.eligible(connected: [], operatorDisplay: nil), [])
        XCTAssertEqual(ProjectionDisplayPolicy.eligible(connected: ["", "external"], operatorDisplay: nil), [])
        XCTAssertEqual(ProjectionDisplayPolicy.eligible(connected: ["primary", "primary"], operatorDisplay: nil), [])
    }
    func testExplicitPrimarySelectionIsRejectedWithTwoDisplays() {
        XCTAssertNil(ProjectionDisplayPolicy.target(connected: ["primary", "external"], operatorDisplay: "primary", preferred: "primary"))
        XCTAssertEqual(ProjectionDisplayPolicy.target(connected: ["primary", "external"], operatorDisplay: "primary", preferred: ""), "external")
    }
    func testWorkspaceDisplayCannotBeCoveredEvenIfItIsExternal() {
        XCTAssertEqual(ProjectionDisplayPolicy.eligible(connected: ["primary", "workspace", "projector"], operatorDisplay: "workspace"), ["projector"])
        XCTAssertNil(ProjectionDisplayPolicy.target(connected: ["primary", "workspace"], operatorDisplay: "workspace", preferred: "workspace"))
    }
    func testDisconnectAndDisplayReorderingDoNotFallback() {
        XCTAssertNil(ProjectionDisplayPolicy.target(connected: ["primary", "other"], operatorDisplay: "primary", preferred: "projector"))
        XCTAssertNil(ProjectionDisplayPolicy.target(connected: ["projector", "primary"], operatorDisplay: "primary", preferred: "projector"))
        XCTAssertEqual(ProjectionDisplayPolicy.target(connected: ["primary", "other", "projector"], operatorDisplay: "primary", preferred: "projector"), "projector")
    }
    func testOneScreenChoosesLocalWindowIncludingOldPreferences() {
        for preferred in ["", "primary", "old-projector"] {
            XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary"], operatorDisplay: "primary", preferred: preferred), .localWindow)
        }
        XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: [], operatorDisplay: nil, preferred: ""), .unavailable)
    }
    func testSecondScreenAutomaticallyChoosesExternalOutput() {
        for preferred in ["", "primary", "external", "old-projector"] {
            XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary", "external"], operatorDisplay: "primary", preferred: preferred), .externalDisplay("external"))
        }
    }
    func testMultipleExternalScreensRespectChoiceAndRejectMissingChoice() {
        XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary", "a", "b"], operatorDisplay: "primary", preferred: "b"), .externalDisplay("b"))
        XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary", "a", "b"], operatorDisplay: "primary", preferred: "missing"), .unavailable)
        XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary", "a"], operatorDisplay: "a", preferred: ""), .localWindow)
    }
    func testMirroredExternalScreensUseLocalWindow() {
        XCTAssertEqual(ProjectionDisplayPolicy.destination(connected: ["primary", "mirror"], operatorDisplay: "primary", preferred: "", excluded: ["mirror"]), .localWindow)
    }
    func testPreviewWindowCannotFillOperatorDisplay() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let frame = LocalVideoWindowGeometry.clamped(CGRect(x: -500, y: -500, width: 4000, height: 3000), in: visible)
        XCTAssertEqual(frame.width, 1224, accuracy: 0.001)
        XCTAssertEqual(frame.height, 731, accuracy: 0.001)
        XCTAssertTrue(visible.contains(frame))
    }
    func testSavedPreviewFromDisconnectedDisplayIsBroughtBackOnscreen() {
        let visible = CGRect(x: 30, y: 40, width: 1440, height: 860)
        let frame = LocalVideoWindowGeometry.clamped(CGRect(x: 5000, y: 5000, width: 640, height: 360), in: visible)
        XCTAssertEqual(frame.size, CGSize(width: 640, height: 360))
        XCTAssertTrue(visible.contains(frame))
    }
    func testPreviewMinimumSizeFitsSmallDisplays() {
        let visible = CGRect(x: -500, y: 10, width: 200, height: 150)
        let frame = LocalVideoWindowGeometry.clamped(.zero, in: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertLessThan(frame.width, visible.width)
    }

}
