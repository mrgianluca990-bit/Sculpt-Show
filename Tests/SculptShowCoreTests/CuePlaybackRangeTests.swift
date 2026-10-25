import XCTest
@testable import SculptShowCore

final class CuePlaybackRangeTests: XCTestCase {
    func testLegacyAndSourceTimelineRemainUnchanged() throws {
        var cue = Cue(name:"Range",durationSeconds:10)
        XCTAssertEqual(cue.timelineLength(audioEnds:[20]),10)
        cue.playbackRange = .init(start:2,end:7)
        XCTAssertEqual(cue.playbackStart,2); XCTAssertEqual(cue.timelineLength(audioEnds:[20]),7)
        XCTAssertEqual(cue.sourceTimelineLength(audioEnds:[20]),10)
        XCTAssertEqual(try JSONDecoder().decode(Cue.self,from:JSONEncoder().encode(cue)),cue)
    }
    func testRangeValidationAndEnvelopeReferenceChosenPoints() {
        for r in [CuePlaybackRange(start:-1,end:2),.init(start:2,end:2),.init(start:0,end:.infinity),.init(start:.nan,end:5)] { XCTAssertFalse(r.isValid) }
        var cue = Cue(name:"Fade",fadeOutSeconds:1,fadeInSeconds:2,durationSeconds:10)
        cue.playbackRange = .init(start:3,end:8)
        cue.automaticFadeInEnabled = true; cue.automaticFadeOutEnabled = true
        XCTAssertEqual(cue.playbackEnvelope(at:3,end:8),0)
        XCTAssertEqual(cue.playbackEnvelope(at:4,end:8),0.5)
        XCTAssertEqual(cue.playbackEnvelope(at:6,end:8),1)
        XCTAssertEqual(cue.playbackEnvelope(at:7.5,end:8),0.5)
        XCTAssertEqual(cue.playbackEnvelope(at:8,end:8),0)
    }
    func testAutomaticFadesAreIndependentAndOptIn() throws {
        var cue = Cue(name:"Optional",fadeOutSeconds:2,fadeInSeconds:2,durationSeconds:10)
        cue.playbackRange = .init(start:3,end:8)
        XCTAssertEqual(cue.playbackEnvelope(at:3,end:8),1)
        XCTAssertEqual(cue.playbackEnvelope(at:8,end:8),1)
        cue.automaticFadeInEnabled = true
        XCTAssertEqual(cue.playbackEnvelope(at:3,end:8),0)
        XCTAssertEqual(cue.playbackEnvelope(at:7,end:8),1)
        cue.automaticFadeOutEnabled = true; cue.automaticFadeInEnabled = false
        XCTAssertEqual(cue.playbackEnvelope(at:3,end:8),1)
        XCTAssertEqual(cue.playbackEnvelope(at:7,end:8),0.5)
        let decoded = try JSONDecoder().decode(Cue.self,from:JSONEncoder().encode(cue))
        XCTAssertEqual(decoded.automaticFadeInEnabled,false)
        XCTAssertEqual(decoded.automaticFadeOutEnabled,true)
        cue.playbackRange = nil
        XCTAssertEqual(cue.playbackEnvelope(at:9,end:10),0.5)
        // Manual Fade continues to use the stored duration even when automatic OUT is off.
        cue.automaticFadeOutEnabled = false
        XCTAssertEqual(cue.fadeOutSeconds,2)
    }
    func testPlannerCannotReturnOutsideSelectedRange() {
        var cue = Cue(name:"Markers",durationSeconds:10)
        let first = CueMarker(name:"IN",positionSeconds:1)
        var second = CueMarker(name:"OUT",positionSeconds:5)
        var rule = InteractionRule(); rule.action = .fire; rule.target = .itself
        second.rules = [rule]; cue.markers = [first,second]
        XCTAssertNotNil(NativeMarkerLoopPlanner.plan(for:cue))
        cue.playbackRange = .init(start:2,end:8); XCTAssertNil(NativeMarkerLoopPlanner.plan(for:cue))
        cue.playbackRange = .init(start:0,end:4); XCTAssertNil(NativeMarkerLoopPlanner.plan(for:cue))
        cue.playbackRange = .init(start:1,end:5); XCTAssertNotNil(NativeMarkerLoopPlanner.plan(for:cue))
    }
    func testPreflightRejectsInvalidRangeAndWarnsExcludedMarkers() {
        var show = Show(); var cue = Cue(name:"Range",durationSeconds:10)
        cue.playbackRange = .init(start:2,end:12)
        cue.markers = [CueMarker(name:"Before",positionSeconds:1)]
        show.cueLists[0].cues = [cue]
        let report = ShowPreflight.check(show,outputChannels:2,media:[:])
        XCTAssertTrue(report.issues.contains { $0.code == "cue-range" && $0.severity == .blocking })
        XCTAssertTrue(report.issues.contains { $0.code == "marker-outside-range" })
    }
    func testVideoFullDurationAndLegacyStemOffsetsArePreserved() {
        var cue = Cue(name:"Video",mediaPath:"track",durationSeconds:10)
        cue.video = CueVideo(sourcePath:"movie",duration:20)
        cue.elements[0].inSeconds = 4
        cue.playbackRange = .init(start:5,end:12)
        XCTAssertEqual(cue.timelineLength(audioEnds:[20]),12)
        XCTAssertEqual(cue.sourceTimelineLength(audioEnds:[20]),20)
        XCTAssertEqual(cue.elements[0].inSeconds,4)
        XCTAssertEqual(cue.alignedAudioElements[0].inSeconds,0)
    }
}
