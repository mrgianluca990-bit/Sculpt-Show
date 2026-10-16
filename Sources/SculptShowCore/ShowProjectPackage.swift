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

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let name): return "A folder named \(name) already exists. Choose a different Show name or destination."
            case .invalidDestination: return "Choose a valid destination for the .scshow project document."
            case .missingSource(let path): return "Project media is missing or unreadable: \(path)"
            case .unsafeReference(let path): return "Unsafe media path in Show document: \(path)"
            case .notPackaged: return "This is a legacy stand-alone .scshow. Use Save As to create a portable Show folder."
            }
        }
    }

    public static func isPackaged(_ documentURL: URL) -> Bool {
        let folder = documentURL.deletingLastPathComponent()
        return documentURL.pathExtension.lowercased() == "scshow"
            && folder.lastPathComponent == documentURL.deletingPathExtension().lastPathComponent
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio Files", isDirectory: true).path)
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
        let stored = try prepare(show, copyInto: root, existingProjectRoot: root)
        try ShowCodec.encode(stored).write(to: documentURL, options: .atomic)
        return Saved(documentURL: documentURL, runtimeShow: try resolve(stored, documentURL: documentURL))
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
        for li in stored.cueLists.indices {
            let list = stored.cueLists[li]
            let listFolder = String(format: "%02d - %@-%@", li + 1,
                                    safeName(list.name), String(list.id.uuidString.prefix(8)))
            var reusedWithinList: [String: String] = [:]
            for ci in stored.cueLists[li].cues.indices {
                for ei in stored.cueLists[li].cues[ci].elements.indices {
                    let element = stored.cueLists[li].cues[ci].elements[ei]
                    guard element.kind == .audio, !element.sourcePath.isEmpty else { continue }
                    let source = URL(fileURLWithPath: element.sourcePath).standardizedFileURL
                    guard fm.fileExists(atPath: source.path), fm.isReadableFile(atPath: source.path) else {
                        throw Failure.missingSource(source.path)
                    }
                    // Existing media inside the package stays at its current
                    // path: saving again never duplicates or overwrites it.
                    if let extantRoot, source.path.hasPrefix(extantRoot.path + "/") {
                        let rel = String(source.path.dropFirst(extantRoot.path.count + 1))
                        stored.cueLists[li].cues[ci].elements[ei].sourcePath = rel
                        continue
                    }
                    if let relative = reusedWithinList[source.path] {
                        stored.cueLists[li].cues[ci].elements[ei].sourcePath = relative
                        continue
                    }
                    let fileExt = source.pathExtension
                    let basename = safeName(source.deletingPathExtension().lastPathComponent)
                    let shortID = String(element.id.uuidString.prefix(8))
                    let unique = "\(basename)-\(shortID)"
                    let subdirectory = "Audio Files/\(listFolder)"
                    var relative = "\(subdirectory)/\(unique)\(fileExt.isEmpty ? "" : "." + fileExt)"
                    var destination = root.appendingPathComponent(relative)
                    // A different source using the same element ID must never
                    // overwrite the previously packaged audio.
                    while fm.fileExists(atPath: destination.path) {
                        relative = "\(subdirectory)/\(unique)-\(UUID().uuidString.prefix(8))\(fileExt.isEmpty ? "" : "." + fileExt)"
                        destination = root.appendingPathComponent(relative)
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

    private static func safeName(_ raw: String) -> String {
        let sanitized = raw.unicodeScalars.map { c -> String in
            if CharacterSet(charactersIn: "/\\:\n\r\t").contains(c) || CharacterSet.controlCharacters.contains(c) { return "-" }
            return String(c)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "Untitled" : sanitized).prefix(55))
    }
}
