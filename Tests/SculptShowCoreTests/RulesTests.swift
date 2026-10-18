import XCTest
@testable import SculptShowCore

final class RulesTests: XCTestCase {
    func demo() -> (Show, UUID, [UUID]) {
        var show = Show(name: "Rules Demo")
        let listID = show.cueLists[0].id
        let cueIDs = show.addAudio([
            URL(fileURLWithPath: "/tmp/intro.wav"),
            URL(fileURLWithPath: "/tmp/walk.wav"),
            URL(fileURLWithPath: "/tmp/outro.wav")
        ], to: listID)
        return (show, listID, cueIDs)
    }

    func testStartingFireNextAndDelayedAction() {
        var (show, _, ids) = demo()
        show.rules = [InteractionRule(event: .starting, action: .fire, target: .nextCue, delaySeconds: 2.25)]
        let result = RulePlanner.commands(for: .starting, source: ids[0], in: show, states: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].targets, [ids[1]])
        XCTAssertEqual(result[0].rule.delaySeconds, 2.25)
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).isEmpty)
    }

    func testShowListCueRulesInheritanceAndIgnoreParents() {
        var (show, listID, ids) = demo()
        show.rules = [InteractionRule(event: .starting, action: .stop, target: .previousCue)]
        show.cueLists[0].rules = [InteractionRule(event: .starting, action: .dim, target: .allCues)]
        show.updateCue(ids[1], in: listID) { cue in
            cue.rules = [InteractionRule(event: .starting, action: .fire, target: .nextCue)]
        }
        XCTAssertEqual(RulePlanner.effectiveRules(for: ids[1], in: show), show.rules)
        show.updateCue(ids[1], in: listID) { $0.ignoreParentRules = true }
        XCTAssertEqual(RulePlanner.effectiveRules(for: ids[1], in: show).count, 1)
        XCTAssertEqual(RulePlanner.commands(for: .starting, source: ids[1], in: show, states: [:])[0].targets, [ids[2]])
    }

    func testConditionPlayingPausedAndStopped() {
        var (show, listID, ids) = demo()
        let conditional = InteractionRule(event: .ending, action: .fire, target: .nextCue,
                                          conditionCueID: ids[2], conditionState: .paused)
        show.updateCue(ids[0], in: listID) { $0.rules = [conditional] }
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).isEmpty)
        XCTAssertEqual(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [ids[2]: .paused]).count, 1)
        show.updateCue(ids[0], in: listID) { $0.rules[0].conditionState = .stopped }
        XCTAssertEqual(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).count, 1)
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [ids[2]: .waiting]).isEmpty)
    }

    func testNonexistentConditionNeverMatchesStopped() {
        var (show, listID, ids) = demo()
        show.updateCue(ids[0], in: listID) {
            $0.rules = [InteractionRule(conditionCueID: UUID(), conditionState: .stopped)]
        }
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).isEmpty)
    }

    func testSpecificTargetAndWholeList() {
        var (show, _, ids) = demo()
        let secondList = show.addList(name: "Background")
        let extra = show.addAudio([URL(fileURLWithPath: "/tmp/amb.wav"), URL(fileURLWithPath: "/tmp/air.wav")], to: secondList)
        show.rules = [InteractionRule(action: .stop, target: .cueList, targetID: secondList)]
        XCTAssertEqual(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:])[0].targets, extra)
        show.rules[0].action = .fire
        XCTAssertEqual(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:])[0].targets, [extra[0]])
        show.rules[0].target = .specificCue
        show.rules[0].targetID = extra[1]
        XCTAssertEqual(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:])[0].targets, [extra[1]])
    }

    func testSaveAndRestoreRuleHierarchy() throws {
        var (show, listID, ids) = demo()
        show.rules = [InteractionRule(event: .starting, action: .dim, target: .allCues, dimDecibels: -18)]
        show.cueLists[0].rules = [InteractionRule(event: .ending, action: .fade, target: .nextCue, fadeSeconds: 7)]
        show.updateCue(ids[0], in: listID) { $0.rules = [InteractionRule(event: .stopping, action: .fire, target: .nextCue)] }
        let decoded = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(decoded, show)
        XCTAssertEqual(decoded.rules[0].dimDecibels, -18)
        XCTAssertEqual(decoded.cueLists[0].rules[0].fadeSeconds, 7)
        XCTAssertEqual(decoded.cueLists[0].cues[0].rules.count, 1)
    }

    func testLegacyProjectWithoutRulesStillOpens() throws {
        let (show, _, ids) = demo()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ShowCodec.encode(show)) as? [String: Any])
        json.removeValue(forKey: "rules")
        var lists = try XCTUnwrap(json["cueLists"] as? [[String: Any]])
        lists[0].removeValue(forKey: "rules")
        var cues = try XCTUnwrap(lists[0]["cues"] as? [[String: Any]])
        cues[0].removeValue(forKey: "rules")
        cues[0].removeValue(forKey: "ignoreParentRules")
        lists[0]["cues"] = cues
        json["cueLists"] = lists
        let restored = try ShowCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.rules.isEmpty)
        XCTAssertTrue(restored.cueLists[0].rules.isEmpty)
        XCTAssertTrue(restored.cue(ids[0])?.rules.isEmpty ?? false)
        XCTAssertFalse(restored.cue(ids[0])?.ignoreParentRules ?? true)
        XCTAssertEqual(restored.cueLists[0].cues.count, 3)
    }

    func testDuplicateSelfReferencesRetargeted() throws {
        var (show, listID, ids) = demo()
        let originalID = UUID()
        show.updateCue(ids[0], in: listID) {
            $0.rules = [InteractionRule(id: originalID, target: .specificCue,
                                        targetID: ids[0], conditionCueID: ids[0])]
        }
        let copyID = try XCTUnwrap(show.duplicateCue(ids[0], in: listID))
        let copyRule = try XCTUnwrap(show.cue(copyID)?.rules.first)
        XCTAssertNotEqual(copyRule.id, originalID)
        XCTAssertEqual(copyRule.targetID, copyID)
        XCTAssertEqual(copyRule.conditionCueID, copyID)
    }

    func testDisabledRuleAndMissingTargetProduceNoActions() {
        var (show, _, ids) = demo()
        show.rules = [InteractionRule(enabled: false, target: .itself)]
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).isEmpty)
        show.rules = [InteractionRule(target: .specificCue, targetID: UUID())]
        XCTAssertTrue(RulePlanner.commands(for: .ending, source: ids[0], in: show, states: [:]).isEmpty)
    }
}
