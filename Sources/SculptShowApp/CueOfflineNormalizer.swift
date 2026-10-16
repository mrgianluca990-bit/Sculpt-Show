import AVFAudio
import Foundation
import SculptShowCore

/// Non-destructive, offline two-pass normalization. Plain PCM WAV files use
/// Swift's streamed WAV reader/writer, bypassing the AVAudioFile writer that
/// previously produced opaque Foundation._GenericObjCError failures. Other
/// supported audio formats use AVAudioFile only to DECODE to planar Float32.
enum CueOfflineNormalizer {
    struct Request: Sendable {
        let elementID: UUID
        let name: String
        let originalPath: String
    }

    struct Result: Sendable {
        let elementID: UUID
        let originalPath: String
        let normalizedPath: String
        let beforeLUFS: Double?
        let beforePeak: Double?
        let gainDB: Double
        let estimatedAfterLUFS: Double?
        let estimatedAfterPeak: Double?
        let name: String
    }

    enum Failure: LocalizedError {
        case unsupported(String)
        case empty(String)
        case operation(String, String, String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\(name): normalization supports mono and stereo audio only."
            case .empty(let name):
                return "\(name): no measurable signal. For LUFS-I, the audio needs at least 400 ms of measurable content."
            case .operation(let name, let stage, let explanation):
                return "\(name): \(stage) failed — \(explanation)"
            case .invalidOutput(let name):
                return "\(name): normalized WAV failed its frame count, sample rate, channel or output size check. The cue was not changed."
            }
        }
    }

    /// Format-neutral, Float32 planar frame reader with an independent seek state.
    /// WAV PCM uses native Swift; AIFF/other formats use Core Audio only to decode.
    private enum Reader {
        case wave(WavePCMReader)
        case core(CoreAudioDecoder)

        var sampleRate: Double {
            switch self {
            case .wave(let r): return r.sampleRate
            case .core(let r): return r.sampleRate
            }
        }
        var channels: Int {
            switch self {
            case .wave(let r): return r.channels
            case .core(let r): return r.channels
            }
        }
        func next() throws -> [[Float]] {
            switch self {
            case .wave(let r): return try r.readFrames()
            case .core(let r): return try r.next()
            }
        }
    }

    private final class CoreAudioDecoder {
        let audio: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let sampleRate: Double
        let channels: Int

        init(_ url: URL) throws {
            let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = reader.processingFormat
            guard (1...2).contains(Int(format.channelCount)),
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
                  format.sampleRate.isFinite, (8000...384000).contains(format.sampleRate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw Failure.unsupported(url.lastPathComponent)
            }
            self.audio = reader
            self.buffer = buffer
            self.sampleRate = format.sampleRate
            self.channels = Int(format.channelCount)
        }
        func next() throws -> [[Float]] {
            try audio.read(into: buffer, frameCount: 8192)
            let count = Int(buffer.frameLength)
            guard count > 0 else { return Array(repeating: [], count: channels) }
            guard let channelsData = buffer.floatChannelData else {
                throw Failure.unsupported(audio.url.lastPathComponent)
            }
            return (0..<channels).map { ch in Array(UnsafeBufferPointer(start: channelsData[ch], count: count)) }
        }
    }

    private static func makeReader(_ url: URL, name: String) throws -> Reader {
        let ext = url.pathExtension.lowercased()
        if ["wav", "wave", "bwf"].contains(ext) {
            do { return .wave(try WavePCMReader(url: url)) }
            catch WavePCMFailure.unsupported {
                // Compressed WAV codecs may still be supported by Core Audio.
            } catch {
                throw Failure.operation(name, "reading source WAV", explain(error))
            }
        }
        do { return .core(try CoreAudioDecoder(url)) }
        catch { throw Failure.operation(name, "decoding source audio", explain(error)) }
    }

    private static func explain(_ error: Error) -> String {
        let n = error as NSError
        return "\(error.localizedDescription) [\(n.domain):\(n.code)]"
    }

    private static func outputDirectory(cueID: UUID) throws -> URL {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.operation("Output folder", "locating Application Support", "No directory is available")
        }
        let folder = support.appendingPathComponent("Sculpt Show", isDirectory: true)
            .appendingPathComponent("Normalized Audio", isDirectory: true)
            .appendingPathComponent(cueID.uuidString, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw Failure.operation("Output folder", "creating directory", explain(error)) }
        return folder
    }

    static func normalize(_ requests: [Request], cueID: UUID,
                          mode: NormalizationTarget, target: Double,
                          peakLimit: Bool, peakCeiling: Double = -1) throws -> [Result] {
        let fm = FileManager.default
        let folder = try outputDirectory(cueID: cueID)
        var created: [URL] = []
        do {
            var results: [Result] = []
            for request in requests {
                try Task<Never, Never>.checkCancellation()
                let source = URL(fileURLWithPath: request.originalPath)
                let analysis = try makeReader(source, name: request.name)
                guard (1...2).contains(analysis.channels) else { throw Failure.unsupported(request.name) }
                var meter = LoudnessMeter(sampleRate: analysis.sampleRate, channels: analysis.channels)
                do {
                    while true {
                        try Task<Never, Never>.checkCancellation()
                        let pcm = try analysis.next()
                        guard let first = pcm.first, !first.isEmpty else { break }
                        meter.ingest(planar: pcm)
                    }
                } catch let e as Failure { throw e }
                catch { throw Failure.operation(request.name, "analyzing audio", explain(error)) }
                let before = meter.measure()
                let change: Double
                do {
                    change = try NormalizationPlanner.gainDB(for: before, mode: mode,
                        target: target, ceilingDBFS: peakLimit ? peakCeiling : nil)
                } catch NormalizationError.silence { throw Failure.empty(request.name) }
                catch { throw Failure.operation(request.name, "computing gain", explain(error)) }

                let stem = source.deletingPathExtension().lastPathComponent.prefix(60)
                    .replacingOccurrences(of: "/", with: "-")
                let filename = "\(stem)-\(request.elementID.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).wav"
                let output = folder.appendingPathComponent(filename)
                created.append(output)

                do {
                    // Two-pass analysis + rendering with separate reader handles.
                    let replay = try makeReader(source, name: request.name)
                    guard replay.channels == analysis.channels,
                          abs(replay.sampleRate - analysis.sampleRate) < 0.001 else {
                        throw Failure.unsupported(request.name)
                    }
                    let writer = try WaveFloat32Writer(url: output,
                        sampleRate: analysis.sampleRate, channels: analysis.channels)
                    let gain = Float(pow(10, change / 20))
                    let ceiling: Float? = peakLimit ? Float(pow(10, peakCeiling / 20)) : nil
                    while true {
                        try Task<Never, Never>.checkCancellation()
                        let pcm = try replay.next()
                        guard let first = pcm.first, !first.isEmpty else { break }
                        try writer.append(planar: pcm, gain: gain, peakCeiling: ceiling)
                    }
                    try writer.finalize() // close file before verification
                    guard writer.frameCount == before.frames else { throw Failure.invalidOutput(request.name) }
                } catch let e as Failure { throw e }
                catch { throw Failure.operation(request.name, "writing Float32 WAV", explain(error)) }

                let after: NormalizationMeasurement
                do {
                    let verified = try WavePCMReader(url: output)
                    guard verified.channels == analysis.channels,
                          abs(verified.sampleRate - analysis.sampleRate) < 0.001,
                          verified.frameCount == before.frames,
                          verified.frameCount > 0 else { throw Failure.invalidOutput(request.name) }
                    // Actual post-render measurements, not predicted LUFS.
                    var meter = LoudnessMeter(sampleRate: verified.sampleRate, channels: verified.channels)
                    while true {
                        try Task<Never, Never>.checkCancellation()
                        let pcm = try verified.readFrames()
                        guard let first = pcm.first, !first.isEmpty else { break }
                        meter.ingest(planar: pcm)
                    }
                    after = meter.measure()
                } catch let e as Failure { throw e }
                catch { throw Failure.operation(request.name, "verifying normalized WAV", explain(error)) }

                results.append(Result(elementID: request.elementID,
                    originalPath: request.originalPath, normalizedPath: output.path,
                    beforeLUFS: before.integratedLUFS, beforePeak: before.samplePeakDBFS,
                    gainDB: change, estimatedAfterLUFS: after.integratedLUFS,
                    estimatedAfterPeak: after.samplePeakDBFS, name: request.name))
            }
            return results
        } catch {
            // Multitrack normalization is atomic: not one file is relinked if
            // ANY stem fails. Remove all generated files and keep originals.
            for item in created { try? fm.removeItem(at: item) }
            throw error
        }
    }
}
