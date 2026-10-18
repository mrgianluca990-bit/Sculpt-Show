import Foundation

/// A portable Show folder containing its .scshow document and all referenced audio.
/// The in-memory Show keeps absolute paths for the playback engine; the document
/// stores only project-relative paths under "Audio Files/". Legacy absolute paths
/// are still accepted by the regular ShowCodec decoder.
public enum ShowProjectPackage {
    public struct Saved: Sendable {
        public let documentURL: URL
        public let runtimeShow: Show
    }

    public enum Failure: LocalizedError {
        case destinationExists(String)
        case invalidDestination
        case missingSource(String)
        case unsafeReference(String)
        case notPackaged
        case duplicateListName(String)

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let name): return "A folder named \(name) already exists. Choose a different Show name or destination."
            case .invalidDestination: return "Choose a valid destination for the .scshow project document."
            case .missingSource(let path): return "Project media is missing or unreadable: \(path)"
            case .unsafeReference(let path): return "Unsafe media path in Show document: \(path)"
            case .notPackaged: return "This is a legacy stand-alone .scshow. Use Save As to create a portable Show folder."
            case .duplicateListName(let name): return "Two Cue Lists would use the same audio folder: \(name). Rename one list before saving."
            }
        }
    }

    public static func isPackaged(_ documentURL: URL) -> Bool {
        let folder = documentURL.deletingLastPathComponent()
        guard documentURL.pathExtension.lowercased() == "scshow",
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio Files", isDirectory: true).path) else { return false }
        let basename = documentURL.deletingPathExtension().lastPathComponent
        let project = folder.lastPathComponent
        if basename == project { return true }
        let prefix = project + "_"
        guard basename.hasPrefix(prefix) else { return false }
        let components = String(basename.dropFirst(prefix.count)).split(separator: "_", omittingEmptySubsequences: false)
        return components.count == 4 &&
            [4, 2, 2, 3].enumerated().allSatisfy { index, length in
                components[index].count == length && components[index].allSatisfy { $0.isNumber }
            }
    }

    /// Media directories use the readable Cue List name without numbering or IDs.
    /// Renamed lists are migrated to their new media folder on the next Save.
    public static func audioDirectory(for listID: UUID, in show: Show,
                                      documentURL: URL) throws -> URL {
        guard isPackaged(documentURL) else { throw Failure.notPackaged }
        try validateUniqueListFolders(show)
        guard let list = show.cueLists.first(where: { $0.id == listID }) else {
            throw Failure.invalidDestination
        }
        let folder = documentURL.deletingLastPathComponent()
            .appendingPathComponent("Audio Files", isDirectory: true)
            .appendingPathComponent(listFolderName(list), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func listFolderName(_ list: CueList) -> String {
        safeName(list.name)
    }

    /// Prevent duplicate folders on case-insensitive macOS volumes and after
    /// sanitizing illegal path characters. Collisions are explicit errors.
    private static func validateUniqueListFolders(_ show: Show) throws {
        var names: Set<String> = []
        for list in show.cueLists {
            let name = listFolderName(list)
            guard names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                            locale: Locale(identifier: "en_US_POSIX"))).inserted else {
                throw Failure.duplicateListName(name)
            }
        }
    }

    /// Create "My Show/My Show.scshow" and "My Show/Audio Files/<cue list>/...".
    /// Nothing is moved into the final destination before ALL media and the show
    /// document have been written successfully into a temporary sibling folder.
    public static func create(_ show: Show, requestedDocumentURL: URL) throws -> Saved {
        let fm = FileManager.default
        guard requestedDocumentURL.isFileURL,
              requestedDocumentURL.pathExtension.lowercased() == "scshow" else { throw Failure.invalidDestination }
        let filename = requestedDocumentURL.lastPathComponent
        let root = requestedDocumentURL.deletingPathExtension().standardizedFileURL
        guard !fm.fileExists(atPath: root.path) else { throw Failure.destinationExists(root.lastPathComponent) }
        let stage = root.deletingLastPathComponent().appendingPathComponent(".sculpt-show-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        // Ensure even shows without audio contain the standard project structure.
        try fm.createDirectory(at: stage.appendingPathComponent("Audio Files", isDirectory: true), withIntermediateDirectories: true)
        try validateUniqueListFolders(show)
        let stored = try prepare(show, copyInto: stage, existingProjectRoot: nil)
        let stageDocument = stage.appendingPathComponent(filename)
        try ShowCodec.encode(stored).write(to: stageDocument, options: .atomic)
        try fm.moveItem(at: stage, to: root)
        let actualDocument = root.appendingPathComponent(filename)
        return Saved(documentURL: actualDocument,
                     runtimeShow: try resolve(stored, documentURL: actualDocument))
    }

    /// Re-save an existing portable project. Imported/newly normalized media are
    /// copied inside the folder before its .scshow is atomically replaced. Old
    /// audio remains present (no destructive garbage collection during Save).
    public static func save(_ show: Show, documentURL: URL) throws -> Saved {
        guard isPackaged(documentURL) else { throw Failure.notPackaged }
        let root = documentURL.deletingLastPathComponent()
        try validateUniqueListFolders(show)
        return try ShowProjectFolderMigration.saving(show, documentURL: documentURL) { renamed in
            let stored = try prepare(renamed, copyInto: root, existingProjectRoot: root)
            let runtime = try resolve(stored, documentURL: documentURL)
            try ShowCodec.encode(stored).write(to: documentURL, options: .atomic)
            return Saved(documentURL: documentURL, runtimeShow: runtime)
        }
    }

    /// A version is a standalone .scshow DOCUMENT inside the same portable
    /// project folder, not another project or an audio copy. The main .scshow
    /// remains untouched, and only new external media needs to be packaged.
    public static func saveVersion(_ show: Show, documentURL: URL,
                                   on date: Date = Date()) throws -> Saved {
        guard isPackaged(documentURL) else { throw Failure.notPackaged }
        let root = documentURL.deletingLastPathComponent()
        let name = root.lastPathComponent
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw Failure.invalidDestination
        }
        let prefix = String(format: "%@_%04d_%02d_%02d_", name, year, month, day)
        var sequence = 1
        var versionURL: URL
        repeat {
            let filename = prefix + String(format: "%03d", sequence) + ".scshow"
            versionURL = root.appendingPathComponent(filename)
            sequence += 1
        } while FileManager.default.fileExists(atPath: versionURL.path)

        let stored = try prepare(show, copyInto: root, existingProjectRoot: root)
        try ShowCodec.encode(stored).write(to: versionURL, options: .atomic)
        return Saved(documentURL: versionURL,
                     runtimeShow: try resolve(stored, documentURL: versionURL))
    }

    /// Make project-relative paths absolute before giving a show to the audio
    /// engine or the Show -> DAW bridge. Legacy absolute paths are unmodified.
    public static func resolve(_ show: Show, documentURL: URL) throws -> Show {
        let root = documentURL.deletingLastPathComponent().standardizedFileURL
        var updated = show
        for li in updated.cueLists.indices {
            for ci in updated.cueLists[li].cues.indices {
                for ei in updated.cueLists[li].cues[ci].elements.indices {
                    let element = updated.cueLists[li].cues[ci].elements[ei]
                    guard element.kind == .audio, !element.sourcePath.isEmpty else { continue }
                    if let original = element.originalSourcePath, !(original as NSString).isAbsolutePath {
                        let source = root.appendingPathComponent(original).standardizedFileURL
                        guard source.path.hasPrefix(root.path + "/") else { throw Failure.unsafeReference(original) }
                        updated.cueLists[li].cues[ci].elements[ei].originalSourcePath = source.path
                    }
                    if (element.sourcePath as NSString).isAbsolutePath { continue }
                    let absolute = root.appendingPathComponent(element.sourcePath).standardizedFileURL
                    guard absolute.path.hasPrefix(root.path + "/") else {
                        throw Failure.unsafeReference(element.sourcePath)
                    }
                    updated.cueLists[li].cues[ci].elements[ei].sourcePath = absolute.path
                }
            }
        }
        return updated
    }

    private static func prepare(_ show: Show, copyInto root: URL, existingProjectRoot: URL?) throws -> Show {
        let fm = FileManager.default
        var stored = show
        let extantRoot = existingProjectRoot?.standardizedFileURL
        try validateUniqueListFolders(show)
        for li in stored.cueLists.indices {
            let list = stored.cueLists[li]
            let folder = listFolderName(list)
            var reusedWithinList: [String: String] = [:]
            for ci in stored.cueLists[li].cues.indices {
                for ei in stored.cueLists[li].cues[ci].elements.indices {
                    let element = stored.cueLists[li].cues[ci].elements[ei]
                    guard element.kind == .audio, !element.sourcePath.isEmpty else { continue }
                    let source = URL(fileURLWithPath: element.sourcePath).standardizedFileURL
                    guard fm.fileExists(atPath: source.path), fm.isReadableFile(atPath: source.path) else {
                        throw Failure.missingSource(source.path)
                    }
                    if let original = element.originalSourcePath {
                        let origin = URL(fileURLWithPath: original).standardizedFileURL
                        guard fm.isReadableFile(atPath: origin.path) else { throw Failure.missingSource(origin.path) }
                        let relative: String
                        if let extantRoot, origin.path.hasPrefix(extantRoot.path + "/") {
                            relative = String(origin.path.dropFirst(extantRoot.path.count + 1))
                        } else {
                            relative = "Original Audio/\(element.id.uuidString)/" + safeFilename(origin.lastPathComponent)
                            let destination = root.appendingPathComponent(relative)
                            if !fm.fileExists(atPath: destination.path) {
                                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try fm.copyItem(at: origin, to: destination)
                            } else if !fm.contentsEqual(atPath: origin.path, andPath: destination.path) {
                                throw Failure.destinationExists(relative)
                            }
                        }
                        stored.cueLists[li].cues[ci].elements[ei].originalSourcePath = relative
                    }
                    if let previous = reusedWithinList[source.path] {
                        stored.cueLists[li].cues[ci].elements[ei].sourcePath = previous
                        continue
                    }
                    let subdirectory = "Audio Files/\(folder)"
                    let inPackage = extantRoot.map { source.path.hasPrefix($0.path + "/") } ?? false
                    let currentRelative: String? = inPackage && extantRoot != nil
                        ? String(source.path.dropFirst(extantRoot!.path.count + 1)) : nil
                    let legacy = currentRelative?.hasPrefix("Audio Files/") == true &&
                        currentRelative?.hasPrefix(subdirectory + "/") == false
                    let proposed = legacy ? restoredFilename(source.lastPathComponent, in: list)
                                          : source.lastPathComponent
                    let name = safeFilename(proposed)
                    // Already in the right folder with a readable name: do not copy.
                    if let currentRelative, currentRelative.hasPrefix(subdirectory + "/"),
                       source.lastPathComponent == name {
                        reusedWithinList[source.path] = currentRelative
                        stored.cueLists[li].cues[ci].elements[ei].sourcePath = currentRelative
                        continue
                    }
                    var relative = "\(subdirectory)/\(name)"
                    var destination = root.appendingPathComponent(relative)
                    let candidate = URL(fileURLWithPath: name)
                    let stem = candidate.deletingPathExtension().lastPathComponent
                    let ext = candidate.pathExtension
                    var suffix = 2
                    // Same-name media must never overwrite a different source.
                    while fm.fileExists(atPath: destination.path) {
                        let newName = "\(stem)_\(suffix)\(ext.isEmpty ? "" : "." + ext)"
                        relative = "\(subdirectory)/\(newName)"
                        destination = root.appendingPathComponent(relative)
                        suffix += 1
                    }
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    do { try fm.copyItem(at: source, to: destination) }
                    catch { throw Failure.missingSource("\(source.path) — \(error.localizedDescription)") }
                    reusedWithinList[source.path] = relative
                    stored.cueLists[li].cues[ci].elements[ei].sourcePath = relative
                }
            }
        }
        return stored
    }

    /// Older packages suffixed media with eight hex characters derived from
    /// their element ID. Remove only a suffix matching an element in this list.
    private static func restoredFilename(_ name: String, in list: CueList) -> String {
        let url = URL(fileURLWithPath: name)
        var stem = url.deletingPathExtension().lastPathComponent
        let ids = Set(list.cues.flatMap { $0.audioElements.map { String($0.id.uuidString.prefix(8)) } })
        let parts = stem.split(separator: "-")
        // Early Sculpt normalization used <name>-<element-id>-<random-id>.wav.
        // Recover the original stem and append the stable _normalized suffix.
        if parts.count >= 3,
           parts[parts.count - 1].count == 8,
           parts[parts.count - 1].allSatisfy({ $0.isHexDigit }),
           ids.contains(String(parts[parts.count - 2])) {
            stem = parts.dropLast(2).joined(separator: "-") + "_normalized"
        } else if let suffix = parts.last,
                  suffix.count == 8, ids.contains(String(suffix)) {
            stem.removeLast(9)
        }
        return stem + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
    }

    /// Sanitize only path-hostile characters, retaining original case, spaces,
    /// musical accents and the extension. No opaque ID in normal filenames.
    private static func safeFilename(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = safeName(url.deletingPathExtension().lastPathComponent)
        return base + (ext.isEmpty ? "" : "." + ext)
    }

    private static func safeName(_ raw: String) -> String {
        let sanitized = raw.unicodeScalars.map { c -> String in
            if CharacterSet(charactersIn: "/\\:\n\r\t").contains(c) || CharacterSet.controlCharacters.contains(c) { return "-" }
            return String(c)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "Untitled" : sanitized).prefix(55))
    }
}
