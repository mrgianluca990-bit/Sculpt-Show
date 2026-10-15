import Foundation

/// Project format v1. Media files are referenced, not embedded.
public struct Show: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var formatVersion: Int
    public var name: String
    public var cueLists: [CueList]
    public var rules: [InteractionRule]

    public init(name: String = "Untitled Show", cueLists: [CueList] = [CueList(name: "Cue List 1")]) {
        self.formatVersion = Self.currentVersion
        self.name = name
        self.cueLists = cueLists
        self.rules = []
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, name, cueLists, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        name = try c.decode(String.self, forKey: .name)
        cueLists = try c.decode([CueList].self, forKey: .cueLists)
        rules = try c.decodeIfPresent([InteractionRule].self, forKey: .rules) ?? []
    }

    @discardableResult
    public mutating func addList(name: String? = nil) -> UUID {
        let list = CueList(name: name ?? "Cue List \(cueLists.count + 1)")
        cueLists.append(list)
        return list.id
    }

    public mutating func renameList(_ id: UUID, to name: String) {
        guard let index = cueLists.firstIndex(where: { $0.id == id }) else { return }
        cueLists[index].name = name
    }

    public mutating func removeList(_ id: UUID) {
        guard cueLists.count > 1 else { return }
        cueLists.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func addAudio(_ urls: [URL], to listID: UUID) -> [UUID] {
        guard let index = cueLists.firstIndex(where: { $0.id == listID }) else { return [] }
        let newCues = urls.filter { $0.isFileURL }.map { Cue(name: $0.deletingPathExtension().lastPathComponent, mediaPath: $0.path) }
        cueLists[index].cues.append(contentsOf: newCues)
        return newCues.map(\.id)
    }

    public mutating func removeCue(_ cueID: UUID, from listID: UUID) {
        guard let index = cueLists.firstIndex(where: { $0.id == listID }) else { return }
        cueLists[index].cues.removeAll { $0.id == cueID }
    }

    public mutating func updateCue(_ cueID: UUID, in listID: UUID, _ update: (inout Cue) -> Void) {
        guard let listIndex = cueLists.firstIndex(where: { $0.id == listID }),
              let cueIndex = cueLists[listIndex].cues.firstIndex(where: { $0.id == cueID }) else { return }
        update(&cueLists[listIndex].cues[cueIndex])
    }

    /// Move a cue within its list, preserving its ID and every saved setting.
    public mutating func moveCue(_ cueID: UUID, in listID: UUID, by offset: Int) {
        guard let listIndex = cueLists.firstIndex(where: { $0.id == listID }),
              let index = cueLists[listIndex].cues.firstIndex(where: { $0.id == cueID }),
              offset != 0 else { return }
        let destination = index + offset
        guard cueLists[listIndex].cues.indices.contains(destination) else { return }
        let cue = cueLists[listIndex].cues.remove(at: index)
        cueLists[listIndex].cues.insert(cue, at: destination)
    }

    /// Create an independent cue directly after the original. Audio media is referenced, not copied.
    @discardableResult
    public mutating func duplicateCue(_ cueID: UUID, in listID: UUID) -> UUID? {
        guard let listIndex = cueLists.firstIndex(where: { $0.id == listID }),
              let cueIndex = cueLists[listIndex].cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        var copy = cueLists[listIndex].cues[cueIndex]
        copy.id = UUID()
        copy.name += " copy"
        // Duplicates must receive unique rule IDs, and self-targets stay relative.
        copy.rules = copy.rules.map { rule in
            var clone = rule
            clone.id = UUID()
            if clone.target == .specificCue && clone.targetID == cueID { clone.targetID = copy.id }
            if clone.conditionCueID == cueID { clone.conditionCueID = copy.id }
            return clone
        }
        cueLists[listIndex].cues.insert(copy, at: cueIndex + 1)
        return copy.id
    }

    /// Find the next enabled cue in the same list (never wraps into another list).
    public func followingCue(after cueID: UUID) -> Cue? {
        guard let list = cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }),
              let index = list.cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        return list.cues.dropFirst(index + 1).first(where: { $0.enabled })
    }

    public func cue(_ id: UUID) -> Cue? {
        cueLists.lazy.flatMap(\.cues).first { $0.id == id }
    }
}

