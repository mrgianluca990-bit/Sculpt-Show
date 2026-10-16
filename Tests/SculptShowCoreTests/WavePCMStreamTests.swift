import Foundation
import XCTest
@testable import SculptShowCore

final class WavePCMStreamTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SculptPCM-\(UUID().uuidString).wav")
    }

    private func encode16(_ sample: Int16) -> [UInt8] {
        let s = UInt16(bitPattern: sample)
        return [UInt8(truncatingIfNeeded: s), UInt8(truncatingIfNeeded: s >> 8)]
    }
    private func encode24(_ sample: Int32) -> [UInt8] {
        let x = UInt32(bitPattern: sample)
        return [0, 8, 16].map { UInt8(truncatingIfNeeded: x >> $0) }
    }
    private func le16(_ x: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8)] }
    private func le32(_ x: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: x >> ($0*8)) } }

    /// Plain RIFF/WAV PCM with an extra non-audio chunk before data.
    private func pcmFixture(bits: Int, channels: Int, samples: [Int32], extraChunk: Bool = false) throws -> URL {
        let url = tempURL()
        let bytesPerFrame = channels * (bits / 8)
        let sampleBytes = samples.flatMap { bits == 16 ? encode16(Int16(truncatingIfNeeded: $0)) : encode24($0) }
        var body: [UInt8] = []
        body += Array("fmt ".utf8) + le32(16)
        body += le16(1) + le16(UInt16(channels)) + le32(48000)
        body += le32(UInt32(48000 * bytesPerFrame)) + le16(UInt16(bytesPerFrame)) + le16(UInt16(bits))
        if extraChunk { body += Array("JUNK".utf8) + le32(5) + [1,2,3,4,5,0] }
        body += Array("data".utf8) + le32(UInt32(sampleBytes.count)) + sampleBytes
        var riff: [UInt8] = Array("RIFF".utf8) + le32(UInt32(body.count + 4)) + Array("WAVE".utf8)
        riff += body
        try Data(riff).write(to: url)
        return url
    }

    func testStereoFloatWriterAndReadBackPreservesChannelsAndGain() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WaveFloat32Writer(url: url, sampleRate: 48000, channels: 2)
        let frames: [[Float]] = [[0.25, -0.5, 0.75, 0], [-0.25, 0.5, -0.75, 0]]
        try w.append(planar: frames, gain: 2, peakCeiling: 0.9)
        try w.finalize()
        XCTAssertEqual(w.frameCount, 4)
        let reader = try WavePCMReader(url: url)
        XCTAssertEqual(reader.channels, 2)
        XCTAssertEqual(reader.sampleRate, 48000)
        XCTAssertEqual(reader.frameCount, 4)
        let pcm = try reader.readFrames(maxFrames: 2)
        XCTAssertEqual(pcm[0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(pcm[0][1], -0.9, accuracy: 1e-5)
        XCTAssertEqual(pcm[1][0], -0.5, accuracy: 1e-6)
        XCTAssertEqual(pcm[1][1], 0.9, accuracy: 1e-5)
        let next = try reader.readFrames(maxFrames: 8)
        XCTAssertEqual(next[0].count, 2)
        XCTAssertEqual(next[0][0], 0.9, accuracy: 1e-5)
        XCTAssertTrue(try reader.readFrames().allSatisfy(\.isEmpty))
    }

    func testReadMono16BitAndSkipJunkChunk() throws {
        let url = try pcmFixture(bits: 16, channels: 1, samples: [0, -32768, 16384, 32767], extraChunk: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try WavePCMReader(url: url)
        XCTAssertEqual(reader.frameCount, 4)
        let pcm = try reader.readFrames()
        XCTAssertEqual(pcm[0][1], -1, accuracy: 1e-6)
        XCTAssertEqual(pcm[0][2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(pcm[0][3], 32767.0/32768.0, accuracy: 1e-6)
    }

    func testReadStereo24BitKeepsIndividualChannels() throws {
        let url = try pcmFixture(bits: 24, channels: 2, samples: [4194304, -4194304, 0, -8388608])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try WavePCMReader(url: url)
        XCTAssertEqual(reader.frameCount, 2)
        let pcm = try reader.readFrames()
        XCTAssertEqual(pcm[0], [0.5, 0])
        XCTAssertEqual(pcm[1], [-0.5, -1])
    }

    func testTruncatedWavProducesDiagnosticNotGenericObjCError() throws {
        let url = try pcmFixture(bits: 16, channels: 1, samples: [1000])
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = try Data(contentsOf: url)
        bytes.removeLast()
        try bytes.write(to: url)
        XCTAssertThrowsError(try WavePCMReader(url: url)) { error in
            XCTAssertTrue(error is WavePCMFailure)
        }
    }

    func testExistingProjectWAVSamplesDecodeToExpectedDuration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let names = ["TestTone_A440.wav", "TestTone_C523.wav", "LTC_25fps_01h_demo.wav"]
        for name in names {
            let reader = try WavePCMReader(url: root.appendingPathComponent("Samples/" + name))
            XCTAssertEqual(reader.channels, 1)
            XCTAssertGreaterThan(reader.frameCount, 80_000)
            var n: Int64 = 0
            while true {
                let chunk = try reader.readFrames()
                guard let first = chunk.first, !first.isEmpty else { break }
                n += Int64(first.count)
            }
            XCTAssertEqual(n, reader.frameCount)
        }
    }

    func testNormalizeAQuietStereoFileAndVerifyActualLUFS() throws {
        let url = tempURL()
        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        let writer = try WaveFloat32Writer(url: url, sampleRate: 48000, channels: 2)
        for chunk in 0..<20 {
            let left = (0..<4800).map { f in Float(0.02 * sin(2 * Double.pi * 440 * Double(chunk * 4800 + f) / 48000)) }
            let pcm = [left, left]
            try writer.append(planar: pcm, gain: 1)
        }
        try writer.finalize()
        let r1 = try WavePCMReader(url: url)
        var beforeMeter = LoudnessMeter(sampleRate: r1.sampleRate, channels: r1.channels)
        while true {
            let part = try r1.readFrames()
            guard !part[0].isEmpty else { break }
            beforeMeter.ingest(planar: part)
        }
        let measurement = beforeMeter.measure()
        let gain = try NormalizationPlanner.gainDB(for: measurement,
            mode: .integratedLUFS, target: -18, ceilingDBFS: nil)
        XCTAssertGreaterThan(gain, 0)
        let r2 = try WavePCMReader(url: url)
        let w2 = try WaveFloat32Writer(url: out, sampleRate: r2.sampleRate, channels: r2.channels)
        while true {
            let part = try r2.readFrames()
            guard !part[0].isEmpty else { break }
            try w2.append(planar: part, gain: Float(pow(10, gain/20)))
        }
        try w2.finalize()
        let r3 = try WavePCMReader(url: out)
        var afterMeter = LoudnessMeter(sampleRate: r3.sampleRate, channels: r3.channels)
        while true {
            let part = try r3.readFrames()
            guard !part[0].isEmpty else { break }
            afterMeter.ingest(planar: part)
        }
        XCTAssertEqual(afterMeter.measure().integratedLUFS ?? -999, -18, accuracy: 0.1)
    }
}
