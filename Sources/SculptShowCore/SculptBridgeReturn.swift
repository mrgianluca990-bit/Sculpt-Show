import Foundation

/// Validates and applies a rendered DAW publication without touching the audio engine.
public enum SculptBridgeReturn {
    public struct Publication: Codable, Sendable {
        public let publicationID: UUID
        public let publishMode: String
        public let targetSelection: Bool
        public let originSessionPath: String
        public let manifest: SculptBridge.Manifest

        // DAW's v1 packet is flat; retain the original handoff format.
        private enum CodingKeys: String, CodingKey { case publicationID, publishMode, originSessionPath, targetSelection }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetSelection = try c.decodeIfPresent(Bool.self, forKey: .targetSelection) ?? false
            publicationID = try c.decode(UUID.self, forKey: .publicationID)
            publishMode = try c.decode(String.self, forKey: .publishMode)
            originSessionPath = try c.decode(String.self, forKey: .originSessionPath)
            manifest = try SculptBridge.Manifest(from: decoder)
        }
        public func encode(to encoder: Encoder) throws {
            try manifest.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(targetSelection, forKey: .targetSelection)
            try c.encode(publicationID, forKey: .publicationID)
            try c.encode(publishMode, forKey: .publishMode)
            try c.encode(originSessionPath, forKey: .originSessionPath)
        }
    }
    public enum Failure: String, LocalizedError {
        case unsupported = "Unsupported Sculpt bridge packet."
        case invalid = "Invalid duration, markers, stems or hardware routing."
        case destination = "Open the original Show containing this cue list before publishing."
        case conflict = "The cue changed in Show after opening DAW. Reopen it from Show or publish as a new cue."
        case duplicate = "This cue already exists; the publication was not applied again."
        case media = "Published media must be readable files inside the publication Audio folder."
        public var errorDescription: String? { rawValue }
    }
    public static func decode(_ data: Data, at url: URL) throws -> Publication {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalid }
        let p = try JSONDecoder().decode(Publication.self, from: data)
        let m = p.manifest
        guard m.format == SculptBridge.format, m.version == 1,
              ["updateCue", "newCue"].contains(p.publishMode) else { throw Failure.unsupported }
        guard m.durationSeconds.isFinite, m.durationSeconds > 0, m.durationSeconds <= 14400,
              !m.stems.isEmpty, m.stems.count <= 64, m.markers.count <= 10000,
              Set(m.stems.map(\.elementID)).count == m.stems.count,
              Set(m.markers.map(\.id)).count == m.markers.count else { throw Failure.invalid }
        let audio = url.deletingLastPathComponent().appendingPathComponent("Audio").resolvingSymlinksInPath().path + "/"
        for s in m.stems {
            guard s.outputStartChannel >= 1, s.outputStartChannel <= 64,
                  s.gain.isFinite, (0...1).contains(s.gain) else { throw Failure.invalid }
            let source = URL(fileURLWithPath: s.sourcePath).resolvingSymlinksInPath()
            guard (s.sourcePath as NSString).isAbsolutePath, source.path.hasPrefix(audio),
                  source.pathExtension.lowercased() == "wav",
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw Failure.media }
        }
        for marker in m.markers {
            guard marker.seconds.isFinite, marker.seconds >= 0, marker.seconds <= m.durationSeconds else { throw Failure.invalid }
        }
        return p
    }
    public static func applying(_ p: Publication, to show: Show, destinationListID: UUID? = nil) throws -> Show {
        let m = p.manifest
        guard !p.targetSelection || p.publishMode == "newCue" else { throw Failure.invalid }
        let listID = p.targetSelection ? destinationListID : m.cueListID
        guard let list = show.cueLists.firstIndex(where: { $0.id == listID }) else { throw Failure.destination }
        var next = show
        let existing = show.cueLists[list].cues.first(where: { $0.id == m.cueID })
        var cue: Cue
        if p.publishMode == "updateCue" {
            guard let current = existing, let origin = m.originCue, origin.id == current.id else { throw Failure.destination }
            // Show-only controls remain editable during DAW work. Media/timeline edits conflict.
            guard current.elements == origin.elements, current.markers == origin.markers,
                  current.name == origin.name, current.durationSeconds == origin.durationSeconds,
                  current.durationMode == origin.durationMode else { throw Failure.conflict }
            cue = current
        } else {
            guard existing == nil else { throw Failure.duplicate }
            cue = Cue(id: m.cueID, name: m.cueName)
            // Keep timecode from the originating cue; no event rules are duplicated.
            cue.elements = (m.originCue?.elements.filter { $0.kind != .audio } ?? []).map { element in
                var copy = element
                copy.id = UUID()
                return copy
            }
        }
        let oldMarkers = cue.markers
        cue.name = m.cueName
        cue.durationMode = .fixed
        cue.durationSeconds = m.durationSeconds
        cue.elements = cue.elements.filter { $0.kind != .audio } + m.stems.map { s in
            CueElement(id: s.elementID, kind: .audio, name: s.name, sourcePath: s.sourcePath,
                       gain: s.gain, muted: s.muted, outputStartChannel: s.outputStartChannel)
        }
        cue.markers = m.markers.map { marker in
            CueMarker(id: marker.id, name: marker.name, positionSeconds: marker.seconds,
                      rules: oldMarkers.first(where: { $0.id == marker.id })?.rules ?? [])
        }
        if let i = next.cueLists[list].cues.firstIndex(where: { $0.id == cue.id }) {
            next.cueLists[list].cues[i] = cue
        } else { next.cueLists[list].cues.append(cue) }
        return next
    }
}
