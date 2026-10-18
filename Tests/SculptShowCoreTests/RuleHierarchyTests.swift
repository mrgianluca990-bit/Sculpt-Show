import XCTest
@testable import SculptShowCore

final class RuleHierarchyTests: XCTestCase {
    private func fixture() -> Show {
        var list = CueList(name: "Playlist", cues: [Cue(name: "A"), Cue(name: "B")])
        for index in list.cues.indices {
            list.cues[index].rules = [InteractionRule(event: .starting, action: .pause, target: .itself)]
        }
        list.rules = [InteractionRule(event: .starting, action: .fade, target: .cueList, targetID: list.id, excludeSource: true)]
        var show = Show(cueLists: [list])
        show.rules = [InteractionRule(event: .starting, action: .dim, target: .itself)]
        return show
    }
    func testShowReplacesListAndCueRulesForEveryCue() {
        let show = fixture()
        for cue in show.cueLists[0].cues {
            XCTAssertEqual(RulePlanner.effectiveRules(for: cue.id, in: show), show.rules)
            let commands = RulePlanner.commands(for: .starting, source: cue.id, in: show, states: [:])
            XCTAssertEqual(commands.map(\.rule.action), [.dim])
        }
    }
    func testListReplacesCueRulesAndAppliesToEachSong() {
        var show = fixture(); show.rules = []
        let list = show.cueLists[0]
        for cue in list.cues {
            let commands = RulePlanner.commands(for: .starting, source: cue.id, in: show, states: [:])
            XCTAssertEqual(commands.map(\.rule.action), [.fade])
            XCTAssertEqual(commands.first?.targets, list.cues.filter { $0.id != cue.id }.map(\.id))
        }
    }
    func testListCanIgnoreShowAndOneCueCanIgnoreBothParents() {
        var show = fixture()
        show.cueLists[0].ignoreParentRules = true
        let first = show.cueLists[0].cues[0].id
        let second = show.cueLists[0].cues[1].id
        XCTAssertEqual(RulePlanner.effectiveRules(for: first, in: show), show.cueLists[0].rules)
        show.cueLists[0].cues[0].ignoreParentRules = true
        XCTAssertEqual(RulePlanner.effectiveRules(for: first, in: show), show.cueLists[0].cues[0].rules)
        XCTAssertEqual(RulePlanner.effectiveRules(for: second, in: show), show.cueLists[0].rules)
        show.cueLists[0].ignoreParentRules = false
        XCTAssertEqual(RulePlanner.effectiveRules(for: first, in: show), show.cueLists[0].cues[0].rules)
        XCTAssertEqual(RulePlanner.effectiveRules(for: second, in: show), show.rules)
    }
    func testFalseParentConditionDoesNotFallBackToChildRules() {
        var show = fixture()
        let source = show.cueLists[0].cues[0].id
        let other = show.cueLists[0].cues[1].id
        show.rules[0].conditionCueID = other
        show.rules[0].conditionState = .playing
        XCTAssertTrue(RulePlanner.commands(for: .starting, source: source, in: show, states: [:]).isEmpty)
        // A different event also does not mix in a lower-level rule set.
        show.rules[0].event = .ending
        XCTAssertTrue(RulePlanner.commands(for: .starting, source: source, in: show, states: [other: .playing]).isEmpty)
    }
    func testDisabledParentsAllowLowerLevelAndOptOutWithEmptyRulesDoesNothing() {
        var show = fixture()
        let id = show.cueLists[0].cues[0].id
        show.rules[0].enabled = false
        XCTAssertEqual(RulePlanner.effectiveRules(for: id, in: show), show.cueLists[0].rules)
        show.cueLists[0].rules[0].enabled = false
        XCTAssertEqual(RulePlanner.effectiveRules(for: id, in: show), show.cueLists[0].cues[0].rules)
        show.cueLists[0].cues[0].ignoreParentRules = true
        show.cueLists[0].cues[0].rules = []
        XCTAssertTrue(RulePlanner.effectiveRules(for: id, in: show).isEmpty)
    }
    func testListOptOutPersistsAndLegacyDefaultsToInheritance() throws {
        var show = fixture(); show.cueLists[0].ignoreParentRules = true
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(show.cueLists[0])) as? [String: Any])
        json.removeValue(forKey: "ignoreParentRules")
        let old = try JSONDecoder().decode(CueList.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.ignoreParentRules)
    }
    func testMarkerLoopRulesRemainIndependentFromLifecycleHierarchy() {
        var show = fixture()
        let marker = CueMarker(name: "Loop", positionSeconds: 2, rules: [InteractionRule(action: .fire, target: .itself)])
        show.cueLists[0].cues[0].markers = [marker]
        let id = show.cueLists[0].cues[0].id
        XCTAssertEqual(RulePlanner.markerCommands(markerID: marker.id, source: id, in: show, states: [:]).map(\.rule.action), [.fire])
    }
}
