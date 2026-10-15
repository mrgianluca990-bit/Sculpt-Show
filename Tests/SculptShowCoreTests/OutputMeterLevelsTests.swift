import XCTest
@testable import SculptShowCore

final class OutputMeterLevelsTests: XCTestCase {
    func testSilence() {
        XCTAssertEqual(OutputMeterLevels.measure([0, 0, 0]).peak, 0)
        XCTAssertEqual(OutputMeterLevels.measure([0, 0, 0]).rms, 0)
        XCTAssertEqual(OutputMeterLevels.dBFS(0), -90)
    }

    func testTrueMeasuredPeakRMS() {
        let measured = OutputMeterLevels.measure([-1, 0, 1, 0])
        XCTAssertEqual(measured.peak, 1)
        XCTAssertEqual(measured.rms, Float(0.5).squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(OutputMeterLevels.dBFS(1), 0, accuracy: 0.0001)
    }

    func testMeterScale() {
        XCTAssertEqual(OutputMeterLevels.normalized(1), 1)
        XCTAssertEqual(OutputMeterLevels.normalized(0), 0)
        XCTAssertEqual(OutputMeterLevels.normalized(0.001), 0, accuracy: 0.001)
        XCTAssertGreaterThan(OutputMeterLevels.normalized(0.1), 0)
        XCTAssertEqual(OutputMeterLevels.dBFS(.nan), -90)
    }
}