public struct CueList: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cues: [Cue]
    public var rules: [InteractionRule]

    public init(id: UUID = UUID(), name: String, cues: [Cue] = []) {
        self.id = id
        self.name = name
        self.cues = cues
        self.rules = []
    }

    private enum CodingKeys: String, CodingKey { case id, name, cues, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        cues = try c.decode([Cue].self, forKey: .cues)
        rules = try c.decodeIfPresent([InteractionRule].self, forKey: .rules) ?? []
    }
}

public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mediaPath: String
    public var gain: Double
    public var fadeOutSeconds: Double
    public var enabled: Bool

    // v2 capabilities: new keys decode with defaults so v1 shows remain readable.
    public var fadeInSeconds: Double
    public var loop: Bool
    public var followOnFinish: Bool
    /// Delay before playback begins after GO; a pending cue is cancelable with STOP.
    public var preWaitSeconds: Double
    public var rules: [InteractionRule]
    public var ignoreParentRules: Bool

    public init(id: UUID = UUID(), name: String, mediaPath: String,
                gain: Double = 1.0, fadeOutSeconds: Double = 2.0,
                enabled: Bool = true, fadeInSeconds: Double = 0,
                loop: Bool = false, followOnFinish: Bool = false,
                preWaitSeconds: Double = 0) {
        self.id = id
        self.name = name
        self.mediaPath = mediaPath
        self.gain = min(max(gain, 0), 1)
        self.fadeOutSeconds = max(fadeOutSeconds, 0)
        self.enabled = enabled
        self.fadeInSeconds = max(fadeInSeconds, 0)
        self.loop = loop
        self.followOnFinish = followOnFinish
        self.preWaitSeconds = min(max(preWaitSeconds, 0), 600)
        self.rules = []
        self.ignoreParentRules = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mediaPath, gain, fadeOutSeconds, enabled
        case fadeInSeconds, loop, followOnFinish, preWaitSeconds, rules, ignoreParentRules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            mediaPath: try values.decode(String.self, forKey: .mediaPath),
            gain: try values.decode(Double.self, forKey: .gain),
            fadeOutSeconds: try values.decode(Double.self, forKey: .fadeOutSeconds),
            enabled: try values.decode(Bool.self, forKey: .enabled),
            fadeInSeconds: try values.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? 0,
            loop: try values.decodeIfPresent(Bool.self, forKey: .loop) ?? false,
            followOnFinish: try values.decodeIfPresent(Bool.self, forKey: .followOnFinish) ?? false,
            preWaitSeconds: try values.decodeIfPresent(Double.self, forKey: .preWaitSeconds) ?? 0
        )
        rules = try values.decodeIfPresent([InteractionRule].self, forKey: .rules) ?? []
        ignoreParentRules = try values.decodeIfPresent(Bool.self, forKey: .ignoreParentRules) ?? false
    }
}

public enum ShowFormatError: LocalizedError {
    case unsupportedVersion(Int)
    case noCueLists

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported Sculpt Show file format version \(version)."
        case .noCueLists: return "This show has no cue lists."
        }
    }
}

public enum ShowCodec {
    public static func encode(_ show: Show) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(show)
    }

    public static func decode(_ data: Data) throws -> Show {
        let show = try JSONDecoder().decode(Show.self, from: data)
        guard show.formatVersion == Show.currentVersion else {
            throw ShowFormatError.unsupportedVersion(show.formatVersion)
        }
        guard !show.cueLists.isEmpty else { throw ShowFormatError.noCueLists }
        return show
    }
}
