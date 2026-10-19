import AVFAudio
import AudioToolbox
import Foundation
import SculptLTCCore
import SculptShowCore

final class CueRealtimeSignal {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = sculpt_signal_create() else { throw SessionAudioPreparation.Failure.invalid("Cannot allocate cue signal") }
        self.pointer = pointer
    }
    deinit { sculpt_signal_destroy(pointer) }
}

/// Prepared metadata is lightweight; bounded PCM caches belong to active voices.
final class PreparedConditionalPCM: @unchecked Sendable {
    let sampleRate: Int
    let frames: Int64
    let path: String
    let modified: Date?
    let bytes: UInt64
    init(path: String, sampleRate: Int) throws {
        self.path = path
        self.sampleRate = sampleRate
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        modified = attributes[.modificationDate] as? Date
        bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0,
              file.processingFormat.sampleRate == Double(sampleRate) else {
            throw SessionAudioPreparation.Failure.invalid("Conditional-loop media must be prepared at the project sample rate")
        }
        frames = file.length
    }
    func matches(path: String, sampleRate: Int) -> Bool {
        guard self.sampleRate == sampleRate,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return modified == attributes[.modificationDate] as? Date &&
            bytes == (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
    static func prepare(show: Show, cached: [String: PreparedConditionalPCM]) throws -> [String: PreparedConditionalPCM] {
        let paths = Set(show.cueLists.flatMap(\.cues).filter {
            NativeMarkerLoopPlanner.plan(for: $0)?.conditionCueID != nil
        }.flatMap { $0.audioElements.map(\.sourcePath) })
        var result: [String: PreparedConditionalPCM] = [:]
        for path in paths {
            if let previous = cached[path], previous.matches(path: path, sampleRate: show.sampleRate) { result[path] = previous }
            else { result[path] = try PreparedConditionalPCM(path: path, sampleRate: show.sampleRate) }
        }
        return result
    }
}

final class ConditionalLoopRealtime {
    let pointer: OpaquePointer
    let condition: CueRealtimeSignal
    let own: CueRealtimeSignal
    let streams: [ConditionalPCMStream]
    let slots: [LoopVoiceSlot]
    init(plan: NativeMarkerLoop, sampleRate: Double, end: Double,
         files: [PreparedConditionalPCM], from: Double, indices: [Int], slots: [LoopVoiceSlot],
         condition: CueRealtimeSignal, own: CueRealtimeSignal) throws {
        let phase: Int32
        switch plan.conditionState { case .stopped: phase = 0; case .playing: phase = 1; case .paused: phase = 2; case .waiting: phase = 3 }
        guard let instance = sculpt_loop_create(sampleRate, Int64((plan.inSeconds * sampleRate).rounded()),
            Int64((plan.outSeconds * sampleRate).rounded()), Int64((end * sampleRate).rounded()),
            condition.pointer, phase, own.pointer) else { throw SessionAudioPreparation.Failure.invalid("Invalid conditional-loop region") }
        pointer = instance
        self.condition = condition
        self.own = own
        var preparedStreams: [ConditionalPCMStream] = []
        do {
            for prepared in files {
                preparedStreams.append(try ConditionalPCMStream(path: prepared.path, sampleRate: Int(sampleRate),
                    loopIn: Int64((plan.inSeconds * sampleRate).rounded()),
                    loopOut: Int64((plan.outSeconds * sampleRate).rounded()), from: Int64((from * sampleRate).rounded())))
            }
        } catch { sculpt_loop_destroy(instance); throw error }
        self.streams = preparedStreams
        self.slots = slots
        for (index, stream) in zip(indices, preparedStreams) {
            guard sculpt_loop_stream_voice(instance, UInt32(index), stream.pointer) else {
                throw SessionAudioPreparation.Failure.invalid("Cannot bind conditional-loop stream")
            }
        }
        for stream in preparedStreams { stream.start() }
    }
    deinit { sculpt_loop_destroy(pointer) }
    var quiescent: Bool { slots.allSatisfy { !sculpt_loop_slot_busy($0.pointer) } }
    func unbind() { for slot in slots { sculpt_loop_slot_bind(slot.pointer, nil) } }
}

final class LoopVoiceSlot {
    let pointer: OpaquePointer
    init(index: Int) throws {
        guard let pointer = sculpt_loop_slot_create(UInt32(index)) else { throw SessionAudioPreparation.Failure.invalid("Cannot allocate audio render slot") }
        self.pointer = pointer
    }
    deinit { sculpt_loop_slot_destroy(pointer) }
    func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: AVAudioFrameCount,
                data: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return }
        let sample = timestamp.pointee.mSampleTime
        guard timestamp.pointee.mFlags.contains(.hostTimeValid),
              timestamp.pointee.mFlags.contains(.sampleTimeValid), sample.isFinite,
              abs(sample) < Double(Int64.max) else {
            left.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
            right.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames))
            return
        }
        let now = AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime)
        sculpt_loop_slot_render(pointer, now, Int64(timestamp.pointee.mSampleTime.rounded()), frames, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self))
    }
}
