import Foundation

/// Renames list-owned directories and their stored references as one save operation.
/// Stage every source first, so swapped names and case-only renames work too.
enum ShowProjectFolderMigration {
    static func saving(_ show: Show, documentURL: URL,
                       write: (Show) throws -> ShowProjectPackage.Saved) throws -> ShowProjectPackage.Saved {
        let fm = FileManager.default
        let previous = try ShowCodec.decode(contentsOf: documentURL)
        let root = documentURL.deletingLastPathComponent()
        let audio = root.appendingPathComponent("Audio Files", isDirectory: true)
        var moves: [(old: URL, new: URL, stage: URL)] = []
        let staging = root.appendingPathComponent(".list-rename-\(UUID().uuidString)", isDirectory: true)
        for list in show.cueLists {
            guard let prior = previous.cueLists.first(where: { $0.id == list.id }) else { continue }
            let old = audio.appendingPathComponent(ShowProjectPackage.listFolderName(prior), isDirectory: true)
            let new = audio.appendingPathComponent(ShowProjectPackage.listFolderName(list), isDirectory: true)
            guard old.path != new.path, fm.fileExists(atPath: old.path) else { continue }
            moves.append((old, new, staging.appendingPathComponent(list.id.uuidString, isDirectory: true)))
        }
        guard !moves.isEmpty else { return try write(show) }
        let sourcePaths = Set(moves.map { $0.old.path.lowercased() })
        var destinations: [(url: URL, stage: URL, moveIndex: Int, files: [URL])] = []
        for (i, move) in moves.enumerated() where fm.fileExists(atPath: move.new.path) && !sourcePaths.contains(move.new.path.lowercased()) {
            let files = try fm.contentsOfDirectory(at: move.new, includingPropertiesForKeys: [.isRegularFileKey])
            let owner = show.cueLists.first { ShowProjectPackage.listFolderName($0) == move.new.lastPathComponent }
            let owned = Set((owner?.cues.flatMap { $0.audioElements.map(\.sourcePath) } ?? [])
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            let others = Set(show.cueLists.filter { $0.id != owner?.id }
                .flatMap { $0.cues.flatMap { $0.audioElements.map(\.sourcePath) } }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            // A normalization started after Rename may already have created the
            // new folder. Merge only its uniquely owned files, never user data.
            for file in files {
                guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                      owned.contains(file.resolvingSymlinksInPath().path), !others.contains(file.resolvingSymlinksInPath().path),
                      !fm.fileExists(atPath: move.old.appendingPathComponent(file.lastPathComponent).path) else {
                    throw ShowProjectPackage.Failure.destinationExists(move.new.lastPathComponent)
                }
            }
            destinations.append((move.new, staging.appendingPathComponent("destination-\(i)"), i, files))
        }
        // Replace all prefixes simultaneously; sequential substitutions corrupt swaps.
        func remap(_ value: String) -> String {
            for move in moves {
                for (old, new) in [
                    (move.old.path + "/", move.new.path + "/"),
                    ("Audio Files/" + move.old.lastPathComponent + "/", "Audio Files/" + move.new.lastPathComponent + "/")
                ] where value.hasPrefix(old) {
                    return new + value.dropFirst(old.count)
                }
            }
            return value
        }
        func remapJSON(_ value: Any) -> Any {
            if let text = value as? String { return remap(text) }
            if let array = value as? [Any] { return array.map(remapJSON) }
            if let object = value as? [String: Any] { return object.mapValues(remapJSON) }
            return value
        }
        var updated = show
        for li in updated.cueLists.indices {
            for ci in updated.cueLists[li].cues.indices {
                for ei in updated.cueLists[li].cues[ci].elements.indices {
                    updated.cueLists[li].cues[ci].elements[ei].sourcePath =
                        remap(updated.cueLists[li].cues[ci].elements[ei].sourcePath)
                }
            }
        }
        // Preserve previous saved versions and bridge sessions/receipts as well.
        // WAVs and unrelated user files are never parsed or rewritten.
        var replacements: [(url: URL, old: Data, new: Data)] = []
        let documents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "scshow" }
        var candidates = documents
        if let bridgeFiles = fm.enumerator(at: root.appendingPathComponent("bridge"),
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in bridgeFiles where ["json", "scdaw", "scraft", "sculptbridge", "txt"].contains(url.pathExtension.lowercased()) {
                if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { candidates.append(url) }
            }
        }
        for url in candidates {
            let bytes = try Data(contentsOf: url)
            let rewritten: Data
            if url.pathExtension.lowercased() == "txt" {
                var text = String(decoding: bytes, as: UTF8.self)
                let token = UUID().uuidString
                for (i, move) in moves.enumerated() {
                    text = text.replacingOccurrences(of: move.old.path + "/", with: "__" + token + "_" + String(i) + "__")
                    text = text.replacingOccurrences(of: (move.old.path + "/").replacingOccurrences(of: "/", with: "\\/"),
                        with: "__" + token + "_escaped_" + String(i) + "__")
                }
                for (i, move) in moves.enumerated() {
                    text = text.replacingOccurrences(of: "__" + token + "_" + String(i) + "__", with: move.new.path + "/")
                    text = text.replacingOccurrences(of: "__" + token + "_escaped_" + String(i) + "__",
                        with: (move.new.path + "/").replacingOccurrences(of: "/", with: "\\/"))
                }
                rewritten = Data(text.utf8)
            } else {
                let json = try JSONSerialization.jsonObject(with: bytes)
                rewritten = try JSONSerialization.data(withJSONObject: remapJSON(json), options: [.sortedKeys])
            }
            replacements.append((url, bytes, rewritten))
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var staged: [Int] = []
        var installed: [Int] = []
        var stagedDestinations: [Int] = []
        var merged: [(source: URL, destination: URL)] = []
        do {
            for i in destinations.indices {
                try fm.moveItem(at: destinations[i].url, to: destinations[i].stage)
                stagedDestinations.append(i)
            }
            for i in moves.indices {
                try fm.moveItem(at: moves[i].old, to: moves[i].stage)
                staged.append(i)
            }
            for destination in destinations {
                for file in destination.files {
                    let source = destination.stage.appendingPathComponent(file.lastPathComponent)
                    let target = moves[destination.moveIndex].stage.appendingPathComponent(file.lastPathComponent)
                    try fm.moveItem(at: source, to: target)
                    merged.append((source, target))
                }
            }
            for i in moves.indices {
                try fm.moveItem(at: moves[i].stage, to: moves[i].new)
                installed.append(i)
            }
            for item in replacements { try item.new.write(to: item.url, options: .atomic) }
            let result = try write(updated)
            try? fm.removeItem(at: staging) // staging is now empty
            return result
        } catch {
            let original = error
            var failures: [String] = []
            for item in replacements {
                do { try item.old.write(to: item.url, options: .atomic) }
                catch { failures.append(item.url.path) }
            }
            for i in installed.reversed() {
                do { try fm.moveItem(at: moves[i].new, to: moves[i].stage) }
                catch { failures.append(moves[i].new.path) }
            }
            for file in merged.reversed() {
                do { try fm.moveItem(at: file.destination, to: file.source) }
                catch { failures.append(file.destination.path) }
            }
            for i in staged.reversed() where fm.fileExists(atPath: moves[i].stage.path) {
                do { try fm.moveItem(at: moves[i].stage, to: moves[i].old) }
                catch { failures.append(moves[i].stage.path) }
            }
            for i in stagedDestinations.reversed() {
                do { try fm.moveItem(at: destinations[i].stage, to: destinations[i].url) }
                catch { failures.append(destinations[i].stage.path) }
            }
            if failures.isEmpty { try? fm.removeItem(at: staging); throw original }
            throw ShowProjectPackage.Failure.missingSource(
                "Save failed: \(original.localizedDescription). Recovery files retained at \(staging.path); could not restore: \(failures.joined(separator: ", "))")
        }
    }
}
