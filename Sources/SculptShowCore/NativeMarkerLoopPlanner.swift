import Foundation

/// A marker loop that can be scheduled ahead of the UI event timer.
public struct NativeMarkerLoop: Equatable, Sendable {
    public let ruleID: UUID?
    public let conditionCueID: UUID?
    public let conditionState: RuleCueState
    public let triggerMarkerID: UUID?
    public let inSeconds: Double
    public let outSeconds: Double

    public init(triggerMarkerID: UUID?, inSeconds: Double, outSeconds: Double,
                conditionCueID: UUID? = nil, conditionState: RuleCueState = .playing, ruleID: UUID? = nil) {
        self.ruleID = ruleID
        self.conditionCueID = conditionCueID
        self.conditionState = conditionState
        self.triggerMarkerID = triggerMarkerID
        self.inSeconds = inSeconds
        self.outSeconds = outSeconds
    }
}

public enum NativeMarkerLoopPlanner {
    /// Only unambiguous zero-delay self-loop rules are rendered ahead of time.
    /// Other Rules keep the existing event engine for full compatibility.
    public static func plan(for cue: Cue) -> NativeMarkerLoop? {
        guard !cue.hasTimecode else { return nil }
        let markers = cue.sortedMarkers
        var matches: [NativeMarkerLoop] = []
        for (i, marker) in markers.enumerated() where i > 0 {
            // Actions aimed at other cues do not invalidate the audio loop.
            // Multiple returns remain ambiguous and retain the event engine.
            let rules = marker.rules.filter { $0.enabled && $0.action == .fire &&
                $0.excludeSource != true &&
                ($0.target == .itself || ($0.target == .specificCue && $0.targetID == cue.id)) }
            guard rules.count == 1, let rule = rules.first,
                  rule.action == .fire, rule.excludeSource != true,
                  (rule.target == .itself || (rule.target == .specificCue && rule.targetID == cue.id)),
                  rule.delaySeconds == 0 else { continue }
            let start: Double
            if let destinationID = rule.fireAtMarkerID {
                guard let destination = markers.first(where: { $0.id == destinationID }) else { continue }
                start = destination.positionSeconds
            } else {
                start = markers[i - 1].positionSeconds
            }
            let end = marker.positionSeconds
            guard end - start >= 0.4 && end - start <= 600 else { continue }
            matches.append(NativeMarkerLoop(triggerMarkerID: marker.id,
                                             inSeconds: start, outSeconds: end,
                                             conditionCueID: rule.conditionCueID, conditionState: rule.conditionState, ruleID: rule.id))
        }
        return matches.count == 1 ? matches[0] : nil
    }

}
