import XCTest
@testable import SculptShowCore

final class ListFolderRenameTests: XCTestCase {
    private func project() throws -> (URL, ShowProjectPackage.Saved) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("stem.wav")
        try Data([1, 2, 3, 4]).write(to: source)
        let show = Show(name: "Show", cueLists: [CueList(name: "Old", cues: [Cue(name: "Cue", mediaPath: source.path)])])
        return (dir, try ShowProjectPackage.create(show, requestedDocumentURL: dir.appendingPathComponent("Show.scshow")))
    }
    func testRenameMovesDirectoryAndUpdatesSavedVersionsAndBridge() throws {
        let (dir, saved) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = try ShowProjectPackage.saveVersion(saved.runtimeShow, documentURL: saved.documentURL)
        let root = saved.documentURL.deletingLastPathComponent()
        let bridge = root.appendingPathComponent("bridge/edit")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        let session = bridge.appendingPathComponent("Cue.scdaw")
        try JSONSerialization.data(withJSONObject: ["path": saved.runtimeShow.cueLists[0].cues[0].mediaPath]).write(to: session)
        var renamed = saved.runtimeShow
        renamed.cueLists[0].name = "New"
        let result = try ShowProjectPackage.save(renamed, documentURL: saved.documentURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio Files/Old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.runtimeShow.cueLists[0].cues[0].mediaPath))
        XCTAssertTrue(result.runtimeShow.cueLists[0].cues[0].mediaPath.contains("/New/"))
        let history = try ShowProjectPackage.resolve(ShowCodec.decode(contentsOf: version.documentURL), documentURL: version.documentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.cueLists[0].cues[0].mediaPath))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String: String])
        XCTAssertEqual(json["path"], result.runtimeShow.cueLists[0].cues[0].mediaPath)
        _ = try ShowProjectPackage.save(result.runtimeShow, documentURL: result.documentURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Audio Files").path), ["New"])
    }
    func testFailedSaveRestoresFoldersAndDocuments() throws {
        let (dir, saved) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: saved.documentURL)
        var renamed = saved.runtimeShow
        renamed.cueLists[0].name = "New"
        renamed.cueLists[0].cues.append(Cue(name: "Missing", mediaPath: dir.appendingPathComponent("missing.wav").path))
        XCTAssertThrowsError(try ShowProjectPackage.save(renamed, documentURL: saved.documentURL))
        XCTAssertEqual(try Data(contentsOf: saved.documentURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.runtimeShow.cueLists[0].cues[0].mediaPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.documentURL.deletingLastPathComponent().appendingPathComponent("Audio Files/New").path))
    }
    func testUnrelatedDestinationFolderIsNeverOverwritten() throws {
        let (dir, saved) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = saved.documentURL.deletingLastPathComponent().appendingPathComponent("Audio Files/New")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let userFile = destination.appendingPathComponent("keep.wav")
        try Data([9]).write(to: userFile)
        var renamed = saved.runtimeShow
        renamed.cueLists[0].name = "New"
        XCTAssertThrowsError(try ShowProjectPackage.save(renamed, documentURL: saved.documentURL))
        XCTAssertEqual(try Data(contentsOf: userFile), Data([9]))
    }
}
