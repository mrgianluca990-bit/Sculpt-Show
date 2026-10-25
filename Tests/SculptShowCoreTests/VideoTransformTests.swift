import XCTest
@testable import SculptShowCore

final class VideoTransformTests: XCTestCase {
    func testLegacyDefaultsAreCenteredAndKeepOriginalAspect() throws {
        let movie = try JSONDecoder().decode(CueVideo.self, from: Data(#"{"sourcePath":"movie.mp4","duration":2,"scale":1}"#.utf8))
        XCTAssertTrue(movie.keepsAspectRatio)
        XCTAssertEqual(movie.contentFrame(source: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 1920, height: 1080)), CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }
    func testZoomBeyond100AndTranslationAreAppliedToPixels() {
        var movie = CueVideo(sourcePath: "movie", duration: 2, scale: 2)
        movie.offsetX = 0.25; movie.offsetY = -0.25
        let frame = movie.contentFrame(source: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(frame, CGRect(x: -480, y: -810, width: 3840, height: 2160))
        XCTAssertTrue(movie.isValid)
        XCTAssertEqual(CueVideo(sourcePath: "movie", duration: 2, scale: 9).scale, 4)
    }
    func testIndependentWidthAndHeightDeformTheSource() {
        var movie = CueVideo(sourcePath: "movie", duration: 2)
        movie.widthScale = 2; movie.heightScale = 0.5; movie.lockAspectRatio = false
        let frame = movie.contentFrame(source: CGSize(width: 100, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frame, CGRect(x: -50, y: 25, width: 200, height: 50))
        XCTAssertFalse(movie.keepsAspectRatio)
    }
    func testUniformDimensionsKeepPortraitRatio() {
        var movie = CueVideo(sourcePath: "movie", duration: 2)
        movie.widthScale = 0.5; movie.heightScale = 0.5
        let frame = movie.contentFrame(source: CGSize(width: 1080, height: 1920), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(frame.width / frame.height, 1080.0 / 1920.0, accuracy: 0.000001)
        XCTAssertEqual(frame.midX, 960)
        XCTAssertEqual(frame.midY, 540)
    }
    func testTransformsRoundTripWithCueLoopAndSoundtrack() throws {
        var cue = Cue(name: "Movie", mediaPath: "soundtrack.wav", loop: true)
        cue.video = CueVideo(sourcePath: "movie.mp4", duration: 2, scale: 2.5)
        cue.video?.offsetX = -0.2; cue.video?.offsetY = 0.3
        cue.video?.widthScale = 1.8; cue.video?.heightScale = 0.7; cue.video?.lockAspectRatio = false
        cue.video?.framing = .fill; cue.video?.audioPrepared = true
        XCTAssertEqual(try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue)), cue)
    }
    func testInvalidTransformIsRejected() {
        var movie = CueVideo(sourcePath: "movie", duration: 2)
        movie.widthScale = 0; XCTAssertFalse(movie.isValid)
        movie.widthScale = 1; movie.heightScale = 5; XCTAssertFalse(movie.isValid)
        movie.heightScale = 1; movie.offsetX = .infinity; XCTAssertFalse(movie.isValid)
        movie.offsetX = 0; movie.offsetY = 3; XCTAssertFalse(movie.isValid)
        movie.offsetY = 0; movie.scale = .nan; XCTAssertFalse(movie.isValid)
    }
    func testLoopSyncTreatsBoundaryAsSmallDifference() {
        XCTAssertEqual(VideoSyncPolicy.error(video: 1.99, audio: 0.01, duration: 2, looping: true), 0.02, accuracy: 0.000001)
        XCTAssertEqual(VideoSyncPolicy.error(video: 0.01, audio: 1.99, duration: 2, looping: true), -0.02, accuracy: 0.000001)
        XCTAssertEqual(VideoSyncPolicy.error(video: 0.01, audio: 1.99, duration: 2, looping: false), 1.98, accuracy: 0.000001)
    }
    func testVideoRateCorrectionIsBoundedAndHasDeadband() {
        XCTAssertEqual(VideoSyncPolicy.rate(for: 0.02), 1)
        XCTAssertEqual(VideoSyncPolicy.rate(for: 1), 1.02, accuracy: 0.000001)
        XCTAssertEqual(VideoSyncPolicy.rate(for: -1), 0.98, accuracy: 0.000001)
    }
    func testCropViewportFollowsZoomAndPosition() {
        var movie = CueVideo(sourcePath: "movie", duration: 2, scale: 0.5)
        movie.framing = .fill; movie.offsetX = 0.2
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let viewport = movie.viewportFrame(in: canvas)
        let content = movie.contentFrame(source: CGSize(width: 1920, height: 1080), in: canvas)
        XCTAssertEqual(viewport, CGRect(x: 450, y: 250, width: 500, height: 500))
        XCTAssertEqual(content.height, viewport.height, accuracy: 0.001)
        XCTAssertGreaterThan(content.width, viewport.width)
        XCTAssertEqual(content.midX, viewport.midX, accuracy: 0.001)
    }

}
