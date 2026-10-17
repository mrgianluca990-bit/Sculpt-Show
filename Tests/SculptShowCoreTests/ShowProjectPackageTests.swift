import XCTest
@testable import SculptShowCore

final class ShowProjectPackageTests: XCTestCase {
    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sculpt-package-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioFile(_ directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([0x52, 0x49, 0x46, 0x46, 0x00]).write(to: url)
        return url
    }

    func testNewFolderCopiesAudioGroupedByCueListAndUsesRelativePaths() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try audioFile(dir, name: "test mono.wav")
        let one = CueList(name: "Drums", cues: [Cue(name: "Kick", mediaPath: source.path), Cue(name: "Snare", mediaPath: source.path)])
        let two = CueList(name: "FX", cues: [Cue(name: "Impact", mediaPath: source.path)])
        var show = Show(name: "My Show", cueLists: [one, two])
        show.cueLists[0].cues[0].markers.append(CueMarker(name: "Check", positionSeconds: 1.5))
        let saved = try ShowProjectPackage.create(show, requestedDocumentURL: dir.appendingPathComponent("My Show.scshow"))
        XCTAssertEqual(saved.documentURL.path, dir.appendingPathComponent("My Show/My Show.scshow").path)
        XCTAssertTrue(ShowProjectPackage.isPackaged(saved.documentURL))
        let stored = try ShowCodec.decode(contentsOf: saved.documentURL)
        let paths = stored.cueLists.flatMap { $0.cues.flatMap { $0.audioElements.map(\.sourcePath) } }
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[0], paths[1], "same source in same Cue List is copied only once")
        XCTAssertNotEqual(paths[1], paths[2], "a separate Cue List receives its own media subfolder")
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("Audio Files/") && !$0.hasPrefix("/") })
        XCTAssertTrue(paths[0].contains("Drums"))
        XCTAssertTrue(paths[2].contains("FX"))
        let resolved = try ShowProjectPackage.resolve(stored, documentURL: saved.documentURL)
        XCTAssertEqual(resolved, saved.runtimeShow)
        XCTAssertEqual(resolved.cueLists[0].cues[0].markers.count, 1)
        for path in resolved.cueLists.flatMap({ $0.cues.flatMap { $0.audioElements.map(\.sourcePath) } }) {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0x52, 0x49, 0x46, 0x46, 0x00]))
        }
        // The complete project may be copied to a different disk/computer.
        let relocatedParent = dir.appendingPathComponent("New Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: relocatedParent, withIntermediateDirectories: true)
        let movedRoot = relocatedParent.appendingPathComponent("My Show", isDirectory: true)
        try FileManager.default.moveItem(at: saved.documentURL.deletingLastPathComponent(), to: movedRoot)
        let movedDocument = movedRoot.appendingPathComponent("My Show.scshow")
        let moved = try ShowProjectPackage.resolve(ShowCodec.decode(contentsOf: movedDocument), documentURL: movedDocument)
        XCTAssertTrue(moved.cueLists.flatMap { $0.cues.flatMap { $0.audioElements.map(\.sourcePath) } }
            .allSatisfy { FileManager.default.fileExists(atPath: $0) && $0.hasPrefix(movedRoot.path) })
    }

    func testResaveReusesPackedAudioAndImportsOnlyNewMedia() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try audioFile(dir, name: "first.wav")
        let second = try audioFile(dir, name: "second.wav")
        let initial = Show(name: "Concert", cueLists: [CueList(name: "Main", cues: [Cue(name: "A", mediaPath: first.path)])])
        let created = try ShowProjectPackage.create(initial, requestedDocumentURL: dir.appendingPathComponent("Concert.scshow"))
        var changed = created.runtimeShow
        let priorPath = changed.cueLists[0].cues[0].mediaPath
        changed.cueLists[0].cues.append(Cue(name: "B", mediaPath: second.path))
        let saved = try ShowProjectPackage.save(changed, documentURL: created.documentURL)
        XCTAssertEqual(saved.runtimeShow.cueLists[0].cues[0].mediaPath, priorPath)
        XCTAssertEqual(saved.runtimeShow.cueLists[0].cues.count, 2)
        XCTAssertNotEqual(saved.runtimeShow.cueLists[0].cues[1].mediaPath, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.runtimeShow.cueLists[0].cues[1].mediaPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "original external audio stays untouched")
    }

    func testMissingAudioDoesNotCreateProjectFolder() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = Show(name: "Broken", cueLists: [CueList(name: "Cue List", cues: [Cue(name: "A", mediaPath: dir.appendingPathComponent("missing.wav").path)])])
        XCTAssertThrowsError(try ShowProjectPackage.create(show, requestedDocumentURL: dir.appendingPathComponent("Broken.scshow")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Broken").path))
    }

    func testLegacyAbsolutePathStillLoadsAndEmptyShowCreatesAudioFolder() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try audioFile(dir, name: "original.wav")
        let old = Show(name: "Legacy", cueLists: [CueList(name: "Old", cues: [Cue(name: "Old cue", mediaPath: audio.path)])])
        let legacyDoc = dir.appendingPathComponent("legacy.scshow")
        try ShowCodec.encode(old).write(to: legacyDoc)
        let loaded = try ShowProjectPackage.resolve(ShowCodec.decode(contentsOf: legacyDoc), documentURL: legacyDoc)
        XCTAssertEqual(loaded, old)
        XCTAssertFalse(ShowProjectPackage.isPackaged(legacyDoc))
        let empty = Show(name: "Empty")
        let saved = try ShowProjectPackage.create(empty, requestedDocumentURL: dir.appendingPathComponent("Empty.scshow"))
        XCTAssertTrue(ShowProjectPackage.isPackaged(saved.documentURL))
        XCTAssertEqual(try ShowCodec.decode(contentsOf: saved.documentURL), empty)
    }

    func testNormalizedAudioDirectoryFollowsCleanCueListNameAfterRename() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try audioFile(dir, name: "original.wav")
        let original = Show(name: "Concert", cueLists: [
            CueList(name: "Drums", cues: [Cue(name: "Snare", mediaPath: source.path)])
        ])
        let saved = try ShowProjectPackage.create(original,
            requestedDocumentURL: dir.appendingPathComponent("Concert.scshow"))
        let id = saved.runtimeShow.cueLists[0].id
        let audioRoot = saved.documentURL.deletingLastPathComponent()
            .appendingPathComponent("Audio Files")
        let directory = try ShowProjectPackage.audioDirectory(for: id,
            in: saved.runtimeShow, documentURL: saved.documentURL)
        XCTAssertEqual(directory.deletingLastPathComponent(), audioRoot)
        XCTAssertEqual(directory.lastPathComponent, "Drums")
        var edited = saved.runtimeShow
        edited.cueLists[0].name = "Percussion"
        let renamed = try ShowProjectPackage.audioDirectory(for: id,
            in: edited, documentURL: saved.documentURL)
        XCTAssertEqual(renamed.lastPathComponent, "Percussion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        let savedAgain = try ShowProjectPackage.save(edited, documentURL: saved.documentURL)
        let referenced = savedAgain.runtimeShow.cueLists[0].cues[0].mediaPath
        XCTAssertTrue(referenced.contains("/Audio Files/Percussion/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced))
    }

    func testCleanAudioNamesAndCollisionSuffixes() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A", isDirectory: true)
        let b = dir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let first = try audioFile(a, name: "music.wav")
        let second = try audioFile(b, name: "music.wav")
        let show = Show(name: "Concert", cueLists: [CueList(name: "Background Music", cues: [
            Cue(name: "First", mediaPath: first.path), Cue(name: "Second", mediaPath: second.path)
        ])])
        let saved = try ShowProjectPackage.create(show,
            requestedDocumentURL: dir.appendingPathComponent("Concert.scshow"))
        let stored = try ShowCodec.decode(contentsOf: saved.documentURL)
        let paths = stored.cueLists[0].cues.map { $0.audioElements[0].sourcePath }
        XCTAssertEqual(paths[0], "Audio Files/Background Music/music.wav")
        XCTAssertEqual(paths[1], "Audio Files/Background Music/music_2.wav")
    }

    func testDuplicateCueListNamesFailWithoutOverwritingAudio() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let show = Show(name: "Concert", cueLists: [
            CueList(name: "Audio"), CueList(name: "audio")
        ])
        XCTAssertThrowsError(try ShowProjectPackage.create(show,
            requestedDocumentURL: dir.appendingPathComponent("Concert.scshow")))
    }

    func testNormalizedWAVIsPortableWithItsCueAfterSaveAndRelocation() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try audioFile(dir, name: "source.wav")
        let initial = Show(name: "Portable", cueLists: [
            CueList(name: "Music", cues: [Cue(name: "Stereo", mediaPath: source.path)])
        ])
        let saved = try ShowProjectPackage.create(initial,
            requestedDocumentURL: dir.appendingPathComponent("Portable.scshow"))
        var edited = saved.runtimeShow
        let listID = edited.cueLists[0].id
        let destination = try ShowProjectPackage.audioDirectory(for: listID,
            in: edited, documentURL: saved.documentURL)
            .appendingPathComponent("Normalized-Stereo.wav")
        let writer = try WaveFloat32Writer(url: destination,
            sampleRate: 48000, channels: 2)
        try writer.append(planar: [[0.1, -0.2], [-0.3, 0.4]], gain: 1)
        try writer.finalize()
        edited.cueLists[0].cues[0].elements[0].sourcePath = destination.path
        _ = try ShowProjectPackage.save(edited, documentURL: saved.documentURL)

        let stored = try ShowCodec.decode(contentsOf: saved.documentURL)
        let relative = stored.cueLists[0].cues[0].audioElements[0].sourcePath
        XCTAssertTrue(relative.hasPrefix("Audio Files/"))
        XCTAssertFalse(relative.hasPrefix("/"))
        let newParent = dir.appendingPathComponent("Another Computer")
        try FileManager.default.createDirectory(at: newParent, withIntermediateDirectories: true)
        let newRoot = newParent.appendingPathComponent("Portable")
        try FileManager.default.moveItem(at: saved.documentURL.deletingLastPathComponent(), to: newRoot)
        let reopened = try ShowProjectPackage.resolve(
            ShowCodec.decode(contentsOf: newRoot.appendingPathComponent("Portable.scshow")),
            documentURL: newRoot.appendingPathComponent("Portable.scshow"))
        let reopenedURL = URL(fileURLWithPath: reopened.cueLists[0].cues[0].audioElements[0].sourcePath)
        XCTAssertTrue(reopenedURL.path.hasPrefix(newRoot.path))
        let audio = try WavePCMReader(url: reopenedURL)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.frameCount, 2)
        XCTAssertEqual(try audio.readFrames()[1][1], 0.4, accuracy: 0.00001)
    }

    func testRejectsEscapingRelativePath() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        var show = Show(name: "Untrusted")
        show.cueLists[0].cues.append(Cue(name: "File", mediaPath: "../../outside.wav"))
        XCTAssertThrowsError(try ShowProjectPackage.resolve(show, documentURL: dir.appendingPathComponent("project.scshow")))
    }
}
