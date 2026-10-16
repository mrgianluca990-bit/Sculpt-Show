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
    }
    public enum BridgeError: Error, Equatable {
        case missingCue, noAudio, invalidSampleRate
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
        return Manifest(format: format, version: version, showName: show.name,
                        cueListID: listID, cueID: cueID, cueName: cue.name,
                        durationSeconds: cue.durationSeconds, stems: stems,
                        markers: cue.sortedMarkers.map { Marker(id: $0.id, name: $0.name, seconds: $0.positionSeconds) },
                        timecode: tc)
    }

    public static func encode(_ manifest: Manifest) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(manifest)
    }

    /// Script understood by SculptDAW's existing soundcraft-cli `script FILE`
    /// command: session.new, file.import_audio, session.save. Each JSON object is
    /// escaped by JSONSerialization; a name/path cannot inject extra commands.
    public static func dawImportScript(_ manifest: Manifest, sampleRate: Int,
                                       destination: String) throws -> String {
        guard sampleRate >= 8000 && sampleRate <= 384000 else { throw BridgeError.invalidSampleRate }
        func command(_ name: String, _ args: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .fragmentsAllowed])
            guard let json = String(data: data, encoding: .utf8) else { return "" }
            return name + " " + json
        }
        let lines = [
            "# Sculpt Bridge v1 · cueID=\(manifest.cueID.uuidString)",
            "# Non-destructive handoff. Stem placements begin at 00:00; Show retains routing, LTC and Rules.",
            try command("session.new", ["name": manifest.cueName, "sample_rate": sampleRate]),
            try command("file.import_audio", ["paths": manifest.stems.map(\.sourcePath),
                                               "at": ["seconds": 0], "new_tracks": true]),
            try command("session.save", ["path": destination, "replace": false])
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
