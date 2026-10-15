import XCTest
@testable import SculptShowCore

final class AudioStartPlannerTests: XCTestCase {
    func testSameOffsetProducesSameStartTime() throws {
        let first = try XCTUnwrap(AudioStartPlanner.instruction(
            elementOffset: 0, sourceIn: 0, sourceOut: 60, cuePosition: 0))
        let second = try XCTUnwrap(AudioStartPlanner.instruction(
            elementOffset: 0, sourceIn: 5, sourceOut: 65, cuePosition: 0))
        XCTAssertEqual(first.delayFromCueAnchor, 0)
        XCTAssertEqual(first.delayFromCueAnchor, second.delayFromCueAnchor)
        XCTAssertEqual(second.positionInFile, 5)
    }

    func testLateElementSchedulesAgainstCueAnchor() throws {
        let late = try XCTUnwrap(AudioStartPlanner.instruction(
            elementOffset: 3.125, sourceIn: 0.5, sourceOut: 5, cuePosition: 0))
        XCTAssertEqual(late.delayFromCueAnchor, 3.125, accuracy: 0.0001)
        XCTAssertEqual(late.positionInFile, 0.5)
    }

    func testSeekIntoActiveElementSeeksFilePosition() throws {
        let active = try XCTUnwrap(AudioStartPlanner.instruction(
            elementOffset: 2, sourceIn: 5, sourceOut: 15, cuePosition: 7))
        XCTAssertEqual(active.positionInFile, 10)
        XCTAssertEqual(active.delayFromCueAnchor, 0)
    }

    func testSeekBeforeElementPreservesFutureStart() throws {
        let future = try XCTUnwrap(AudioStartPlanner.instruction(
            elementOffset: 12, sourceIn: 4, sourceOut: 20, cuePosition: 7.5))
        XCTAssertEqual(future.positionInFile, 4)
        XCTAssertEqual(future.delayFromCueAnchor, 4.5)
    }

    func testAfterOutPointDoesNotSchedule() {
        XCTAssertNil(AudioStartPlanner.instruction(
            elementOffset: 1, sourceIn: 3, sourceOut: 8, cuePosition: 6))
    }

    func testInvalidSourceWindowDoesNotSchedule() {
        XCTAssertNil(AudioStartPlanner.instruction(
            elementOffset: 0, sourceIn: 10, sourceOut: 3, cuePosition: 0))
    }
}
