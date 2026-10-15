import AVFAudio
import AudioToolbox
import SculptLTCCore

/// Holds the lock-free C transport state for the full lifetime of a Core Audio
/// source-node render block. It must outlive the engine callback during teardown.
final class LTCRealtimeState {
    let pointer: OpaquePointer
    init?() {
        guard let instance = sculpt_ltc_create() else { return nil }
        pointer = instance
    }
    deinit { sculpt_ltc_stop(pointer); sculpt_ltc_destroy(pointer) }

    func render(timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: AVAudioFrameCount,
                outputData: UnsafeMutablePointer<AudioBufferList>,
                sampleRate: Float) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        // CoreAudioTypes defines kAudioTimeStampHostTimeValid as bit 1 (0x02).
        // The named C constant is not always surfaced in Swift's SDK imports.
        let validHostTime = (timestamp.pointee.mFlags & 0x02) != 0
        let hostNanos: UInt64 = validHostTime
            ? AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime) : 0
        for (index, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            if index == 0 && buffer.mNumberChannels == 1 {
                sculpt_ltc_render(pointer, hostNanos, sampleRate, samples, frameCount)
            } else {
                samples.update(repeating: 0,
                    count: Int(frameCount) * Int(buffer.mNumberChannels))
            }
        }
    }
}
