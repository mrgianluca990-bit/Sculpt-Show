import XCTest
@testable import SculptShowCore

final class CueVideoTests: XCTestCase {
    func testLegacyCueHasNoVideo() throws {
        let cue = Cue(name: "Audio")
        let round = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertNil(round.video)
    }
    func testVideoRoundTripAndTimeline() throws {
        var cue = Cue(name: "Film", durationSeconds: 5)
        cue.video = CueVideo(sourcePath: "/tmp/movie.mov", duration: 30, scale: 0.6)
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded, cue)
        XCTAssertEqual(decoded.timelineLength(audioEnds: []), 30)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertFalse(decoded.hasAudio)
    }
    func testEnvelopeAtBothBlackBoundaries() {
        XCTAssertEqual(CueVideo.opacity(elapsed: 0, duration: 10, fadeIn: 2, fadeOut: 2), 0)
        XCTAssertEqual(CueVideo.opacity(elapsed: 1, duration: 10, fadeIn: 2, fadeOut: 2), 0.5)
        XCTAssertEqual(CueVideo.opacity(elapsed: 5, duration: 10, fadeIn: 2, fadeOut: 2), 1)
        XCTAssertEqual(CueVideo.opacity(elapsed: 9, duration: 10, fadeIn: 2, fadeOut: 2), 0.5)
        XCTAssertEqual(CueVideo.opacity(elapsed: 10, duration: 10, fadeIn: 2, fadeOut: 2), 0)
        XCTAssertEqual(CueVideo.opacity(elapsed: -1, duration: 10, fadeIn: 0, fadeOut: 0), 0)
    }
    func testNoFadeAndOverlappingFadesStayBounded() {
        XCTAssertEqual(CueVideo.opacity(elapsed: 5, duration: 10, fadeIn: 0, fadeOut: 0), 1)
        XCTAssertEqual(CueVideo.opacity(elapsed: 1, duration: 2, fadeIn: 4, fadeOut: 4), 0.25)
        XCTAssertFalse(CueVideo(sourcePath: "", duration: 0).isValid)
        XCTAssertEqual(CueVideo(sourcePath: "m", duration: 1, scale: 4).scale, 4)
    }
    func testPortableVideoCopySaveRenameAndVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("movie.mov")
        try Data([1,2,3]).write(to: source)
        var show = Show(); var cue = Cue(name: "Video")
        cue.video = CueVideo(sourcePath: source.path, duration: 2)
        show.cueLists[0].cues = [cue]
        let saved = try ShowProjectPackage.create(show, requestedDocumentURL: root.appendingPathComponent("Portable.scshow"))
        let path = try XCTUnwrap(saved.runtimeShow.cue(cue.id)?.video?.sourcePath)
        XCTAssertTrue(path.contains("/Video Files/"))
        try FileManager.default.removeItem(at: source)
        let stored = try ShowCodec.decode(contentsOf: saved.documentURL)
        XCTAssertFalse(try XCTUnwrap(stored.cue(cue.id)?.video?.sourcePath).hasPrefix("/"))
        var renamed = saved.runtimeShow; renamed.cueLists[0].name = "Renamed"
        let again = try ShowProjectPackage.save(renamed, documentURL: saved.documentURL)
        XCTAssertEqual(again.runtimeShow.cue(cue.id)?.video?.sourcePath, path)
        let version = try ShowProjectPackage.saveVersion(again.runtimeShow, documentURL: saved.documentURL)
        XCTAssertEqual(version.runtimeShow.cue(cue.id)?.video?.sourcePath, path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([1,2,3]))
    }
    func testUnsafeVideoReferenceRejected() throws {
        var show = Show(); var cue = Cue(name: "Unsafe")
        cue.video = CueVideo(sourcePath: "../movie.mov", duration: 1)
        show.cueLists[0].cues = [cue]
        XCTAssertThrowsError(try ShowProjectPackage.resolve(show, documentURL: URL(fileURLWithPath: "/tmp/project/show.scshow")))
    }
    func testSoundtrackAssociationSurvivesRoundTrip() throws {
        var cue = Cue(name: "Movie", mediaPath: "/tmp/soundtrack.wav")
        cue.video = CueVideo(sourcePath: "/tmp/movie.mov", duration: 3)
        cue.video?.audioPrepared = true
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded, cue)
        XCTAssertTrue(decoded.hasAudio)
        XCTAssertEqual(decoded.video?.audioPrepared, true)
    }
    func testVideoMarkerReturnNeverLoopsAudioIndependently() {
        var cue = Cue(name: "Movie", mediaPath: "/tmp/soundtrack.wav")
        cue.video = CueVideo(sourcePath: "/tmp/movie.mov", duration: 3)
        cue.markers = [CueMarker(name: "IN", positionSeconds: 0), CueMarker(name: "OUT", positionSeconds: 1, rules: [InteractionRule(action: .fire, target: .itself)])]
        XCTAssertNil(NativeMarkerLoopPlanner.plan(for: cue))
    }

    func testLegacyVideoDefaultsToProportionalMovie() throws {
        let data = Data(#"{"sourcePath":"movie.mov","duration":3,"scale":1}"#.utf8)
        let movie = try JSONDecoder().decode(CueVideo.self, from: data)
        XCTAssertNil(movie.isImage)
        XCTAssertNil(movie.framing)
        XCTAssertNil(movie.audioPrepared)
        XCTAssertTrue(movie.isValid)
    }
    func testImageLoopAndFramingRoundTrip() throws {
        var cue = Cue(name: "Still", durationSeconds: 10)
        cue.video = CueVideo(sourcePath: "still.png", duration: 10, scale: 0.5)
        cue.video?.isImage = true; cue.video?.framing = .fill; cue.video?.audioPrepared = true
        cue.loop = true
        let decoded = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded, cue)
        XCTAssertEqual(decoded.timelineLength(audioEnds: []), 10)
        XCTAssertFalse(decoded.hasAudio)
    }
    func testFitCentersWithoutCropping() {
        let frame = VideoFraming.fit.frame(source: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(frame.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 218.75, accuracy: 0.001)
    }
    func testFillCropsSymmetricallyAndStretchUsesEntireCanvas() {
        let canvas = CGRect(x: 30, y: 20, width: 1000, height: 1000)
        let source = CGSize(width: 1920, height: 1080)
        let frame = VideoFraming.fill.frame(source: source, in: canvas)
        XCTAssertEqual(frame.height, 1000, accuracy: 0.001)
        XCTAssertEqual(frame.width, 1777.777777, accuracy: 0.001)
        XCTAssertEqual(frame.midX, canvas.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, canvas.midY, accuracy: 0.001)
        XCTAssertEqual(VideoFraming.stretch.frame(source: source, in: canvas), canvas)
    }
    func testPortraitAndInvalidSourceGeometry() {
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fit = VideoFraming.fit.frame(source: CGSize(width: 400, height: 800), in: canvas)
        XCTAssertEqual(fit.width, 540)
        XCTAssertEqual(fit.minX, 690)
        XCTAssertEqual(VideoFraming.fill.frame(source: .zero, in: canvas), canvas)
    }
    func testPortableImageKeepsFramingAndLoop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("still.png")
        try Data([1,2,3]).write(to: source)
        var show = Show(); var cue = Cue(name: "Still", durationSeconds: 10)
        cue.video = CueVideo(sourcePath: source.path, duration: 10)
        cue.video?.isImage = true; cue.video?.framing = .stretch; cue.loop = true
        show.cueLists[0].cues = [cue]
        let saved = try ShowProjectPackage.create(show, requestedDocumentURL: root.appendingPathComponent("Images.scshow"))
        try FileManager.default.removeItem(at: source)
        let reopened = try ShowProjectPackage.resolve(ShowCodec.decode(contentsOf: saved.documentURL), documentURL: saved.documentURL)
        XCTAssertEqual(reopened.cue(cue.id)?.video?.framing, .stretch)
        XCTAssertEqual(reopened.cue(cue.id)?.video?.isImage, true)
        XCTAssertEqual(reopened.cue(cue.id)?.loop, true)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: try XCTUnwrap(reopened.cue(cue.id)?.video?.sourcePath)))
    }

}
