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

/// PCM is immutable after preparation and retained for the lifetime of C pointers.
final class PreparedConditionalPCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let modified: Date?
    let bytes: UInt64
    init(path: String, sampleRate: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        modified = attributes[.modificationDate] as? Date
        bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, file.length <= Int64(UInt32.max),
              file.processingFormat.sampleRate == Double(sampleRate) else {
            throw SessionAudioPreparation.Failure.invalid("Conditional-loop media must be prepared at the project sample rate")
        }
        let pcm = try NativeLoopBuffer.readFrames(file: file, count: AVAudioFrameCount(file.length))
        buffer = pcm
    }
    func matches(path: String, sampleRate: Int) -> Bool {
        guard buffer.format.sampleRate == Double(sampleRate),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return modified == attributes[.modificationDate] as? Date &&
            bytes == (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
    static func prepare(show: Show, cached: [String: PreparedConditionalPCM]) throws -> [String: PreparedConditionalPCM] {
        let paths = Set(show.cueLists.flatMap(\.cues).filter {
            NativeMarkerLoopPlanner.plan(for: $0)?.conditionCueID != nil
        }.flatMap { $0.audioElements.map(\.sourcePath) })
        var result: [String: PreparedConditionalPCM] = [:]
        var total = 0.0
        // Inspect all sizes before allocating. Refuse, never silently return to
        // timer-driven seeking, if a show exceeds the prepared PCM budget.
        for path in paths {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            total += Double(file.length) * Double(file.processingFormat.channelCount) * 4
        }
        guard total <= 512 * 1024 * 1024 else {
            throw SessionAudioPreparation.Failure.invalid("Conditional-loop media exceeds the 512 MiB prepared-audio budget. Consolidate shorter cue media before playback.")
        }
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
    let pcm: [PreparedConditionalPCM]
    let slots: [LoopVoiceSlot]
    init(plan: NativeMarkerLoop, sampleRate: Double, end: Double,
         files: [PreparedConditionalPCM], indices: [Int], slots: [LoopVoiceSlot],
         condition: CueRealtimeSignal, own: CueRealtimeSignal) throws {
        let phase: Int32
        switch plan.conditionState { case .stopped: phase = 0; case .playing: phase = 1; case .paused: phase = 2; case .waiting: phase = 3 }
        guard let instance = sculpt_loop_create(sampleRate, Int64((plan.inSeconds * sampleRate).rounded()),
            Int64((plan.outSeconds * sampleRate).rounded()), Int64((end * sampleRate).rounded()),
            condition.pointer, phase, own.pointer) else { throw SessionAudioPreparation.Failure.invalid("Invalid conditional-loop region") }
        pointer = instance
        self.condition = condition
        self.own = own
        self.pcm = files
        self.slots = slots
        for (index, prepared) in zip(indices, files) {
            guard let data = prepared.buffer.floatChannelData,
                  sculpt_loop_voice(instance, UInt32(index), data[0],
                    prepared.buffer.format.channelCount == 2 ? data[1] : nil, Int64(prepared.buffer.frameLength)) else {
                sculpt_loop_destroy(instance)
                throw SessionAudioPreparation.Failure.invalid("Cannot prepare conditional-loop voice")
            }
        }
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
