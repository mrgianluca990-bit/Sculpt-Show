import XCTest
@testable import SculptShowCore
final class CueListOrderTests: XCTestCase {
    func testMovingListPreservesAllContentsAndReferences() throws {
        var show = Show(cueLists: [CueList(name: "A", cues: [Cue(name: "Song")]), CueList(name: "B"), CueList(name: "C")])
        let original = show.cueLists
        show.rules = [InteractionRule(target: .cueList, targetID: original[0].id)]
        XCTAssertTrue(show.moveList(original[2].id, before: original[0].id))
        XCTAssertEqual(show.cueLists, [original[2], original[0], original[1]])
        XCTAssertEqual(show.rules[0].targetID, original[0].id)
        XCTAssertTrue(show.moveList(original[2].id, before: nil))
        XCTAssertEqual(show.cueLists, original)
        XCTAssertEqual(try ShowCodec.decode(ShowCodec.encode(show)), show)
    }
    func testInvalidAndNoOpMovesDoNotChangeShow() {
        var show = Show(cueLists: [CueList(name: "A"), CueList(name: "B")]); let original = show
        XCTAssertFalse(show.moveList(UUID(), before: nil))
        XCTAssertFalse(show.moveList(show.cueLists[0].id, before: UUID()))
        XCTAssertFalse(show.moveList(show.cueLists[0].id, before: show.cueLists[0].id))
        XCTAssertFalse(show.moveList(show.cueLists[1].id, before: nil))
        XCTAssertEqual(show, original)
    }
}
