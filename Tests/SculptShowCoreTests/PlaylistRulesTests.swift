import XCTest
@testable import SculptShowCore

final class PlaylistRulesTests: XCTestCase {
    func testStartingFadeExcludesNewSongAndStaysInsideList() throws {
        let songs = [Cue(name: "A"), Cue(name: "B"), Cue(name: "C")]
        var list = CueList(name: "Playlist", cues: songs)
        list.rules = [InteractionRule(event: .starting, action: .fade, target: .cueList,
            targetID: list.id, fadeSeconds: 3, excludeSource: true)]
        let show = Show(cueLists: [list, CueList(name: "Other", cues: [Cue(name: "Bed")])])
        let commands = RulePlanner.commands(for: .starting, source: songs[1].id, in: show, states: [:])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].targets, [songs[0].id, songs[2].id])
        XCTAssertEqual(commands[0].rule.fadeSeconds, 3)
        let saved = try ShowCodec.decode(ShowCodec.encode(show))
        XCTAssertEqual(saved, show)
    }
    func testAllCuesIsLegacyOnlyAndOldRulesDecode() throws {
        XCTAssertFalse(RuleTarget.allCases.contains(.allCues))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(InteractionRule(target: .allCues))) as? [String: Any])
        json.removeValue(forKey: "excludeSource")
        let rule = try JSONDecoder().decode(InteractionRule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(rule.target, .allCues)
        XCTAssertNil(rule.excludeSource)
    }
    func testSequentialRepeatAndSkipDisabled() {
        var list = CueList(name: "Playlist", cues: [Cue(name: "A"), Cue(name: "Skip"), Cue(name: "B")])
        list.cues[1].enabled = false
        var order = PlaylistOrder()
        XCTAssertEqual(order.next(in: list, after: list.cues[0].id), list.cues[2].id)
        XCTAssertNil(order.next(in: list, after: list.cues[2].id))
        list.repeatAll = true
        XCTAssertEqual(order.next(in: list, after: list.cues[2].id), list.cues[0].id)
    }
    func testRandomRoundHasNoRepeatsAndRepeatAllAvoidsImmediateRepeat() throws {
        var list = CueList(name: "Random", cues: (0..<6).map { Cue(name: "Song \($0)") })
        list.randomOrder = true
        var order = PlaylistOrder()
        var played: [UUID] = []
        var current: UUID?
        for _ in 0..<6 {
            current = try XCTUnwrap(order.next(in: list, after: current))
            played.append(try XCTUnwrap(current))
        }
        XCTAssertEqual(Set(played), Set(list.cues.map(\.id)))
        XCTAssertNil(order.next(in: list, after: current))
        list.repeatAll = true
        XCTAssertNotEqual(try XCTUnwrap(order.next(in: list, after: current)), current)
    }
    func testPlaylistOptionsPersistAndLegacyDefaultsAreOff() throws {
        var list = CueList(name: "Playlist")
        list.randomOrder = true; list.repeatAll = true
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(Show(cueLists: [list]))).cueLists[0], list)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        json.removeValue(forKey: "randomOrder"); json.removeValue(forKey: "repeatAll")
        let legacy = try JSONDecoder().decode(CueList.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(legacy.randomOrder); XCTAssertFalse(legacy.repeatAll)
    }
    func testSingleAndEmptyRandomRepeatingLists() {
        var list = CueList(name: "Single", cues: [Cue(name: "Only")]); list.randomOrder = true; list.repeatAll = true
        var order = PlaylistOrder()
        XCTAssertEqual(order.next(in: list, after: list.cues[0].id), list.cues[0].id)
        list.cues.removeAll()
        XCTAssertNil(order.next(in: list, after: nil))
    }
}
