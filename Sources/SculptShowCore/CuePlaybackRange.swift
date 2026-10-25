import Foundation

/// Cue-wide source timeline range. Legacy per-stem in/out fields remain untouched.
public struct CuePlaybackRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end <= 86400 && end - start >= 0.001 - 1e-9 }
}

extension Cue {
    public var playbackStart: Double { playbackRange?.start ?? 0 }
    public func sourceTimelineLength(audioEnds: [Double]) -> Double {
        if let video { return video.duration }
        if durationMode == .fixed { return max(0, min(86400, durationSeconds)) }
        return max(audioEnds.max() ?? 0, 0)
    }
    public func playbackEnvelope(at position: Double, end: Double) -> Double {
        let incoming = fadeInSeconds > 0 ? min(1, max(0, (position - playbackStart) / fadeInSeconds)) : 1
        // Existing cues retain their former natural-end behavior until a range is set.
        let outgoing = playbackRange != nil && fadeOutSeconds > 0 ? min(1, max(0, (end - position) / fadeOutSeconds)) : 1
        return min(incoming, outgoing)
    }
}
