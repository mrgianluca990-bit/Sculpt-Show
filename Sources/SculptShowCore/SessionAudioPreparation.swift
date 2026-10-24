#if canImport(AVFAudio)
import AVFAudio
import Foundation

public enum SessionAudioPreparation {
    public enum Failure: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    /// Convert into a temporary sibling and publish only a fully verified WAV.
    /// No playback code calls this method. All source originals remain untouched.
    public static func convert(source: URL, destination: URL, sampleRate: Int) throws {
        guard Show.supportedSampleRates.contains(sampleRate) else { throw Failure.invalid("Unsupported project sample rate") }
        let file = try AVAudioFile(forReading: source)
        let channels = file.processingFormat.channelCount
        guard (1...2).contains(channels), file.length > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: channels),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw Failure.invalid("Cannot prepare mono/stereo media: \(source.lastPathComponent)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".convert-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: temporary) }
        let expected = Int64((Double(file.length) * Double(sampleRate) / file.processingFormat.sampleRate).rounded())
        var written: Int64 = 0
        do {
            let sink = try AVAudioFile(forWriting: temporary, settings: format.settings)
            var readError: Error?
            var done = false
            var emptyPasses = 0
            while !done {
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { requested, state in
                    if file.framePosition >= file.length { state.pointee = .endOfStream; return nil }
                    do {
                        try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                        state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                        return input.frameLength > 0 ? input : nil
                    } catch { readError = error; state.pointee = .endOfStream; return nil }
                }
                if let error = readError { throw error }
                if let error = conversionError { throw error }
                if status == .error { throw Failure.invalid("Offline conversion failed: \(source.lastPathComponent)") }
                let keep = min(Int64(output.frameLength), max(0, expected - written))
                if keep > 0 {
                    output.frameLength = AVAudioFrameCount(keep)
                    try sink.write(from: output)
                    written += keep
                    emptyPasses = 0
                } else { emptyPasses += 1 }
                done = status == .endOfStream || written >= expected
                guard done || emptyPasses < 32 else { throw Failure.invalid("Offline converter made no progress") }
            }
            // Converter edge rounding can be one frame short. Pad only that
            // rounding frame; a larger discrepancy is a failed conversion.
            guard expected - written <= 1 else { throw Failure.invalid("Incomplete offline conversion") }
            if written < expected {
                output.frameLength = 1
                for channel in 0..<Int(channels) { output.floatChannelData?[channel][0] = 0 }
                try sink.write(from: output)
            }
        }
        let verified = try AVAudioFile(forReading: temporary)
        guard verified.length == expected, verified.processingFormat.sampleRate == Double(sampleRate),
              verified.processingFormat.channelCount == channels else { throw Failure.invalid("Converted WAV verification failed") }
        // Conversion destinations are new revision names; no source is replaced.
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.invalid("Conversion destination already exists") }
        try fm.moveItem(at: temporary, to: destination)
    }

    public static func preparing(_ show: Show, projectRoot: URL) throws -> Show {
        var next = show
        let fm = FileManager.default
        var created: [URL] = []
        do {
            for li in next.cueLists.indices {
                let list = next.cueLists[li]
                for ci in next.cueLists[li].cues.indices {
                    for ei in next.cueLists[li].cues[ci].elements.indices {
                        let element = next.cueLists[li].cues[ci].elements[ei]
                        guard element.kind == .audio, !element.sourcePath.isEmpty else { continue }
                        let current = URL(fileURLWithPath: element.sourcePath)
                        let info = try AVAudioFile(forReading: current)
                        guard abs(info.processingFormat.sampleRate - Double(show.sampleRate)) > 0.5 else { continue }
                        var original = element.originalSourcePath.map { URL(fileURLWithPath: $0) }
                        if original == nil {
                            // The imported project copy is already the source original.
                            // Only external media needs the normal import copy.
                            if current.standardizedFileURL.path.hasPrefix(projectRoot.standardizedFileURL.path + "/") {
                                original = current
                            } else {
                                let folder = projectRoot.appendingPathComponent("Audio Files/" + ShowProjectPackage.listFolderName(list), isDirectory: true)
                                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                                let copy = folder.appendingPathComponent(UUID().uuidString + "-" + current.lastPathComponent)
                                try fm.copyItem(at: current, to: copy)
                                created.append(copy)
                                original = copy
                            }
                        }
                        guard let original else { throw Failure.invalid("Missing source original") }
                        let folder = projectRoot.appendingPathComponent("Audio Files/" + ShowProjectPackage.listFolderName(list), isDirectory: true)
                        let destination = folder.appendingPathComponent(SculptBridge.safeFilename(element.name) + "-\(show.sampleRate)-\(UUID().uuidString.prefix(8)).wav")
                        try convert(source: original, destination: destination, sampleRate: show.sampleRate)
                        created.append(destination)
                        next.cueLists[li].cues[ci].elements[ei].sourcePath = destination.path
                        next.cueLists[li].cues[ci].elements[ei].originalSourcePath = original.path
                    }
                }
            }
            return next
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
#endif
