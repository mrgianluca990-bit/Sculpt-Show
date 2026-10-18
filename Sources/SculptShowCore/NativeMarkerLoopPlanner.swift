import Foundation

/// A marker loop that can be scheduled ahead of the UI event timer.
public struct NativeMarkerLoop: Equatable, Sendable {
    public let triggerMarkerID: UUID?
    public let inSeconds: Double
    public let outSeconds: Double

    public init(triggerMarkerID: UUID?, inSeconds: Double, outSeconds: Double) {
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
            let rules = marker.rules.filter(\.enabled)
            guard rules.count == 1, let rule = rules.first,
                  rule.action == .fire,
                  (rule.target == .itself || (rule.target == .specificCue && rule.targetID == cue.id)),
                  rule.delaySeconds == 0, rule.conditionCueID == nil else { continue }
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
                                             inSeconds: start, outSeconds: end))
        }
        return matches.count == 1 ? matches[0] : nil
    }

}
