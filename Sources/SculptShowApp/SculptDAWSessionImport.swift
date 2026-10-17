import Foundation

/// Safe, read-only import of a native Sculpt DAW .scraft JSON document.
/// Show's current audio engine plays aligned, full-file stems; if a DAW session
/// contains edits/processed audio that Show cannot represent, we reject it
/// explicitly instead of silently discarding the edit.
enum SculptDAWSessionImport {
    struct Stem: Sendable {
        let name: String
        let path: String
        let output: Int
        let gain: Double
        let muted: Bool
    }
    struct Marker: Sendable {
        let name: String
        let seconds: Double
    }
    struct Result: Sendable {
        let name: String
        let stems: [Stem]
        let markers: [Marker]
        let duration: Double
        var audioPaths: [String] { stems.map(\.path) }
    }
    enum ImportError: LocalizedError {
        case malformed, noTracks, noSource(String), unsupported(String), unsafe(String)
        var errorDescription: String? {
            switch self {
            case .malformed: return "This file is not a readable Sculpt DAW .scraft session."
            case .noTracks: return "No complete audio stems were found in this DAW session."
            case .noSource(let name): return "DAW media not found: \(name). Reopen and consolidate the DAW session."
            case .unsupported(let description): return "\(description). Bounce/consolidate the edited tracks in Sculpt DAW before importing into Show."
            case .unsafe(let value): return "Unsafe DAW audio path: \(value)"
            }
        }
    }

    private static func dictionary(_ object: Any?) -> [String: Any]? { object as? [String: Any] }
    private static func number(_ object: Any?) -> Double? {
        guard let number = object as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
    private static func integer(_ object: Any?) -> Int? {
        guard let number = number(object), number >= 0, number <= Double(Int.max) else { return nil }
        return Int(number)
    }
    private static func dbGain(_ db: Double) -> Double {
        min(1, max(0, pow(10, min(0, db) / 20)))
    }

    static func read(at url: URL) throws -> Result {
        guard url.isFileURL, url.pathExtension.lowercased() == "scraft" else { throw ImportError.malformed }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["format_version"]) != nil,
              let rate = number(root["sample_rate"]), rate >= 8000,
              let sources = root["sources"] as? [[String: Any]],
              let tracks = root["tracks"] as? [[String: Any]] else { throw ImportError.malformed }
        let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let byID = Dictionary(sources.compactMap { source -> (Int, [String: Any])? in
            guard let id = integer(source["id"]) else { return nil }
            return (id, source)
        }, uniquingKeysWith: { first, _ in first })
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let fileManager = FileManager.default
        var stems: [Stem] = []
        var end = 0.0
        var nextOutput = 1
        for track in tracks where (track["kind"] as? String) == "Audio" {
            let title = (track["name"] as? String) ?? "Audio"
            guard let playlists = track["playlists"] as? [[String: Any]],
                  let active = integer(track["active_playlist"]),
                  playlists.indices.contains(active),
                  let clips = playlists[active]["clips"] as? [[String: Any]] else {
                throw ImportError.unsupported("Malformed playlist in '\(title)'")
            }
            if clips.isEmpty { continue }
            guard clips.count == 1, let clip = clips.first,
                  let content = dictionary(clip["content"]),
                  let audio = dictionary(content["Audio"]),
                  let sourceID = integer(audio["source"]),
                  let source = byID[sourceID],
                  let start = number(clip["start"]), start == 0,
                  let offset = number(audio["offset"]), offset == 0,
                  let length = number(clip["length"]), length > 0 else {
                throw ImportError.unsupported("Split, trimmed or repositioned regions in '\(title)'")
            }
            if (clip["gain_env"] as? [Any])?.isEmpty == false ||
               number(dictionary(clip["fade_in"])?["len"]) ?? 0 > 0 ||
               number(dictionary(clip["fade_out"])?["len"]) ?? 0 > 0 ||
               abs((number(clip["stretch"]) ?? 1) - 1) > 0.00001 {
                throw ImportError.unsupported("Clip processing in '\(title)'")
            }
            let clipSeconds = length / rate
            let sourceFrames = number(source["frames"]) ?? 0
            let sourceRate = number(source["sample_rate"]) ?? 0
            guard sourceRate > 0, sourceFrames > 0,
                  abs(clipSeconds - sourceFrames / sourceRate) <= 0.05 else {
                throw ImportError.unsupported("Partial region in '\(title)'")
            }
            guard let raw = source["path"] as? String, !raw.isEmpty else {
                throw ImportError.noSource(title)
            }
            let relative = URL(fileURLWithPath: raw)
            let candidate = (raw as NSString).isAbsolutePath
                ? relative.standardizedFileURL : parent.appendingPathComponent(raw).standardizedFileURL
            // Relative sources must resolve within their parent session folder.
            if !(raw as NSString).isAbsolutePath && !candidate.path.hasPrefix(parent.path + "/") {
                throw ImportError.unsafe(raw)
            }
            guard fileManager.fileExists(atPath: candidate.path) else { throw ImportError.noSource(raw) }
            let mixer = dictionary(track["mixer"]) ?? [:]
            // Insert FX and per-track automation must be rendered in the DAW first.
            let inserted = (mixer["inserts"] as? [Any])?.contains {
                guard let plugin = dictionary($0) else { return false }
                return (plugin["active"] as? Bool ?? true) && !(plugin["bypass"] as? Bool ?? false)
            } ?? false
            if inserted || (track["automation"] as? [Any])?.isEmpty == false {
                throw ImportError.unsupported("Active plugins/automation in '\(title)'")
            }
            let expectedChannels = (track["format"] as? String) == "Stereo" ? 2 : 1
            guard (source["channels"] as? NSNumber)?.intValue == expectedChannels else {
                throw ImportError.unsupported("Channel format in '\(title)'")
            }
            let comment = (track["comments"] as? String) ?? ""
            var output = nextOutput
            if let match = comment.range(of: #"OUT [0-9]{1,2}"#, options: .regularExpression),
               let number = Int(comment[match].split(separator: " ").last ?? "") {
                output = number
            }
            guard output >= 1 && output + expectedChannels - 1 <= 64 else {
                throw ImportError.unsupported("Hardware output beyond OUT 64 in '\(title)'")
            }
            let volume = (number(mixer["volume_db"]) ?? 0) + (number(mixer["trim_db"]) ?? 0)
                + (number(clip["gain_db"]) ?? 0)
            stems.append(Stem(name: title, path: candidate.path, output: output,
                              gain: dbGain(volume),
                              muted: (mixer["mute"] as? Bool ?? false) || (clip["muted"] as? Bool ?? false)))
            end = max(end, clipSeconds)
            nextOutput = max(nextOutput, output + expectedChannels)
        }
        guard !stems.isEmpty else { throw ImportError.noTracks }
        let memory = (root["markers"] as? [[String: Any]]) ?? []
        let markers = memory.compactMap { item -> Marker? in
            guard (item["kind"] as? String) == "Marker",
                  let sample = number(item["start"]), sample >= 0 else { return nil }
            let seconds = sample / rate
            guard seconds <= 86400 else { return nil }
            return Marker(name: (item["name"] as? String) ?? "Marker", seconds: seconds)
        }.sorted { $0.seconds < $1.seconds }
        return Result(name: name, stems: stems, markers: markers,
                      duration: max(end, markers.last?.seconds ?? 0.1))
    }
}
