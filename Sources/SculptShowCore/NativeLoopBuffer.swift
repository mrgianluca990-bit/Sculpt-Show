#if canImport(AVFAudio)
import AVFAudio
import Foundation

/// Prepare before scheduling playback. The render thread repeats this immutable
/// buffer itself, independently of UI timers, file I/O and other cue launches.
public enum NativeLoopBuffer {
    public enum Failure: Error { case invalidRange, allocation, shortRead }
    public static func prepare(file: AVAudioFile, start: Double, end: Double,
                               outputChannels: AVAudioChannelCount? = nil) throws -> AVAudioPCMBuffer {
        let rate = file.processingFormat.sampleRate
        guard start.isFinite, end.isFinite, start >= 0, end > start, rate > 0,
              end * rate <= Double(file.length) else { throw Failure.invalidRange }
        let first = AVAudioFramePosition((start * rate).rounded())
        let last = AVAudioFramePosition((end * rate).rounded())
        let count = last - first
        let channels = outputChannels ?? file.processingFormat.channelCount
        guard channels == file.processingFormat.channelCount ||
              (file.processingFormat.channelCount == 1 && channels == 2) else { throw Failure.invalidRange }
        guard count > 0, count <= Int64(UInt32.max),
              Double(count) * Double(channels) * 4 <= 128 * 1024 * 1024 else {
            throw Failure.invalidRange
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)) else { throw Failure.allocation }
        let previous = file.framePosition
        defer { file.framePosition = previous }
        file.framePosition = first
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength == AVAudioFrameCount(count) else { throw Failure.shortRead }
        if channels == buffer.format.channelCount { return buffer }
        // Matrix voices have stereo player outputs, even for mono source files.
        // scheduleBuffer requires that exact channel count. Only input zero is
        // routed for mono, so leave the unused second channel silent.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let input = buffer.floatChannelData, let output = stereo.floatChannelData else {
            throw Failure.allocation
        }
        stereo.frameLength = buffer.frameLength
        for frame in 0..<Int(buffer.frameLength) {
            output[0][frame] = input[0][frame]
            output[1][frame] = 0
        }
        return stereo
    }
}
#endif
