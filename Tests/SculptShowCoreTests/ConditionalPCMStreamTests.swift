#if canImport(AVFAudio)
import XCTest
import AVFAudio
import SculptLTCCore
@testable import SculptShowCore

final class ConditionalPCMStreamTests: XCTestCase {
    private func sample(_ frame: Int, _ channel: Int) -> Float { Float(frame % 1021) / 8192 + Float(channel) / 8 }
    private func fixture(_ url: URL, frames: Int, rate: Double = 48000, channels: AVAudioChannelCount = 2) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        let data = try XCTUnwrap(chunk.floatChannelData)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var first = 0
        while first < frames {
            chunk.frameLength = AVAudioFrameCount(min(8192, frames - first))
            for c in 0..<Int(channels) { for i in 0..<Int(chunk.frameLength) { data[c][i] = sample(first + i, c) } }
            try file.write(from: chunk); first += Int(chunk.frameLength)
        }
    }
    func testSevenBoundedStreamsRepeatAndExitWithoutLostOrDuplicatedSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(url, frames: 200000)
        let streams = try (0..<7).map { _ in try ConditionalPCMStream(path: url.path, sampleRate: 48000, loopIn: 32000, loopOut: 80000, from: 0) }
        XCTAssertEqual(streams.reduce(UInt64(0)) { $0 + $1.allocatedBytes }, 7 * 4 * 1024 * 1024)
        let condition = try XCTUnwrap(sculpt_signal_create())
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 32000, 80000, 200000, condition, 1, nil))
        defer { sculpt_loop_destroy(loop); sculpt_signal_destroy(condition) }
        for i in 0..<7 { XCTAssertTrue(sculpt_loop_stream_voice(loop, UInt32(i), streams[i].pointer)) }
        sculpt_signal_set(condition, 1, 0, UInt64.max); sculpt_loop_arm(loop, 0, 0)
        var left = [Float](repeating: 0, count: 512); var right = left
        for first in stride(from: 0, to: 320000, by: 512) {
            if first >= 131072 { sculpt_signal_phase(condition, 0) }
            for stream in streams { try stream.refill() }
            for voice in 0..<7 {
                sculpt_loop_render_frames(loop, UInt32(voice), Int64(first), 512, &left, &right)
                for i in 0..<512 {
                    let frame = first + i
                    let source = frame < 80000 ? frame : (frame < 176000 ? 32000 + (frame - 80000) % 48000 : frame - 96000)
                    XCTAssertEqual(left[i], source < 200000 ? sample(source, 0) : 0)
                    XCTAssertEqual(right[i], source < 200000 ? sample(source, 1) : 0)
                }
            }
            XCTAssertEqual(sculpt_loop_failure(loop), 0)
        }
    }
    func testSeekIsPrewarmedAndMonoRightChannelRemainsSilent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(url, frames: 200000, channels: 1)
        let stream = try ConditionalPCMStream(path: url.path, sampleRate: 48000, loopIn: 32000, loopOut: 160000, from: 120000)
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 32000, 160000, 200000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop) }
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream.pointer)); sculpt_loop_arm(loop, 0, 120000)
        var left = [Float](repeating: 0, count: 1024); var right = left
        sculpt_loop_render_frames(loop, 0, 120000, 1024, &left, &right)
        XCTAssertEqual(left, (120000..<121024).map { sample($0, 0) }); XCTAssertEqual(right, [Float](repeating: 0, count: 1024))
        XCTAssertEqual(sculpt_loop_failure(loop), 0)
    }
    func testUnavailablePageLatchesFailureInsteadOfReplayingStaleAudio() throws {
        let stream = try XCTUnwrap(sculpt_stream_create(1, 1000000, 0))
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 20000, 40000, 1000000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop); sculpt_stream_destroy(stream) }
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream)); sculpt_loop_arm(loop, 0, 0)
        var left = [Float](repeating: 1, count: 64); var right = left
        sculpt_loop_render_frames(loop, 0, 0, 64, &left, &right)
        XCTAssertEqual(sculpt_loop_failure(loop), 1)
        XCTAssertEqual(left, [Float](repeating: 0, count: 64))
        sculpt_stream_fail(stream)
        sculpt_loop_render_frames(loop, 0, 64, 64, &left, &right)
        XCTAssertNotEqual(sculpt_loop_failure(loop), 0)
    }
    func testDiskReadFailureIsReportedSeparately() throws {
        let stream = try XCTUnwrap(sculpt_stream_create(1, 1000, 0))
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 100, 200, 1000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop); sculpt_stream_destroy(stream) }
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream)); sculpt_loop_arm(loop, 0, 0); sculpt_stream_fail(stream)
        var left = [Float](repeating: 1, count: 64); var right = left
        sculpt_loop_render_frames(loop, 0, 0, 64, &left, &right)
        XCTAssertEqual(sculpt_loop_failure(loop), 2)
        XCTAssertEqual(left, [Float](repeating: 0, count: 64))
    }
    func testFileLargerThanOld512MiBBudgetHasConstantCacheAllocation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // Valid sparse IEEE-float WAV: 800 MB logically, only its header and
        // prefetched pages are touched. No enormous test allocation or disk write.
        let count: UInt32 = 200000000; var header = Data()
        func text(_ s: String) { header.append(Data(s.utf8)) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + count * 4); text("WAVEfmt "); u32(16); u16(3); u16(1)
        u32(48000); u32(48000 * 4); u16(4); u16(32); text("data"); u32(count * 4)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(44) + UInt64(count) * 4); try handle.close()
        let stream = try ConditionalPCMStream(path: url.path, sampleRate: 48000, loopIn: 120000000, loopOut: 120048000, from: 0)
        XCTAssertEqual(stream.frames, Int64(count)); XCTAssertEqual(stream.allocatedBytes, 2 * 1024 * 1024)
        XCTAssertThrowsError(try ConditionalPCMStream(path: url.path, sampleRate: 96000, loopIn: 0, loopOut: 48000, from: 0))
    }
    func testPagesAreRecycledWhileTraversingFileLargerThanCache() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(url, frames: 1500000, channels: 1)
        let stream = try ConditionalPCMStream(path: url.path, sampleRate: 48000, loopIn: 10000, loopOut: 20000, from: 0)
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 10000, 20000, 1500000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop) }
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream.pointer)); sculpt_loop_arm(loop, 0, 0)
        var left = [Float](repeating: 0, count: 8192); var right = left
        for first in stride(from: 0, to: 1500000, by: 8192) {
            try stream.refill()
            let count = min(8192, 1500000 - first)
            sculpt_loop_render_frames(loop, 0, Int64(first), UInt32(count), &left, &right)
            XCTAssertEqual(Array(left.prefix(count)), (first..<(first + count)).map { sample($0, 0) })
            XCTAssertEqual(sculpt_loop_failure(loop), 0)
        }
        XCTAssertEqual(stream.allocatedBytes, 2 * 1024 * 1024)
    }
    func testBackgroundWorkerFeedsRendererBeyondInitialLookahead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(url, frames: 120000, channels: 1)
        let stream = try ConditionalPCMStream(path: url.path, sampleRate: 48000, loopIn: 90000, loopOut: 100000, from: 0)
        let loop = try XCTUnwrap(sculpt_loop_create(48000, 90000, 100000, 120000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop) }
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream.pointer)); sculpt_loop_arm(loop, 0, 0)
        stream.start()
        var left = [Float](repeating: 0, count: 1024); var right = left
        for first in stride(from: 0, to: 48000, by: 1024) {
            sculpt_loop_render_frames(loop, 0, Int64(first), 1024, &left, &right)
            XCTAssertEqual(left, (first..<(first + 1024)).map { sample($0, 0) })
            XCTAssertEqual(sculpt_loop_failure(loop), 0)
            Thread.sleep(forTimeInterval: 0.022)
        }
    }
    func testHighRateLookaheadAndSeekRemainWithinFixedCapacity() throws {
        for rate in [44100, 96000, 192000] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try fixture(url, frames: 600000, rate: Double(rate))
            let stream = try ConditionalPCMStream(path: url.path, sampleRate: rate, loopIn: 200000, loopOut: 400000, from: 300000)
            let loop = try XCTUnwrap(sculpt_loop_create(Double(rate), 200000, 400000, 600000, nil, 0, nil))
            defer { sculpt_loop_destroy(loop) }
            XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream.pointer)); sculpt_loop_arm(loop, 0, 300000)
            var left = [Float](repeating: 0, count: 4096); var right = left
            sculpt_loop_render_frames(loop, 0, 300000, 4096, &left, &right)
            XCTAssertEqual(left, (300000..<304096).map { sample($0, 0) })
            XCTAssertEqual(right, (300000..<304096).map { sample($0, 1) })
            XCTAssertEqual(sculpt_loop_failure(loop), 0); XCTAssertEqual(stream.allocatedBytes, 4 * 1024 * 1024)
        }
    }
    func testCacheUses64BitPositions() throws {
        let start: Int64 = 1 << 34
        let stream = try XCTUnwrap(sculpt_stream_create(2, start + 100000, start))
        let loop = try XCTUnwrap(sculpt_loop_create(48000, start, start + 10000, start + 100000, nil, 0, nil))
        defer { sculpt_loop_destroy(loop); sculpt_stream_destroy(stream) }
        let left = [Float](repeating: 0.25, count: 8192); let right = [Float](repeating: -0.25, count: 8192)
        XCTAssertTrue(sculpt_stream_publish(stream, start, left, right, 8192, nil, 0))
        XCTAssertTrue(sculpt_loop_stream_voice(loop, 0, stream)); sculpt_loop_arm(loop, 0, start)
        var out = [Float](repeating: 0, count: 64); var outR = out
        sculpt_loop_render_frames(loop, 0, start, 64, &out, &outR)
        XCTAssertEqual(out, [Float](repeating: 0.25, count: 64)); XCTAssertEqual(outR, [Float](repeating: -0.25, count: 64))
        XCTAssertEqual(sculpt_loop_failure(loop), 0)
    }
}
#endif
