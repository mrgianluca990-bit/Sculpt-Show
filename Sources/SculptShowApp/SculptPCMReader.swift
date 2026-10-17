import AVFAudio
import AudioToolbox
import Foundation
import SculptShowCore

/// Common offline decoder used by normalization and waveform analysis.
/// The native WAV path avoids opaque AVAudioFile errors for standard PCM.
/// Extended Audio File handles compressed/Core Audio formats without AVAudioFile.read.
final class SculptPCMReader {
    private enum Backend {
        case wav(WavePCMReader)
        case extended(ExtendedDecoder)
        case av(AVDecoder)
    }

    enum Failure: LocalizedError {
        case unsupported(String)
        case coreAudio(String, OSStatus)
        case allDecodersFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let file):
                return "Unsupported audio stream (mono/stereo PCM required): \(file)"
            case .coreAudio(let stage, let status):
                return "Core Audio \(stage) returned OSStatus \(status)"
            case .allDecodersFailed(let file, let details):
                return "Cannot decode \(file). \(details)"
            }
        }
    }

    private let backend: Backend
    let sampleRate: Double
    let channels: Int
    let frameCount: Int64

    init(_ url: URL) throws {
        var failures: [String] = []
        if ["wav", "wave", "bwf"].contains(url.pathExtension.lowercased()) {
            do {
                let reader = try WavePCMReader(url: url)
                backend = .wav(reader)
                sampleRate = reader.sampleRate
                channels = reader.channels
                frameCount = reader.frameCount
                return
            } catch { failures.append("Native WAV: \(error.localizedDescription)") }
        }
        do {
            let reader = try ExtendedDecoder(url)
            backend = .extended(reader)
            sampleRate = reader.sampleRate
            channels = reader.channels
            frameCount = reader.frameCount
            return
        } catch { failures.append("ExtAudioFile: \(error.localizedDescription)") }
        do {
            let reader = try AVDecoder(url)
            backend = .av(reader)
            sampleRate = reader.sampleRate
            channels = reader.channels
            frameCount = reader.frameCount
            return
        } catch { failures.append("AVAudioFile: \(error.localizedDescription)") }
        throw Failure.allDecodersFailed(url.lastPathComponent, failures.joined(separator: "; "))
    }

    func next() throws -> [[Float]] {
        switch backend {
        case .wav(let reader): return try reader.readFrames()
        case .extended(let reader): return try reader.next()
        case .av(let reader): return try reader.next()
        }
    }

    private final class ExtendedDecoder {
        private let file: ExtAudioFileRef
        private let buffer: AVAudioPCMBuffer
        let sampleRate: Double
        let channels: Int
        let frameCount: Int64

        init(_ url: URL) throws {
            var opened: ExtAudioFileRef?
            let openStatus = ExtAudioFileOpenURL(url as CFURL, &opened)
            guard openStatus == noErr, let ref = opened else {
                throw Failure.coreAudio("opening \(url.lastPathComponent)", openStatus)
            }
            var disposeOnFailure = true
            defer { if disposeOnFailure { ExtAudioFileDispose(ref) } }

            var original = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat,
                                                       &formatSize, &original)
            guard formatStatus == noErr else {
                throw Failure.coreAudio("reading stream format", formatStatus)
            }
            let n = Int(original.mChannelsPerFrame)
            guard (1...2).contains(n), original.mSampleRate.isFinite,
                  (8000...384000).contains(original.mSampleRate),
                  let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: original.mSampleRate,
                                          channels: AVAudioChannelCount(n), interleaved: false),
                  let storage = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
                throw Failure.unsupported(url.lastPathComponent)
            }
            let clientStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), pcm.streamDescription)
            guard clientStatus == noErr else {
                throw Failure.coreAudio("setting Float32 decoder format", clientStatus)
            }
            var sourceFrames: Int64 = 0
            var lengthSize = UInt32(MemoryLayout<Int64>.size)
            let lengthStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames,
                                                       &lengthSize, &sourceFrames)
            let estimatedFrames = (try? AVAudioPlayer(contentsOf: url)).map {
                Int64(($0.duration * original.mSampleRate).rounded())
            } ?? 0
            self.file = ref
            self.buffer = storage
            self.channels = n
            self.sampleRate = original.mSampleRate
            self.frameCount = lengthStatus == noErr && sourceFrames > 0 ? sourceFrames : estimatedFrames
            disposeOnFailure = false
        }

        deinit { ExtAudioFileDispose(file) }

        func next() throws -> [[Float]] {
            buffer.frameLength = buffer.frameCapacity
            var frames = UInt32(buffer.frameCapacity)
            let status = ExtAudioFileRead(file, &frames, buffer.mutableAudioBufferList)
            guard status == noErr else { throw Failure.coreAudio("decoding sample frames", status) }
            guard frames > 0 else { return Array(repeating: [], count: channels) }
            buffer.frameLength = frames
            guard let data = buffer.floatChannelData else { throw Failure.unsupported("no Float32 channels") }
            return (0..<channels).map {
                Array(UnsafeBufferPointer(start: data[$0], count: Int(frames)))
            }
        }
    }

    private final class AVDecoder {
        private let audio: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        let sampleRate: Double
        let channels: Int
        let frameCount: Int64

        init(_ url: URL) throws {
            let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            let format = reader.processingFormat
            guard (1...2).contains(Int(format.channelCount)),
                  format.sampleRate.isFinite, (8000...384000).contains(format.sampleRate),
                  let storage = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw Failure.unsupported(url.lastPathComponent)
            }
            audio = reader
            buffer = storage
            channels = Int(format.channelCount)
            sampleRate = format.sampleRate
            frameCount = Int64(reader.length)
        }

        func next() throws -> [[Float]] {
            do { try audio.read(into: buffer, frameCount: 8192) }
            catch {
                let ns = error as NSError
                throw Failure.allDecodersFailed(audio.url.lastPathComponent,
                    "AVAudioFile read at frame \(audio.framePosition): \(ns.domain) \(ns.code) — \(error.localizedDescription)")
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return Array(repeating: [], count: channels) }
            guard let data = buffer.floatChannelData else { throw Failure.unsupported(audio.url.lastPathComponent) }
            return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
        }
    }
}
