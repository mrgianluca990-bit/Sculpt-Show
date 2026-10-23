import Foundation

/// Offline comparison only. It does not certify clock alignment or switch audio.
public struct BackupCheckReport: Codable, Equatable, Sendable {
    public var version = 1
    public var showName: String
    public var projectDigest: String
    public var mediaCount: Int
    public var sampleRate: Int
    public var blockingIssues: [String]
    public init(showName: String, projectDigest: String, mediaCount: Int, sampleRate: Int, blockingIssues: [String]) {
        self.showName = showName; self.projectDigest = projectDigest; self.mediaCount = mediaCount
        self.sampleRate = sampleRate; self.blockingIssues = blockingIssues
    }
    public func differences(from other: Self) -> [String] {
        var issues: [String] = []
        if version != 1 || other.version != 1 { issues.append("Unsupported report version") }
        if projectDigest != other.projectDigest { issues.append("Project settings, cue identities or audio content differ") }
        if mediaCount != other.mediaCount { issues.append("Different number of audio stems") }
        if sampleRate != other.sampleRate { issues.append("Different project sample rates") }
        if !blockingIssues.isEmpty { issues.append("This Mac has blocking preflight issues") }
        if !other.blockingIssues.isEmpty { issues.append("The other Mac has blocking preflight issues") }
        return issues
    }
    public static func canonicalProject(_ show: Show, digests: [UUID: String]) throws -> Data {
        var copy = show
        // Hardware profiles are local to each machine and checked separately by preflight.
        copy.outputPatch.profiles = []
        copy.monitor.deviceUID = "hardware"; copy.monitor.leftOutput = 1; copy.monitor.rightOutput = 2
        for list in copy.cueLists {
            for cue in list.cues {
                copy.updateCue(cue.id, in: list.id) { item in
                    for i in item.elements.indices where item.elements[i].kind == .audio {
                        item.elements[i].sourcePath = "sha256:" + (digests[item.elements[i].id] ?? "MISSING")
                        item.elements[i].originalSourcePath = nil
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }
}
