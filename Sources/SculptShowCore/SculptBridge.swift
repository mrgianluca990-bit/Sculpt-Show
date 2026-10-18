import Foundation

/// Sculpt Show ⇄ Sculpt DAW v1 handoff contract. The manifest is descriptive;
/// it does not try to serialize either application's private session format.
/// Audio is referenced by absolute file path, never copied or modified.
public enum SculptBridge {
    public static let version = 1
    public static let format = "com.sculpt.bridge.cue"

    public struct Stem: Codable, Equatable, Sendable {
        public let elementID: UUID
        public let name: String
        public let sourcePath: String
        public let outputStartChannel: Int
        public let gain: Double
        public let muted: Bool
    }
    public struct Marker: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let seconds: Double
    }
    public struct LTC: Codable, Equatable, Sendable {
        public let start: String
        public let trim: String
        public let frameRate: Int
        public let dropFrame: Bool
        public let outputChannel: Int?
    }
    public struct Manifest: Codable, Equatable, Sendable {
        public let format: String
        public let version: Int
        public let showName: String
        public let cueListID: UUID
        public let cueID: UUID
        public let cueName: String
        public let durationSeconds: Double
        public let stems: [Stem]
        public let markers: [Marker]
        public let timecode: LTC?
        /// Optimistic concurrency token: the cue as it was handed to DAW.
        public var originCue: Cue? = nil
    }
    public enum BridgeError: Error, Equatable {
        case missingCue, noAudio, invalidSampleRate, missingChannelMetadata, invalidOutput, unsupportedChannelCount
    }

    public static func manifest(show: Show, listID: UUID, cueID: UUID) throws -> Manifest {
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = list.cues.first(where: { $0.id == cueID }) else { throw BridgeError.missingCue }
        guard cue.hasAudio else { throw BridgeError.noAudio }
        let stems = cue.alignedAudioElements.map { e in
            Stem(elementID: e.id, name: e.name, sourcePath: e.sourcePath,
                 outputStartChannel: e.outputStartChannel, gain: e.gain, muted: e.muted)
        }
        let tc = cue.elements.first(where: { $0.kind == .timecode }).map { e in
            LTC(start: e.timecodeStart, trim: e.ltcTrim, frameRate: e.frameRate,
                dropFrame: e.timecodeDropFrame, outputChannel: e.ltcOutputChannel)
        }
        var result = Manifest(format: format, version: version, showName: show.name,
                        cueListID: listID, cueID: cueID, cueName: cue.name,
                        durationSeconds: cue.durationSeconds, stems: stems,
                        markers: cue.sortedMarkers.map { Marker(id: $0.id, name: $0.name, seconds: $0.positionSeconds) },
                        timecode: tc)
        result.originCue = cue
        return result
    }

    /// File-safe display name only. Cue identity is kept separately by UUID,
    /// and every direct handoff uses a new workspace to avoid overwrites.
    public static func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let pieces = name.components(separatedBy: forbidden)
        let joined = pieces.joined(separator: "-")
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -.\n\r\t"))
        return String((joined.isEmpty ? "Untitled Cue" : joined).prefix(70))
    }

    public static func encode(_ manifest: Manifest) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(manifest)
    }

    /// Creates a native Sculpt DAW project using ONLY commands supported by
    /// the existing DAW CLI. The contract remains version 1 for old manifests;
    /// the additional physical-channel data comes from decoding each source.
    /// Physical routes are recorded as named output paths and track metadata;
    /// track outputs stay on Main until DAW's mix renderer supports hardware routes.
    /// (The current renderer silently drops Route::Hardware output signals.)
    /// One input file = one track; stereo is never split unless explicitly requested.
    public static func dawImportScript(_ manifest: Manifest, sampleRate: Int,
                                       destination: String,
                                       channelCounts: [UUID: Int]) throws -> String {
        guard (8000...384000).contains(sampleRate) else { throw BridgeError.invalidSampleRate }
        func command(_ name: String, _ args: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else { return "" }
            return name + " " + json
        }
        // DAW's main session has an existing default output, Out 1-2. Use
        // distinctly named bridge paths (SCULPT HW ...) to avoid the DAW's
        // special alias parsing of Out 1-2 as the main output bus.
        func physicalPath(_ first: Int, _ count: Int) -> String {
            let ch = String(format: "%02d", first)
            return count == 1 ? "SCULPT HW MONO \(ch)" :
                "SCULPT HW STEREO \(ch)-\(String(format: "%02d", first + 1))"
        }
        var lines = [
            "# Sculpt Bridge v1 · cueID=\(manifest.cueID.uuidString)",
            "# Aligned audio, physical output assignments and cue markers. Do not reinterpret OUT as buses.",
            try command("session.new", ["name": manifest.cueName, "sample_rate": sampleRate])
        ]
        var createdPaths = Set<String>()
        for (index, stem) in manifest.stems.enumerated() {
            guard let count = channelCounts[stem.elementID] else { throw BridgeError.missingChannelMetadata }
            guard count == 1 || count == 2 else { throw BridgeError.unsupportedChannelCount }
            guard stem.outputStartChannel >= 1,
                  stem.outputStartChannel + count - 1 <= 64 else { throw BridgeError.invalidOutput }
            let path = physicalPath(stem.outputStartChannel, count)
            // Import one file at a time, rename the freshly created track before
            // importing another. This also handles sources with identical basenames.
            let sourceName = (stem.sourcePath as NSString).lastPathComponent
            let sourceTrack = (sourceName as NSString).deletingPathExtension
            let stableName = "S\(String(format: "%03d", index + 1)) \(String(stem.name.prefix(35))) \(stem.elementID.uuidString.prefix(8))"
            lines.append(try command("file.import_audio", ["path": stem.sourcePath,
                                                            "at": ["seconds": 0], "new_tracks": true]))
            lines.append(try command("track.rename", ["track": sourceTrack, "name": stableName]))
            if createdPaths.insert(path).inserted {
                lines.append(try command("setup.io", ["action": "create_output", "name": path,
                                                       "first_channel": stem.outputStartChannel - 1,
                                                       "format": count == 1 ? "mono" : "stereo"]))
            }
            // Keep the track audible through the DAW's main monitor output.
            // Physical output assignments are saved separately as I/O paths
            // and explicit track comments until the DAW renderer can output
            // Route::Hardware, which currently produces silence.
            let endChannel = stem.outputStartChannel + count - 1
            let assignment = count == 1 ? "OUT \(stem.outputStartChannel)" :
                "OUT \(stem.outputStartChannel)/\(endChannel)"
            lines.append(try command("track.comments", ["track": stableName,
                                                          "comments": "Sculpt Show physical routing: \(assignment) (\(path)). Prepared only: DAW monitoring uses Main until hardware route playback is supported. Source stem UUID: \(stem.elementID.uuidString)"]))
            if stem.muted {
                lines.append(try command("mix.mute", ["track": stableName, "value": true]))
            }
            if stem.gain.isFinite && stem.gain != 1 {
                let db = stem.gain <= 0 ? -144.0 : max(-144, min(12, 20 * log10(stem.gain)))
                lines.append(try command("mix.volume", ["track": stableName, "db": db]))
            }
        }
        for marker in manifest.markers.sorted(by: { $0.seconds < $1.seconds }) {
            guard marker.seconds.isFinite && marker.seconds >= 0 else { continue }
            lines.append(try command("markers.add", ["name": marker.name,
                                                     "at": ["seconds": marker.seconds],
                                                     "kind": "marker", "ruler": 1]))
        }
        if !manifest.markers.isEmpty {
            lines.append(try command("view.ruler", ["ruler": "markers", "visible": true]))
        }
        lines.append(try command("session.save", ["path": destination, "replace": false]))
        return lines.joined(separator: "\n") + "\n"
    }
}
