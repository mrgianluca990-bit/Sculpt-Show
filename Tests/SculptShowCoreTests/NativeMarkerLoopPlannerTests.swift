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

    func testOtherCueActionsDoNotDisableOrDuplicateNativeReturn() throws {
        for action: RuleAction in [.fire, .stop] {
            for conditional in [false, true] {
                let start = CueMarker(name: "IN", positionSeconds: 1)
                var end = CueMarker(name: "OUT", positionSeconds: 4)
                let loop = InteractionRule(action: .fire, target: .itself,
                    conditionCueID: conditional ? UUID() : nil)
                let otherCue = Cue(name: "Other")
                let other = InteractionRule(action: action, target: .specificCue, targetID: otherCue.id)
                end.rules = [other, loop]
                let source = try cue(markers: [start, end])
                let plan = try XCTUnwrap(NativeMarkerLoopPlanner.plan(for: source))
                XCTAssertEqual(plan.ruleID, loop.id)
                XCTAssertEqual(plan.triggerMarkerID, end.id)
                XCTAssertEqual(plan.conditionCueID, loop.conditionCueID)
                let show = Show(cueLists: [CueList(name: "List", cues: [source, otherCue])])
                let states: [UUID: RuleCueState] = loop.conditionCueID.map { [$0: .playing] } ?? [:]
                let commands = RulePlanner.markerCommands(markerID: end.id, source: source.id,
                    in: show, states: states).filter { $0.rule.id != plan.ruleID }
                XCTAssertEqual(commands.count, 1)
                XCTAssertEqual(commands.first?.rule.action, action)
                XCTAssertEqual(commands.first?.targets, [otherCue.id])
            }
        }
    }

    func testMultipleSelfReturnsRemainAmbiguous() throws {
        let start = CueMarker(name: "IN", positionSeconds: 1)
        var end = CueMarker(name: "OUT", positionSeconds: 4)
        end.rules = [InteractionRule(action: .fire, target: .itself),
                     InteractionRule(action: .fire, target: .itself, conditionCueID: UUID())]
        XCTAssertNil(NativeMarkerLoopPlanner.plan(for: try cue(markers: [start, end])))
    }

    func testNativeBoundaryEventsAreConsumedOnceAndResetOnNewTransport() {
        var cursor = NativeMarkerEventCursor()
        let token = UUID()
        XCTAssertEqual(cursor.consume(token: token, count: 0), 0)
        XCTAssertEqual(cursor.consume(token: token, count: 1), 1)
        for _ in 0..<7 { XCTAssertEqual(cursor.consume(token: token, count: 1), 0) }
        XCTAssertEqual(cursor.consume(token: token, count: 4), 3)
        XCTAssertEqual(cursor.consume(token: UUID(), count: 1), 1)
    }

}
