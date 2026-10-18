#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// Prepare before scheduling playback. The render thread repeats this immutable
/// buffer itself, independently of UI timers, file I/O and other cue launches.
public enum NativeLoopBuffer {
    public enum Failure: Error { case invalidRange, allocation, shortRead }
    public static func prepare(file: AVAudioFile, start: Double, end: Double) throws -> AVAudioPCMBuffer {
        let rate = file.processingFormat.sampleRate
        guard start.isFinite, end.isFinite, start >= 0, end > start, rate > 0,
              end * rate <= Double(file.length) else { throw Failure.invalidRange }
        let first = AVAudioFramePosition((start * rate).rounded())
        let last = AVAudioFramePosition((end * rate).rounded())
        let count = last - first
        guard count > 0, count <= Int64(UInt32.max),
              Double(count) * Double(file.processingFormat.channelCount) * 4 <= 128 * 1024 * 1024 else {
            throw Failure.invalidRange
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)) else { throw Failure.allocation }
        let previous = file.framePosition
        defer { file.framePosition = previous }
        file.framePosition = first
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength == AVAudioFrameCount(count) else { throw Failure.shortRead }
        return buffer
    }
}
#endif
