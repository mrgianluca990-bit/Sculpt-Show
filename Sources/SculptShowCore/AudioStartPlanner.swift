import Foundation

/// Pure scheduling math for playback elements in a cue container.
/// Relative offsets are measured from ONE cue timeline, not a UI refresh callback.
public struct AudioStartInstruction: Equatable, Sendable {
    public let positionInFile: Double
    public let delayFromCueAnchor: Double

    public init(positionInFile: Double, delayFromCueAnchor: Double) {
        self.positionInFile = positionInFile
        self.delayFromCueAnchor = delayFromCueAnchor
    }
}

public enum AudioStartPlanner {
    /// `cuePosition` is the position being played/resumed/seeked in the cue.
    /// Returns nil once the element has passed its OUT point.
    public static func instruction(
        elementOffset: Double,
        sourceIn: Double,
        sourceOut: Double,
        cuePosition: Double
    ) -> AudioStartInstruction? {
        guard elementOffset.isFinite, sourceIn.isFinite, sourceOut.isFinite,
              cuePosition.isFinite, sourceOut > sourceIn, elementOffset >= 0,
              sourceIn >= 0 else { return nil }
        let local = max(0, cuePosition) - elementOffset
        guard local < sourceOut - sourceIn else { return nil }
        return AudioStartInstruction(
            positionInFile: sourceIn + max(local, 0),
            delayFromCueAnchor: max(0, -local)
        )
    }
}
