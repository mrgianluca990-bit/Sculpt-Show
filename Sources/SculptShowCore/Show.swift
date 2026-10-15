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
        let newCues = urls.filter { $0.isFileURL }.map { url -> Cue in
            var cue = Cue(name: url.deletingPathExtension().lastPathComponent)
            cue.elements.append(.audio(url))
            return cue
        }
        cueLists[index].cues.append(contentsOf: newCues)
        return newCues.map(\.id)
    }

    /// Create a silent/timed cue, optionally after the selected row.
    @discardableResult
    public mutating func addEmptyCue(to listID: UUID, after previousID: UUID? = nil) -> UUID? {
        guard let index = cueLists.firstIndex(where: { $0.id == listID }) else { return nil }
        let cue = Cue(name: "New Cue", durationSeconds: 5)
        let destination = previousID.flatMap { previous in
            cueLists[index].cues.firstIndex(where: { $0.id == previous }).map { $0 + 1 }
        } ?? cueLists[index].cues.count
        cueLists[index].cues.insert(cue, at: destination)
        return cue.id
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

    /// Insert a cue before another cue, or append to the destination list.
    /// Works within or across lists; cue and Rule IDs remain unchanged.
    @discardableResult
    public mutating func relocateCue(_ cueID: UUID, to destinationListID: UUID,
                                     before targetCueID: UUID? = nil) -> Bool {
        guard let sourceListIndex = cueLists.firstIndex(where: { $0.cues.contains(where: { $0.id == cueID }) }),
              let destinationListIndex = cueLists.firstIndex(where: { $0.id == destinationListID }),
              let sourceCueIndex = cueLists[sourceListIndex].cues.firstIndex(where: { $0.id == cueID }) else { return false }
        guard targetCueID != cueID else { return false }
        if let targetCueID, !cueLists[destinationListIndex].cues.contains(where: { $0.id == targetCueID }) {
            return false
        }
        let item = cueLists[sourceListIndex].cues.remove(at: sourceCueIndex)
        let destinationIndex = targetCueID.flatMap { id in
            cueLists[destinationListIndex].cues.firstIndex(where: { $0.id == id })
        } ?? cueLists[destinationListIndex].cues.count
        cueLists[destinationListIndex].cues.insert(item, at: destinationIndex)
        return true
    }

    /// Add content to an existing container, without changing its identity or rules.
    @discardableResult
    public mutating func appendAudio(_ urls: [URL], to cueID: UUID) -> Bool {
        guard let li = cueLists.firstIndex(where: { $0.cues.contains(where: { $0.id == cueID }) }),
              let ci = cueLists[li].cues.firstIndex(where: { $0.id == cueID }) else { return false }
        let audio = urls.filter(\.isFileURL).map(CueElement.audio)
        guard !audio.isEmpty else { return false }
        cueLists[li].cues[ci].elements.append(contentsOf: audio)
        return true
    }

    /// Create an independent cue directly after the original. Audio media is referenced, not copied.
    @discardableResult
    public mutating func duplicateCue(_ cueID: UUID, in listID: UUID) -> UUID? {
        guard let listIndex = cueLists.firstIndex(where: { $0.id == listID }),
              let cueIndex = cueLists[listIndex].cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        var copy = cueLists[listIndex].cues[cueIndex]
        copy.id = UUID()
        copy.name += " copy"
        copy.elements = copy.elements.map { element in
            var cloned = element
            cloned.id = UUID()
            return cloned
        }
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

/// Every cue starts as a timeline container. Capabilities live in ordered elements.
/// A cue without elements can still execute Interaction Rules during its timeline.
public enum CueElementKind: String, CaseIterable, Codable, Sendable {
    case audio
    case timecode
}

public enum CueDurationMode: String, Codable, Sendable {
    /// The container has its own explicit length, independent of media duration.
    case fixed
    /// Legacy .scshow compatibility: run until the last source audio ends.
    case mediaEnd
}

public struct CueElement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: CueElementKind
    public var name: String
    /// Absolute audio path; unused for timecode elements.
    public var sourcePath: String
    /// Placement on the cue timeline (seconds).
    public var startSeconds: Double
    /// Non-destructive region inside the audio source.
    public var inSeconds: Double
    public var outSeconds: Double?
    /// Timecode metadata, not yet an LTC/MTC output stream.
    public var timecodeStart: String
    public var frameRate: Int
    /// Independent level per audio element (linear gain, 1.0 = unity).
    public var gain: Double
    /// Muting an element never stops its transport or affects other elements.
    public var muted: Bool

    public init(id: UUID = UUID(), kind: CueElementKind, name: String,
                sourcePath: String = "", startSeconds: Double = 0,
                inSeconds: Double = 0, outSeconds: Double? = nil,
                timecodeStart: String = "00:00:00:00", frameRate: Int = 25,
                gain: Double = 1.0, muted: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sourcePath = sourcePath
        self.startSeconds = max(0, startSeconds)
        self.inSeconds = max(0, inSeconds)
        self.outSeconds = outSeconds.map { max(0, $0) }
        self.timecodeStart = timecodeStart
        self.frameRate = [24, 25, 30].contains(frameRate) ? frameRate : 25
        self.gain = gain.isFinite ? min(max(gain, 0), 1) : 1
        self.muted = muted
    }

    // Version 0.8.1 and older .scshow files lack gain/muted fields.
    // Decode these two settings with safe defaults so old projects still open.
    private enum CodingKeys: String, CodingKey {
        case id, kind, name, sourcePath, startSeconds, inSeconds, outSeconds
        case timecodeStart, frameRate, gain, muted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            kind: try c.decode(CueElementKind.self, forKey: .kind),
            name: try c.decode(String.self, forKey: .name),
            sourcePath: try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? "",
            startSeconds: try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0,
            inSeconds: try c.decodeIfPresent(Double.self, forKey: .inSeconds) ?? 0,
            outSeconds: try c.decodeIfPresent(Double.self, forKey: .outSeconds),
            timecodeStart: try c.decodeIfPresent(String.self, forKey: .timecodeStart) ?? "00:00:00:00",
            frameRate: try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 25,
            gain: try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1,
            muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        )
    }

    public static func audio(_ url: URL) -> CueElement {
        CueElement(kind: .audio, name: url.deletingPathExtension().lastPathComponent, sourcePath: url.path)
    }

    public static func timecode() -> CueElement {
        CueElement(kind: .timecode, name: "Timecode")
    }

    public static func isValidTimecode(_ value: String, frameRate: Int) -> Bool {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hh = Int(components[0]), let mm = Int(components[1]),
              let ss = Int(components[2]), let ff = Int(components[3]) else { return false }
        return (0..<24).contains(hh) && (0..<60).contains(mm) &&
               (0..<60).contains(ss) && (0..<frameRate).contains(ff)
    }
}

