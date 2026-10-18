import XCTest
@testable import SculptShowCore

final class NativeMarkerLoopPlannerTests: XCTestCase {
    private func cue(markers: [CueMarker]) throws -> Cue {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let id = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(id, in: list) { $0.markers = markers }
        return try XCTUnwrap(show.cue(id))
    }

    func testExplicitReturnMarkerUsesNativeScheduling() throws {
        let start = CueMarker(name: "Start", positionSeconds: 1.125)
        let middle = CueMarker(name: "Middle", positionSeconds: 2)
        var end = CueMarker(name: "End", positionSeconds: 3.75)
        end.rules = [InteractionRule(action: .fire, target: .itself, fireAtMarkerID: start.id)]
        let plan = try XCTUnwrap(NativeMarkerLoopPlanner.plan(for: cue(markers: [end, middle, start])))
        XCTAssertEqual(plan.inSeconds, 1.125)
        XCTAssertEqual(plan.outSeconds, 3.75)
        XCTAssertEqual(plan.triggerMarkerID, end.id)
    }

    func testImplicitReturnStillUsesPreviousMarker() throws {
        let start = CueMarker(name: "Start", positionSeconds: 1)
        var end = CueMarker(name: "End", positionSeconds: 4)
        end.rules = [InteractionRule(action: .fire, target: .itself)]
        XCTAssertEqual(NativeMarkerLoopPlanner.plan(for: try cue(markers: [start, end]))?.inSeconds, 1)
    }

    func testInvalidForwardMissingAndDelayedReturnsStayWithRulesEngine() throws {
        let start = CueMarker(name: "Start", positionSeconds: 1)
        var end = CueMarker(name: "End", positionSeconds: 4)
        for rule in [
            InteractionRule(action: .fire, target: .itself, fireAtMarkerID: end.id),
            InteractionRule(action: .fire, target: .itself, fireAtMarkerID: UUID()),
            InteractionRule(action: .fire, target: .itself, delaySeconds: 0.1, fireAtMarkerID: start.id)
        ] {
            end.rules = [rule]
            XCTAssertNil(NativeMarkerLoopPlanner.plan(for: try cue(markers: [start, end])))
        }
    }
    func testConditionalReturnKeepsNativePlanAndConditionIdentity() throws {
        let start = CueMarker(name: "Start", positionSeconds: 1)
        let condition = UUID()
        var end = CueMarker(name: "End", positionSeconds: 4)
        end.rules = [InteractionRule(action: .fire, target: .itself, conditionCueID: condition,
            conditionState: .stopped, fireAtMarkerID: start.id)]
        let plan = try XCTUnwrap(NativeMarkerLoopPlanner.plan(for: cue(markers: [start, end])))
        XCTAssertEqual(plan.conditionCueID, condition)
        XCTAssertEqual(plan.conditionState, .stopped)
        XCTAssertEqual(plan.inSeconds, 1)
        XCTAssertEqual(plan.outSeconds, 4)
    }

}
