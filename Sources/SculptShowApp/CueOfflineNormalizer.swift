import AVFAudio
import AudioToolbox
import Foundation
import SculptShowCore

/// REAPER-inspired offline normalization of mono/stereo stems. Reads a file in
/// bounded chunks; creates a separate 32-bit float WAV at the same sample rate.
/// Never modifies a source, the running audio graph, or a cue on a realtime thread.
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
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "Cannot read mono/stereo Float32 PCM from \(name)."
            case .empty(let name): return "No measurable audio in \(name). Silent stems cannot be normalized."
            }
        }
    }

    static func normalize(_ requests: [Request], cueID: UUID,
                          mode: NormalizationTarget, target: Double,
                          peakLimit: Bool, peakCeiling: Double = -1) throws -> [Result] {
        let fm = FileManager.default
        let base = (fm.urls(for: .musicDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Sculpt Normalized", isDirectory: true)
            .appendingPathComponent(cueID.uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var created: [URL] = []
        do {
            var results: [Result] = []
            for request in requests {
                try Task<Never, Never>.checkCancellation()
                let source = URL(fileURLWithPath: request.originalPath)
                let audio = try AVAudioFile(forReading: source)
                let fmt = audio.processingFormat
                let count = Int(fmt.channelCount)
                guard (1...2).contains(count), fmt.commonFormat == .pcmFormatFloat32,
                      !fmt.isInterleaved else { throw Failure.unsupported(request.name) }
                let cap: AVAudioFrameCount = 8192
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else {
                    throw Failure.unsupported(request.name)
                }
                var meter = LoudnessMeter(sampleRate: fmt.sampleRate, channels: count)
                while true {
                    try Task<Never, Never>.checkCancellation()
                    try audio.read(into: buffer, frameCount: cap)
                    let read = Int(buffer.frameLength)
                    if read == 0 { break }
                    guard let pcm = buffer.floatChannelData else { throw Failure.unsupported(request.name) }
                    meter.ingest(UnsafePointer(pcm), frames: read)
                }
                let measurement = meter.measure()
                let change: Double
                do {
                    change = try NormalizationPlanner.gainDB(for: measurement,
                               mode: mode, target: target,
                               ceilingDBFS: peakLimit ? peakCeiling : nil)
                } catch NormalizationError.silence {
                    throw Failure.empty(request.name)
                }
                let safeName = source.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "/", with: "-")
                    .prefix(60)
                let filename = "\(safeName)-\(request.elementID.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).wav"
                let outputURL = base.appendingPathComponent(filename)
                created.append(outputURL)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: fmt.sampleRate,
                    AVNumberOfChannelsKey: count,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: false
                ]
                // New file instead of clip gain: playback's per-element faders currently
                // support 0...1, so this also supports positive normalization gain.
                let dest = try AVAudioFile(forWriting: outputURL, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                audio.framePosition = 0
                let scale = Float(pow(10, change / 20))
                let maxAmplitude = peakLimit ? Float(pow(10, peakCeiling / 20)) : Float.greatestFiniteMagnitude
                while true {
                    try Task<Never, Never>.checkCancellation()
                    try audio.read(into: buffer, frameCount: cap)
                    let read = Int(buffer.frameLength)
                    if read == 0 { break }
                    guard let pcm = buffer.floatChannelData else { throw Failure.unsupported(request.name) }
                    for ch in 0..<count {
                        for i in 0..<read {
                            let sample = pcm[ch][i] * scale
                            pcm[ch][i] = sample.isFinite ? min(max(sample, -maxAmplitude), maxAmplitude) : 0
                        }
                    }
                    try dest.write(from: buffer)
                }
                results.append(Result(elementID: request.elementID,
                    originalPath: request.originalPath, normalizedPath: outputURL.path,
                    beforeLUFS: measurement.integratedLUFS,
                    beforePeak: measurement.samplePeakDBFS,
                    gainDB: change,
                    estimatedAfterLUFS: measurement.integratedLUFS.map { $0 + change },
                    estimatedAfterPeak: measurement.samplePeakDBFS.map { $0 + change },
                    name: request.name))
            }
            return results
        } catch {
            // An unsuccessful multi-stem operation does not leave partial working copies.
            for path in created { try? fm.removeItem(at: path) }
            throw error
        }
    }
}