public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var elements: [CueElement]
    public var durationMode: CueDurationMode
    public var gain: Double
    public var fadeOutSeconds: Double
    public var enabled: Bool
    public var fadeInSeconds: Double
    public var loop: Bool
    public var followOnFinish: Bool
    public var preWaitSeconds: Double
    public var rules: [InteractionRule]
    public var ignoreParentRules: Bool
    /// This belongs to the cue, not the files inside it.
    public var durationSeconds: Double

    public var isEmpty: Bool { elements.isEmpty }
    public var hasAudio: Bool { elements.contains { $0.kind == .audio } }
    public var audioElements: [CueElement] { elements.filter { $0.kind == .audio } }

    /// The multitrack playout view of audio elements. Individual source edits
    /// remain in the legacy project payload for compatibility but do not alter
    /// stem playback: all tracks start at t=0 and play from their first sample.
    /// Timecode elements retain their separate timeline offset.
    public var alignedAudioElements: [CueElement] {
        audioElements.map { element in
            var aligned = element
            aligned.startSeconds = 0
            aligned.inSeconds = 0
            aligned.outSeconds = nil
            return aligned
        }
    }
    public var hasTimecode: Bool { elements.contains { $0.kind == .timecode } }

    /// Compatibility accessors for existing callers and projects. New edits should use elements.
    public var mediaPath: String {
        get { audioElements.first?.sourcePath ?? "" }
        set {
            if let index = elements.firstIndex(where: { $0.kind == .audio }) {
                if newValue.isEmpty { elements.remove(at: index) }
                else { elements[index].sourcePath = newValue }
            } else if !newValue.isEmpty {
                elements.append(CueElement.audio(URL(fileURLWithPath: newValue)))
            }
        }
    }
    public var inPointSeconds: Double {
        get { audioElements.first?.inSeconds ?? 0 }
        set { if let i = elements.firstIndex(where: { $0.kind == .audio }) { elements[i].inSeconds = max(0, newValue) } }
    }
    public var outPointSeconds: Double? {
        get { audioElements.first?.outSeconds }
        set { if let i = elements.firstIndex(where: { $0.kind == .audio }) { elements[i].outSeconds = newValue.map { max(0, $0) } } }
    }

    /// Legacy helper for the first audio element. A fixed cue's own duration is separate.
    public func playbackWindow(sourceDuration: Double) -> (start: Double, end: Double, duration: Double) {
        guard hasAudio else {
            let length = max(0, min(durationSeconds, 86400))
            return (0, length, length)
        }
        let source = max(0, sourceDuration)
        let start = min(max(0, inPointSeconds), source)
        let end = max(start, min(max(0, outPointSeconds ?? source), source))
        return (start, end, end - start)
    }

    /// The app uses this for the effective timeline length; source lengths are measured at playback.
    public func timelineLength(audioEnds: [Double]) -> Double {
        if durationMode == .fixed { return max(0, min(86400, durationSeconds)) }
        return max(audioEnds.max() ?? 0, 0)
    }

    public init(id: UUID = UUID(), name: String, mediaPath: String = "",
                gain: Double = 1.0, fadeOutSeconds: Double = 2.0,
                enabled: Bool = true, fadeInSeconds: Double = 0,
                loop: Bool = false, followOnFinish: Bool = false,
                preWaitSeconds: Double = 0,
                inPointSeconds: Double = 0, outPointSeconds: Double? = nil,
                durationSeconds: Double = 5,
                durationMode: CueDurationMode? = nil) {
        self.id = id
        self.name = name
        self.elements = mediaPath.isEmpty ? [] : [CueElement(kind: .audio,
            name: URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent,
            sourcePath: mediaPath, inSeconds: inPointSeconds, outSeconds: outPointSeconds)]
        self.durationMode = durationMode ?? (mediaPath.isEmpty ? .fixed : .mediaEnd)
        self.gain = min(max(gain, 0), 1)
        self.fadeOutSeconds = max(fadeOutSeconds, 0)
        self.enabled = enabled
        self.fadeInSeconds = max(fadeInSeconds, 0)
        self.loop = loop
        self.followOnFinish = followOnFinish
        self.preWaitSeconds = min(max(preWaitSeconds, 0), 600)
        self.rules = []
        self.ignoreParentRules = false
        self.durationSeconds = min(max(0, durationSeconds), 86400)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, elements, durationMode, gain, fadeOutSeconds, enabled
        case fadeInSeconds, loop, followOnFinish, preWaitSeconds, rules, ignoreParentRules
        case durationSeconds
        // Old show fields, decoded for migration but never written into the new format.
        case mediaPath, inPointSeconds, outPointSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let oldPath = try c.decodeIfPresent(String.self, forKey: .mediaPath) ?? ""
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            mediaPath: oldPath,
            gain: try c.decode(Double.self, forKey: .gain),
            fadeOutSeconds: try c.decode(Double.self, forKey: .fadeOutSeconds),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            fadeInSeconds: try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? 0,
            loop: try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false,
            followOnFinish: try c.decodeIfPresent(Bool.self, forKey: .followOnFinish) ?? false,
            preWaitSeconds: try c.decodeIfPresent(Double.self, forKey: .preWaitSeconds) ?? 0,
            inPointSeconds: try c.decodeIfPresent(Double.self, forKey: .inPointSeconds) ?? 0,
            outPointSeconds: try c.decodeIfPresent(Double.self, forKey: .outPointSeconds),
            durationSeconds: try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 5,
            durationMode: try c.decodeIfPresent(CueDurationMode.self, forKey: .durationMode)
        )
        if let contents = try c.decodeIfPresent([CueElement].self, forKey: .elements) {
            elements = contents
        }
        rules = try c.decodeIfPresent([InteractionRule].self, forKey: .rules) ?? []
        ignoreParentRules = try c.decodeIfPresent(Bool.self, forKey: .ignoreParentRules) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(elements, forKey: .elements)
        try c.encode(durationMode, forKey: .durationMode)
        try c.encode(gain, forKey: .gain)
        try c.encode(fadeOutSeconds, forKey: .fadeOutSeconds)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(fadeInSeconds, forKey: .fadeInSeconds)
        try c.encode(loop, forKey: .loop)
        try c.encode(followOnFinish, forKey: .followOnFinish)
        try c.encode(preWaitSeconds, forKey: .preWaitSeconds)
        try c.encode(rules, forKey: .rules)
        try c.encode(ignoreParentRules, forKey: .ignoreParentRules)
        try c.encode(durationSeconds, forKey: .durationSeconds)
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
    /// Shared by the File > Open panel and Finder/LaunchServices document opens.
    public static func decode(contentsOf url: URL) throws -> Show {
        try decode(Data(contentsOf: url))
    }

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
