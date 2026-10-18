#if canImport(AVFAudio)
import AVFAudio
import XCTest
import SculptLTCCore

final class ConditionalLoopEngineTests: XCTestCase {
    func testSevenSourceNodesAndSecondCueExitWithoutGapOrCrossStemDrift() throws {
        let condition = try XCTUnwrap(sculpt_signal_create())
        defer { sculpt_signal_destroy(condition) }
        let transport = try XCTUnwrap(sculpt_loop_create(48000, 32, 96, 192, condition, 1, nil))
        defer { sculpt_loop_destroy(transport) }
        sculpt_signal_set(condition, 1, 0, UInt64.max)
        sculpt_loop_arm(transport, 0, 0)
        let sources = (0..<7).map { voice -> UnsafeMutablePointer<Float> in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 192)
            for frame in 0..<192 { samples[frame] = Float(voice + 1) * 0.001 + Float(frame) * 0.00001 }
            return samples
        }
        defer { for samples in sources { samples.deallocate() } }
        let slots = try (0..<7).map { try XCTUnwrap(sculpt_loop_slot_create(UInt32($0))) }
        defer { for slot in slots { sculpt_loop_slot_destroy(slot) } }
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        for voice in 0..<7 {
            XCTAssertTrue(sculpt_loop_voice(transport, UInt32(voice), sources[voice], nil, 192))
            sculpt_loop_slot_bind(slots[voice], transport)
            let slot = slots[voice]
            let node = AVAudioSourceNode(format: format) { _, timestamp, count, data in
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return -1 }
                let frame = Int64(timestamp.pointee.mSampleTime.rounded())
                let host = UInt64(max(0, Double(frame) / 48000 * 1e9).rounded())
                sculpt_loop_slot_render(slot, host, frame, count,
                    left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        let other = AVAudioPlayerNode()
        engine.attach(other)
        engine.connect(other, to: engine.mainMixerNode, format: format)
        let bed = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        bed.frameLength = 64
        let samples = try XCTUnwrap(bed.floatChannelData)
        for channel in 0..<2 { for i in 0..<64 { samples[channel][i] = 0.05 } }
        other.scheduleBuffer(bed, at: nil, options: .loops, completionHandler: nil)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 64)
        try engine.start()
        defer {
            engine.stop()
            for slot in slots { sculpt_loop_slot_bind(slot, nil) }
        }
        other.play()
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        for block in 0..<8 {
            if block == 4 { sculpt_signal_phase(condition, 0) }
            XCTAssertEqual(try engine.renderOffline(64, to: pcm), .success)
            let data = try XCTUnwrap(pcm.floatChannelData)
            for i in 0..<64 {
                let frame = block * 64 + i
                let position = frame < 96 ? frame : (frame < 288 ? 32 + (frame - 96) % 64 : frame - 192)
                let signal = position < 192 ? (1...7).reduce(Float(0)) { $0 + Float($1) * 0.001 + Float(position) * 0.00001 } : 0
                XCTAssertEqual(data[0][i], 0.05 + signal, accuracy: 0.00001, "Frame \(frame)")
                XCTAssertEqual(data[1][i], 0.05, accuracy: 0.00001, "The independent cue must keep playing")
            }
        }
    }
}
#endif
