import AVFAudio
import AudioToolbox
import Foundation
import SculptShowCore

/// Offline, non-destructive normalization. A whole cue is committed only when all
/// stems have been rendered and verified; the audio/render thread is never touched.
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
        case input(String, String)
        case output(String, String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\(name): audio must be mono or stereo."
            case .empty(let name):
                return "\(name): no measurable loudness. This stem is silent or shorter than the 400 ms loudness analysis window."
            case .input(let name, let detail):
                return "\(name): cannot read the source audio (\(detail))."
            case .output(let name, let detail):
                return "\(name): cannot write normalized WAV (\(detail))."
            case .invalidOutput(let name):
                return "\(name): the normalized WAV did not pass validation; no cue audio has been replaced."
            }
        }
    }

    /// Reading explicitly as non-interleaved Float32 works for 16/24-bit PCM,
    /// floating-point WAV, AIFF and Core Audio decodable formats alike. The source
    /// bit depth or interleaving must not determine whether normalization works.
    private static func makeReader(_ source: URL, name: String) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.input(name, error.localizedDescription)
        }
    }

    private static func outputDirectory(cueID: UUID) throws -> URL {
        let fm = FileManager.default
        // ~/Music is subject to privacy and access restrictions on some machines.
        // Application Support is owned by the app/user and does not require
        // blanket permission to another user's audio library.
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.output("Output folder", "Application Support is unavailable")
        }
        let folder = support
            .appendingPathComponent("Sculpt Show", isDirectory: true)
            .appendingPathComponent("Normalized Audio", isDirectory: true)
            .appendingPathComponent(cueID.uuidString, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw Failure.output("Output folder", error.localizedDescription) }
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
                let reader = try makeReader(source, name: request.name)
                let fmt = reader.processingFormat
                let channels = Int(fmt.channelCount)
                guard (1...2).contains(channels), fmt.commonFormat == .pcmFormatFloat32,
                      !fmt.isInterleaved, fmt.sampleRate.isFinite, fmt.sampleRate >= 8_000 else {
                    throw Failure.unsupported(request.name)
                }
                let frameCapacity: AVAudioFrameCount = 8192
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCapacity) else {
                    throw Failure.unsupported(request.name)
                }
                var meter = LoudnessMeter(sampleRate: fmt.sampleRate, channels: channels)
                do {
                    while true {
                        try Task<Never, Never>.checkCancellation()
                        try reader.read(into: buffer, frameCount: frameCapacity)
                        let read = Int(buffer.frameLength)
                        if read == 0 { break }
                        guard let pcm = buffer.floatChannelData else { throw Failure.unsupported(request.name) }
                        meter.ingest(UnsafePointer(pcm), frames: read)
                    }
                } catch let error as Failure { throw error }
                catch { throw Failure.input(request.name, error.localizedDescription) }
                let measurement = meter.measure()
                let change: Double
                do {
                    change = try NormalizationPlanner.gainDB(for: measurement,
                        mode: mode, target: target,
                        ceilingDBFS: peakLimit ? peakCeiling : nil)
                } catch NormalizationError.silence {
                    throw Failure.empty(request.name)
                } catch {
                    throw Failure.output(request.name, "Invalid normalization target: \(error.localizedDescription)")
                }

                let stemName = source.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "/", with: "-")
                    .prefix(60)
                let filename = "\(stemName)-\(request.elementID.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).wav"
                let outputURL = folder.appendingPathComponent(filename)
                created.append(outputURL)

                // A WAV stores interleaved Float32 PCM, but Core Audio provides
                // non-interleaved Float32 processing buffers via an explicit client
                // format. This avoids relying on the source's encoding/layout.
                // Build the on-disk interleaved LPCM format through Core Audio,
                // rather than passing a hand-built settings dictionary. The
                // processing buffers remain planar Float32; AVAudioFile converts.
                guard let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: fmt.sampleRate,
                                channels: AVAudioChannelCount(channels), interleaved: true) else {
                    throw Failure.output(request.name, "Cannot construct WAV format")
                }
                let settings = fileFormat.settings

                do {
                    // Open a fresh decoder for pass two rather than seeking a
                    // compressed source backwards. Some Core Audio file codecs
                    // do not reliably reset their decoding state via framePosition.
                    let replay = try makeReader(source, name: request.name)
                    let scale = Float(pow(10, change / 20))
                    let maxAmplitude: Float = peakLimit ? Float(pow(10, peakCeiling / 20)) : .greatestFiniteMagnitude
                    let dest = try AVAudioFile(forWriting: outputURL, settings: settings,
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    while true {
                        try Task<Never, Never>.checkCancellation()
                        try replay.read(into: buffer, frameCount: frameCapacity)
                        let read = Int(buffer.frameLength)
                        if read == 0 { break }
                        guard let pcm = buffer.floatChannelData else { throw Failure.unsupported(request.name) }
                        for ch in 0..<channels {
                            for i in 0..<read {
                                let sample = pcm[ch][i] * scale
                                pcm[ch][i] = sample.isFinite ? min(max(sample, -maxAmplitude), maxAmplitude) : 0
                            }
                        }
                        try dest.write(from: buffer)
                    }
                } catch let error as Failure { throw error }
                catch { throw Failure.output(request.name, error.localizedDescription) }

                // Verify the file really exists and preserves the original number
                // of frames, sample rate and channels before it can be relinked.
                do {
                    let verify = try makeReader(outputURL, name: request.name)
                    let outFmt = verify.processingFormat
                    guard verify.length == measurement.frames,
                          Int(outFmt.channelCount) == channels,
                          abs(outFmt.sampleRate - fmt.sampleRate) < 0.001,
                          verify.length > 0 else { throw Failure.invalidOutput(request.name) }
                } catch let error as Failure { throw error }
                catch { throw Failure.invalidOutput(request.name) }

                results.append(Result(elementID: request.elementID,
                                      originalPath: request.originalPath,
                                      normalizedPath: outputURL.path,
                                      beforeLUFS: measurement.integratedLUFS,
                                      beforePeak: measurement.samplePeakDBFS,
                                      gainDB: change,
                                      estimatedAfterLUFS: measurement.integratedLUFS.map { $0 + change },
                                      estimatedAfterPeak: measurement.samplePeakDBFS.map { $0 + change },
                                      name: request.name))
            }
            return results
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
