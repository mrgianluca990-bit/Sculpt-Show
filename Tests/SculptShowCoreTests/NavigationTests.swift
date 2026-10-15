import XCTest
@testable import SculptShowCore

final class NavigationTests: XCTestCase {
    func testOneSelectionCanMoveForwardAndBackSkippingDisabledCues() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let ids = show.addAudio([
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/b.wav"),
            URL(fileURLWithPath: "/tmp/c.wav")
        ], to: list)
        show.updateCue(ids[1], in: list) { $0.enabled = false }
        XCTAssertEqual(CueNavigator.neighbor(in: show, listID: list, selectedCueID: nil, direction: 1), ids[0])
        XCTAssertEqual(CueNavigator.neighbor(in: show, listID: list, selectedCueID: ids[0], direction: 1), ids[2])
        XCTAssertEqual(CueNavigator.neighbor(in: show, listID: list, selectedCueID: ids[2], direction: -1), ids[0])
    }

    func testNavigationStopsAtFirstAndLastCue() throws {
        var show = Show()
        let list = try XCTUnwrap(show.cueLists.first?.id)
        let ids = show.addAudio([URL(fileURLWithPath: "/tmp/a.wav")], to: list)
        XCTAssertNil(CueNavigator.neighbor(in: show, listID: list, selectedCueID: ids[0], direction: 1))
        XCTAssertNil(CueNavigator.neighbor(in: show, listID: list, selectedCueID: ids[0], direction: -1))
        XCTAssertEqual(CueNavigator.neighbor(in: show, listID: list, selectedCueID: nil, direction: -1), ids[0])
    }

    func testNextListCyclesBetweenLists() {
        var show = Show()
        let first = show.cueLists[0].id
        let second = show.addList(name: "FX")
        let third = show.addList(name: "Music")
        XCTAssertEqual(CueNavigator.nextList(in: show, currentListID: first), second)
        XCTAssertEqual(CueNavigator.nextList(in: show, currentListID: second), third)
        XCTAssertEqual(CueNavigator.nextList(in: show, currentListID: third), first)
    }

    func testMovingAcrossListsKeepsCueIdentityAndRulesAndNavigation() throws {
        var show = Show()
        let from = show.cueLists[0].id
        let to = show.addList(name: "Second")
        let ids = show.addAudio([URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.wav")], to: from)
        let rule = InteractionRule(event: .ending, action: .stop, target: .itself)
        show.updateCue(ids[0], in: from) { $0.rules = [rule] }
        XCTAssertTrue(show.relocateCue(ids[0], to: to, before: nil))
        XCTAssertEqual(show.cue(ids[0])?.rules, [rule])
        XCTAssertEqual(show.cueLists[0].cues.map(\.id), [ids[1]])
        XCTAssertEqual(show.cueLists[1].cues.map(\.id), [ids[0]])
        XCTAssertEqual(CueNavigator.neighbor(in: show, listID: to, selectedCueID: nil, direction: 1), ids[0])
    }
}
