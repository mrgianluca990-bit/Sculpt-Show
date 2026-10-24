import Foundation

/// UI consumption of audio boundaries. Each generation starts at GO/seek/resume.
/// A render boundary belongs to the whole cue, never to an individual stem.
public struct NativeMarkerEventCursor {
    private var token: UUID?
    private var count: UInt64 = 0
    public init() {}
    public mutating func consume(token: UUID, count: UInt64) -> Int {
        if self.token != token { self.token = token; self.count = 0 }
        let previous = self.count
        self.count = count
        // Match the event engine's safety limit after a stalled UI.
        return Int(min(64, count >= previous ? count - previous : 0))
    }
}
