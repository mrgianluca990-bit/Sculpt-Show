import XCTest
@testable import SculptShowCore

final class LoudnessNormalizationTests: XCTestCase {
    private func analyze(amplitude: Float, channels: Int = 2, rate: Int = 48_000,
                         seconds: Int = 2) -> NormalizationMeasurement {
        var meter = LoudnessMeter(sampleRate: Double(rate), channels: channels)
        let block = 2400
        let signals = (0..<channels).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: block)
        }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        for ch in 0..<channels { ptrs[ch] = signals[ch] }
        defer {
            for pointer in signals { pointer.deallocate() }
            ptrs.deallocate()
        }
        for step in 0..<rate * seconds / block {
            for i in 0..<block {
                let v = amplitude * Float(sin(2 * Double.pi * 1000 * Double(step * block + i) / Double(rate)))
                for ch in 0..<channels { signals[ch][i] = v }
            }
            meter.ingest(UnsafePointer(ptrs), frames: block)
        }
        return meter.measure()
    }

    func testMeterRecognizesSilence() {
        let m = analyze(amplitude: 0)
        XCTAssertNil(m.integratedLUFS)
        XCTAssertNil(m.samplePeakDBFS)
        XCTAssertThrowsError(try NormalizationPlanner.gainDB(for: m, mode: .integratedLUFS, target: -18))
    }

    func testSinePeakAndLoudness() {
        let m = analyze(amplitude: 0.1)
        XCTAssertEqual(m.channels, 2)
        XCTAssertEqual(m.frames, 96000)
        XCTAssertEqual(m.samplePeakDBFS ?? 999, -20, accuracy: 0.05)
        XCTAssertNotNil(m.integratedLUFS)
        XCTAssertTrue((-28 ... -17).contains(m.integratedLUFS ?? 999))
    }

    func testPeakNormalizationLimitsToMinusOne() throws {
        let m = analyze(amplitude: 0.5, channels: 1)
        let gain = try NormalizationPlanner.gainDB(for: m, mode: .samplePeak,
                                                    target: -1, ceilingDBFS: -1)
        XCTAssertEqual((m.samplePeakDBFS ?? 999) + gain, -1, accuracy: 0.01)
    }

    func testLoudnessNormalizationHonorsPeakSafety() throws {
        let m = analyze(amplitude: 0.5)
        let gain = try NormalizationPlanner.gainDB(for: m, mode: .integratedLUFS,
                                                   target: -8, ceilingDBFS: -1)
        XCTAssertLessThanOrEqual((m.samplePeakDBFS ?? 999) + gain, -0.999)
    }

    func testLoudnessWithoutPeakSafetyCanBoost() throws {
        let m = analyze(amplitude: 0.01)
        let gain = try NormalizationPlanner.gainDB(for: m, mode: .integratedLUFS,
                                                   target: -18, ceilingDBFS: nil)
        XCTAssertGreaterThan(gain, 0)
        XCTAssertEqual((m.integratedLUFS ?? 999) + gain, -18, accuracy: 0.05)
    }

    func testInvalidTargetFails() {
        let m = analyze(amplitude: 0.1)
        XCTAssertThrowsError(try NormalizationPlanner.gainDB(for: m, mode: .integratedLUFS, target: .infinity))
    }
}
