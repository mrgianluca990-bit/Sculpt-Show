import Foundation
import XCTest
@testable import SculptShowCore

final class MarkerTests: XCTestCase {
    func testMarkerRoundTripAndStableChronologicalOrder() throws {
        var show = Show(name: "Night Show")
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let cue = try XCTUnwrap(show.addEmptyCue(to: list))
        let middle = CueMarker(name: "Verse", positionSeconds: 30)
        var end = CueMarker(name: "Loop out", positionSeconds: 60)
        end.rules = [InteractionRule(event: .starting, action: .fire,
                                     target: .itself, fireAtMarkerID: middle.id)]
        let first = CueMarker(name: "Intro", positionSeconds: 10)
        show.updateCue(cue, in: list) { $0.markers = [middle, end, first] }
        let decoded = try ShowCodec.decode(ShowCodec.encode(show))
        let restored = try XCTUnwrap(decoded.cue(cue))
        XCTAssertEqual(restored.markers, [middle, end, first])
        XCTAssertEqual(restored.sortedMarkers.map(\.name), ["Intro", "Verse", "Loop out"])
        XCTAssertEqual(restored.markers[1].rules.first?.fireAtMarkerID, middle.id)
    }

    func testLegacyShowAndLegacyRuleDecodeWithoutMarkers() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let cue = try XCTUnwrap(show.addEmptyCue(to: list))
        show.updateCue(cue, in: list) {
            $0.rules.append(InteractionRule(action: .fire, target: .nextCue))
        }
        let encoded = try ShowCodec.encode(show)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var lists = try XCTUnwrap(json["cueLists"] as? [[String: Any]])
        var cues = try XCTUnwrap(lists[0]["cues"] as? [[String: Any]])
        cues[0].removeValue(forKey: "markers")
        var rules = try XCTUnwrap(cues[0]["rules"] as? [[String: Any]])
        rules[0].removeValue(forKey: "fireAtMarkerID")
        cues[0]["rules"] = rules
        lists[0]["cues"] = cues
        json["cueLists"] = lists
        let decoded = try ShowCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(try XCTUnwrap(decoded.cue(cue)).markers.isEmpty)
        XCTAssertNil(try XCTUnwrap(decoded.cue(cue)).rules[0].fireAtMarkerID)
    }

    func testCrossingOrderingAndNoSkippedMarkers() {
        let first = CueMarker(name: "M1", positionSeconds: 1)
        let second = CueMarker(name: "M2", positionSeconds: 2)
        let third = CueMarker(name: "M3", positionSeconds: 3)
        XCTAssertEqual(MarkerPlanner.crossed([third, first, second], from: 0, to: 2.1, duration: 4).map(\.id),
                       [first.id, second.id])
        XCTAssertTrue(MarkerPlanner.crossed([first, second], from: 3, to: 1, duration: 4).isEmpty)
        XCTAssertTrue(MarkerPlanner.crossed([first], from: 1, to: 1.01, duration: 4).isEmpty)
        // A seek to 2.5 should reset previous position to 2.5; intervening markers not emitted.
        XCTAssertEqual(MarkerPlanner.crossed([first, second, third], from: 2.5, to: 3.01, duration: 4).map(\.id), [third.id])
        XCTAssertEqual(MarkerPlanner.crossed([CueMarker(name: "Zero", positionSeconds: 0)],
                                              from: -0.0001, to: 0, duration: 4).count, 1)
    }

    func testOutOfDurationMarkersDoNotTrigger() {
        let end = CueMarker(name: "End", positionSeconds: 10)
        let beyond = CueMarker(name: "Beyond", positionSeconds: 15)
        XCTAssertTrue(MarkerPlanner.crossed([end, beyond], from: 9, to: 30, duration: 10).isEmpty)
    }

    func testFireItselfLoopsToPreviousChronologicalMarker() {
        let a = CueMarker(name: "First", positionSeconds: 11)
        let b = CueMarker(name: "Second", positionSeconds: 18)
        let c = CueMarker(name: "Third", positionSeconds: 42)
        let unordered = [c, a, b]
        XCTAssertEqual(MarkerPlanner.loopDestination(for: c.id, in: unordered), 18)
        XCTAssertEqual(MarkerPlanner.loopDestination(for: b.id, in: unordered), 11)
        XCTAssertEqual(MarkerPlanner.loopDestination(for: a.id, in: unordered), 0)
        XCTAssertNil(MarkerPlanner.loopDestination(for: UUID(), in: unordered))
    }

    func testMarkerRuleConditionAndTargetResolution() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let c1 = try XCTUnwrap(show.addEmptyCue(to: list))
        let c2 = try XCTUnwrap(show.addEmptyCue(to: list))
        var marker = CueMarker(name: "Trigger", positionSeconds: 1)
        marker.rules = [
            InteractionRule(action: .fire, target: .nextCue),
            InteractionRule(action: .stop, target: .specificCue, targetID: c2,
                            conditionCueID: c2, conditionState: .playing),
            InteractionRule(enabled: false, action: .pause, target: .allCues)
        ]
        show.updateCue(c1, in: list) { $0.markers = [marker] }
        XCTAssertEqual(RulePlanner.markerCommands(markerID: marker.id, source: c1,
            in: show, states: [:]).map(\.rule.action), [.fire])
        let commands = RulePlanner.markerCommands(markerID: marker.id, source: c1,
            in: show, states: [c2: .playing])
        XCTAssertEqual(commands.map(\.rule.action), [.fire, .stop])
        XCTAssertEqual(commands[0].targets, [c2])
        XCTAssertTrue(RulePlanner.markerCommands(markerID: UUID(), source: c1,
            in: show, states: [:]).isEmpty)
    }

    func testDuplicateRemapsMarkerRuleDestinationsAndKeepsOriginal() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let cueID = try XCTUnwrap(show.addEmptyCue(to: list))
        let entry = CueMarker(name: "In", positionSeconds: 3)
        var exit = CueMarker(name: "Out", positionSeconds: 7)
        exit.rules.append(InteractionRule(action: .fire, target: .specificCue,
            targetID: cueID, fireAtMarkerID: entry.id))
        show.updateCue(cueID, in: list) {
            $0.markers = [entry, exit]
            $0.rules.append(InteractionRule(action: .fire, target: .itself,
                                            fireAtMarkerID: entry.id))
        }
        let cloneID = try XCTUnwrap(show.duplicateCue(cueID, in: list))
        let clone = try XCTUnwrap(show.cue(cloneID))
        XCTAssertNotEqual(clone.markers[0].id, entry.id)
        XCTAssertNotEqual(clone.markers[1].id, exit.id)
        XCTAssertEqual(clone.markers[1].rules[0].targetID, cloneID)
        XCTAssertEqual(clone.markers[1].rules[0].fireAtMarkerID, clone.markers[0].id)
        XCTAssertEqual(clone.rules[0].fireAtMarkerID, clone.markers[0].id)
        XCTAssertEqual(try XCTUnwrap(show.cue(cueID)).markers[0].id, entry.id)
    }

    func testRelocationPreservesMarkerRulesAndNumbersReorderOnly() throws {
        var show = Show()
        let first = try XCTUnwrap(show.cueLists.first?.id)
        let second = show.addList(name: "Stage B")
        let id = try XCTUnwrap(show.addEmptyCue(to: first))
        let marker = CueMarker(name: "Fire light", positionSeconds: 4,
            rules: [InteractionRule(action: .fire, target: .itself)])
        show.updateCue(id, in: first) { $0.markers = [marker] }
        XCTAssertTrue(show.relocateCue(id, to: second))
        XCTAssertEqual(try XCTUnwrap(show.cue(id)).markers, [marker])
        show.updateCue(id, in: second) { $0.markers[0].positionSeconds = 2 }
        XCTAssertEqual(try XCTUnwrap(show.cue(id)).markers[0].id, marker.id)
    }
}
