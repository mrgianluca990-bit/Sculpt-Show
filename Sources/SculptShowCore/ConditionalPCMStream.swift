#if canImport(AVFAudio)
import Foundation
import AVFAudio
import SculptLTCCore

/// Disk access and decode run ahead on a serial worker. Only the C page cache
/// is visible to the renderer. RAM depends on active voices, not file duration.
public final class ConditionalPCMStream: @unchecked Sendable {
    public let pointer: OpaquePointer
    public let frames: Int64
    public let allocatedBytes: UInt64
    private let file: AVAudioFile
    private let loopIn: Int64
    private let loopOut: Int64
    private let ahead: Int64
    private let queue = DispatchQueue(label: "SculptShow.PCMStream", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let page: Int64 = 8192

    public init(path: String, sampleRate: Int, loopIn: Int64, loopOut: Int64, from: Int64) throws {
        file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        frames = file.length
        guard Show.supportedSampleRates.contains(sampleRate), frames > 0, file.processingFormat.sampleRate == Double(sampleRate),
              (1...2).contains(file.processingFormat.channelCount),
              let instance = sculpt_stream_create(Int32(file.processingFormat.channelCount), frames, max(0, from)) else {
            throw SessionAudioPreparation.Failure.invalid("Cannot prepare bounded PCM stream at the project sample rate")
        }
        pointer = instance
        allocatedBytes = sculpt_stream_bytes(instance)
        self.loopIn = loopIn
        self.loopOut = loopOut
        ahead = Int64(sampleRate / 2)
        try refill()
    }
    deinit {
        timer?.cancel()
        sculpt_stream_destroy(pointer)
    }
    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.refill() }
            catch { sculpt_stream_fail(self.pointer); self.timer?.cancel() }
        }
        timer = source
        source.resume()
    }
    // Before start(), or on the one worker queue only. Internal for regression tests.
    func refill() throws {
        let cursor = max(0, min(frames - 1, sculpt_stream_position(pointer)))
        var pages = Set<Int64>()
        // Keep both alternatives at OUT ready before the condition is evaluated:
        // loop IN and the tail at OUT, as well as the current playhead's lookahead.
        for position in [cursor, loopIn, loopOut] where position >= 0 && position < frames {
            let first = max(0, position / page * page - page)
            let last = min(frames - 1, position + ahead) / page * page
            for frame in stride(from: first, through: last, by: Int(page)) { pages.insert(frame) }
        }
        let keep = pages.sorted()
        guard keep.count <= 64 else { throw SessionAudioPreparation.Failure.invalid("PCM lookahead exceeds page capacity") }
        for first in keep where !sculpt_stream_contains(pointer, first) {
            file.framePosition = first
            let count = AVAudioFrameCount(min(page, frames - first))
            let pcm = try NativeLoopBuffer.readFrames(file: file, count: count)
            guard let data = pcm.floatChannelData else { throw NativeLoopBuffer.Failure.allocation }
            let published = keep.withUnsafeBufferPointer { protected in
                sculpt_stream_publish(pointer, first, data[0],
                    file.processingFormat.channelCount == 2 ? data[1] : nil,
                    count, protected.baseAddress, UInt32(keep.count))
            }
            // An evicted old page may still be pinned by the renderer. Try it on
            // the next worker pass; never block the audio thread or overwrite it.
            if !published { return }
        }
    }
}
#endif
