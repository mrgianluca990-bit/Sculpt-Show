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
}
