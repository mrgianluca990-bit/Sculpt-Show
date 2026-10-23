import XCTest
@testable import SculptShowCore

final class BackupCheckTests: XCTestCase {
    func testCanonicalContentIgnoresPathsAndHardwareButPreservesMixAndRules() throws {
        var first = Show();var cue = Cue(name: "Music", mediaPath: "/main/music.wav")
        cue.triggers.oscAlias = "/sculpt/trigger/intro";first.cueLists[0].cues = [cue]
        let digests = [cue.audioElements[0].id: "same-bytes"]
        var second = first
        second.cueLists[0].cues[0].elements[0].sourcePath = "/backup/copy.wav"
        second.monitor.deviceUID = "another-device";second.monitor.leftOutput = 7;second.monitor.rightOutput = 8
        second.outputPatch.setProfile(.init(deviceUID: "backup", deviceName: "Backup", automatic: false, outputs: Array(repeating: 1, count: 64)))
        XCTAssertEqual(try BackupCheckReport.canonicalProject(first, digests: digests), try BackupCheckReport.canonicalProject(second, digests: digests))
        second.cueLists[0].cues[0].gain = 0.5
        XCTAssertNotEqual(try BackupCheckReport.canonicalProject(first, digests: digests), try BackupCheckReport.canonicalProject(second, digests: digests))
    }
    func testAudioAndTriggerChangesAreDetected() throws {
        var show=Show();let cue=Cue(name:"Music",mediaPath:"/a.wav");show.cueLists[0].cues=[cue]
        let old=try BackupCheckReport.canonicalProject(show,digests:[cue.audioElements[0].id:"old"])
        XCTAssertNotEqual(old,try BackupCheckReport.canonicalProject(show,digests:[cue.audioElements[0].id:"new"]))
        show.cueLists[0].cues[0].triggers.oscEnabled=false
        XCTAssertNotEqual(old,try BackupCheckReport.canonicalProject(show,digests:[cue.audioElements[0].id:"old"]))
    }
    func testReportsCompareSchemaDigestRateAndLocalPreflight() throws {
        let first=BackupCheckReport(showName:"Show",projectDigest:"a",mediaCount:7,sampleRate:48000,blockingIssues:[])
        XCTAssertEqual(first.differences(from:first),[])
        var second=first;second.projectDigest="b";second.sampleRate=44100;second.blockingIssues=["Missing route"]
        XCTAssertEqual(first.differences(from:second).count,3)
        second=first;second.version=2
        XCTAssertFalse(first.differences(from:second).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(BackupCheckReport.self,from:JSONEncoder().encode(first)),first)
    }
}
