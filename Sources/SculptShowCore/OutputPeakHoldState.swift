import Foundation

/// Peak-hold state for the Cue-style physical-output mixer.
/// Stores sampled digital peak, not oversampled true peak.
/// Kept separately from the audio graph and .scshow document.
public struct OutputPeakHoldState: Equatable, Sendable {
    public private(set) var values: [Float]

    public init(channelCount: Int) {
        values = Array(repeating: 0, count: max(0, min(64, channelCount)))
    }

    public var channelCount: Int { values.count }

    public func peak(channel: Int) -> Float {
        let index = channel - 1
        guard index >= 0 && index < values.count else { return 0 }
        return values[index]
    }

    public func clipped(channel: Int) -> Bool { peak(channel: channel) >= 1 }

    /// Safely accept peak buffers with fewer/more channels than the previous
    /// device configuration; caller resets on hardware change.
    public mutating func observe(_ peaks: [Float]) {
        for index in 0..<min(values.count, peaks.count) {
            let value = peaks[index]
            if value.isFinite { values[index] = max(values[index], max(0, value)) }
        }
    }

    public mutating func reset() {
        values = Array(repeating: 0, count: values.count)
    }
}
