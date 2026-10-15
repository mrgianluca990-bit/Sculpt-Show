import Foundation

/// Project format v1. Media files are referenced, not embedded.
public struct Show: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var formatVersion: Int
    public var name: String
    public var cueLists: [CueList]

    public init(name: String = "Untitled Show", cueLists: [CueList] = [CueList(name: "Cue List 1")]) {
        self.formatVersion = Self.currentVersion
        self.name = name
        self.cueLists = cueLists
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

    public func cue(_ id: UUID) -> Cue? {
        cueLists.lazy.flatMap(\.cues).first { $0.id == id }
    }
}

public struct CueList: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cues: [Cue]

    public init(id: UUID = UUID(), name: String, cues: [Cue] = []) {
        self.id = id
        self.name = name
        self.cues = cues
    }
}

public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mediaPath: String
    public var gain: Double
    public var fadeOutSeconds: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, mediaPath: String,
                gain: Double = 1.0, fadeOutSeconds: Double = 2.0, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.mediaPath = mediaPath
        self.gain = min(max(gain, 0), 1)
        self.fadeOutSeconds = max(fadeOutSeconds, 0)
        self.enabled = enabled
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
