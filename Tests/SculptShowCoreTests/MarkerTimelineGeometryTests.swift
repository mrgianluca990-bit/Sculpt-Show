import XCTest
@testable import SculptShowCore

final class MarkerTimelineGeometryTests: XCTestCase {
    func testClampedAndSnappedPlacement() {
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: 250, width: 1000, duration: 40, snap: 1), 10)
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: 257, width: 1000, duration: 40, snap: 0.1), 10.3)
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: -40, width: 1000, duration: 40), 0)
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: 9000, width: 1000, duration: 40), 40)
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: .nan, width: 1000, duration: 40), 0)
        XCTAssertEqual(MarkerTimelineGeometry.clampedTime(x: 100, width: 0, duration: 40), 0)
    }

    func testMarkerNavigation() {
        let m1 = CueMarker(name: "First", positionSeconds: 2)
        let m2 = CueMarker(name: "Second", positionSeconds: 9)
        let m3 = CueMarker(name: "Third", positionSeconds: 20)
        let markers = [m2, m3, m1]
        XCTAssertEqual(MarkerTimelineGeometry.adjacent(to: 9, markers: markers, forward: true)?.id, m3.id)
        XCTAssertEqual(MarkerTimelineGeometry.adjacent(to: 9, markers: markers, forward: false)?.id, m1.id)
        XCTAssertNil(MarkerTimelineGeometry.adjacent(to: 20, markers: markers, forward: true))
        XCTAssertNil(MarkerTimelineGeometry.adjacent(to: 2, markers: markers, forward: false))
        XCTAssertEqual(MarkerTimelineGeometry.x(time: 10, width: 800, duration: 40), 200)
    }
}
