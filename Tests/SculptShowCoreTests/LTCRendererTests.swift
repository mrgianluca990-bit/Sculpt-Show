import XCTest
import SculptLTCCore
@testable import SculptShowCore

final class LTCRendererTests: XCTestCase {
    func testSMPTECodewordAndParity() {
        for rate in 0...3 {
            for frame in [Int64(0), 1, 1799, 1800, 17982, 23976, 80000] {
                var bits = [UInt8](repeating: 0, count: 80)
                sculpt_ltc_codeword(frame, Int32(rate), &bits)
                XCTAssertEqual(Array(bits[64..<80]),
                    [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1])
                XCTAssertEqual(bits.reduce(0) { $0 + Int($1) } % 2, 0)
                XCTAssertEqual(bits[10], rate == 2 ? 1 : 0)
            }
        }
    }

    func testSampleAccurateStartOffsetAndSilenceAfterEnd() throws {
        let g = try XCTUnwrap(sculpt_ltc_create())
        defer { sculpt_ltc_destroy(g) }
        sculpt_ltc_start(g, 1_000_000_000, 0, 1, 0.25, 0, 1.0)
        let count = 48_000
        var audio = [Float](repeating: 0, count: count)
        audio.withUnsafeMutableBufferPointer { ptr in
            sculpt_ltc_render(g, 1_000_000_000, 48_000, ptr.baseAddress, UInt32(count))
        }
        XCTAssertTrue(audio[0..<12_000].allSatisfy { $0 == 0 })
        XCTAssertTrue(audio[12_000..<48_000].allSatisfy { abs($0) > 0.2 })
        let transitions = (12_001..<48_000).filter { (audio[$0] > 0) != (audio[$0-1] > 0) }
        XCTAssertGreaterThan(transitions.count, 1200)
        XCTAssertLessThan(transitions.count, 3300)
        var last = [Float](repeating: -1, count: 100)
        last.withUnsafeMutableBufferPointer { ptr in
            sculpt_ltc_render(g, 2_010_000_000, 48_000, ptr.baseAddress, 100)
        }
        XCTAssertTrue(last.allSatisfy { $0 == 0 })
        sculpt_ltc_stop(g)
        audio.withUnsafeMutableBufferPointer { ptr in
            sculpt_ltc_render(g, 1_300_000_000, 48_000, ptr.baseAddress, UInt32(count))
        }
        XCTAssertTrue(audio.allSatisfy { $0 == 0 })
    }
}

extension LTCRendererTests {
    func testLTCEncodedPCMCanBeDecodedFromAudioInput() throws {
        let gen = try XCTUnwrap(sculpt_ltc_create())
        defer { sculpt_ltc_destroy(gen) }
        let dec = try XCTUnwrap(sculpt_ltc_decoder_create(48_000, 1))
        defer { sculpt_ltc_decoder_destroy(dec) }
        let address = try XCTUnwrap(LTCTimecode(text: "01:02:03:04", rate: .fps25))
        sculpt_ltc_start(gen, 1_000_000_000, address.absoluteFrames, 1, 0, 0, 1.0)
        var audio = [Float](repeating: 0, count: 48_000)
        audio.withUnsafeMutableBufferPointer { p in
            sculpt_ltc_render(gen, 1_000_000_000, 48_000, p.baseAddress, UInt32(p.count))
        }
        var result = SculptLTCAddress()
        var decoded = false
        var firstDecoded: SculptLTCAddress?
        for offset in stride(from: 0, to: audio.count, by: 1024) {
            let end = min(offset+1024, audio.count)
            let found = audio.withUnsafeBufferPointer { p in
                sculpt_ltc_decoder_consume(dec, p.baseAddress!.advanced(by: offset),
                                           UInt32(end-offset), &result)
            }
            if found != 0 { decoded = true; if firstDecoded == nil { firstDecoded = result } }
        }
        XCTAssertTrue(decoded, "LTC receiver should lock to the actual encoded PCM signal")
        XCTAssertEqual(result.hours, 1)
        XCTAssertEqual(result.minutes, 2)
        XCTAssertEqual(firstDecoded?.seconds, 3)
        XCTAssertEqual(result.seconds, 4)
        XCTAssertGreaterThanOrEqual(result.frames, 0)
        XCTAssertLessThan(result.frames, 25)
    }
}

extension LTCRendererTests {
    func testAllFourRatesDecodeActualOutput() throws {
        for rate in 0...3 {
            let g = try XCTUnwrap(sculpt_ltc_create())
            let d = try XCTUnwrap(sculpt_ltc_decoder_create(48_000, Int32(rate)))
            defer { sculpt_ltc_destroy(g); sculpt_ltc_decoder_destroy(d) }
            sculpt_ltc_start(g, 1_000_000_000, 0, Int32(rate), 0, 0, 0.5)
            var samples = [Float](repeating: 0, count: 24_000)
            samples.withUnsafeMutableBufferPointer { p in
                sculpt_ltc_render(g, 1_000_000_000, 48_000, p.baseAddress, UInt32(p.count))
            }
            var decoded = SculptLTCAddress()
            let found = samples.withUnsafeBufferPointer { p in
                sculpt_ltc_decoder_consume(d, p.baseAddress, UInt32(p.count), &decoded)
            }
            XCTAssertEqual(found, 1, "Expected LTC lock at rate index \(rate)")
            XCTAssertEqual(decoded.hours, 0)
            XCTAssertEqual(decoded.minutes, 0)
            XCTAssertEqual(decoded.seconds, 0)
            XCTAssertEqual(decoded.drop_frame, rate == 2 ? 1 : 0)
        }
    }
}
