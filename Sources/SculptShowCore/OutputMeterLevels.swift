import Foundation

/// Linear amplitude measured from the real, post-routing PCM bus.
/// The view is free to convert values to dBFS / meter heights.
public enum OutputMeterLevels {
    public struct Levels: Equatable, Sendable {
        public var peak: Float
        public var rms: Float
        public init(peak: Float, rms: Float) { self.peak = peak; self.rms = rms }
    }

    public static func measure(_ samples: [Float]) -> Levels {
        guard !samples.isEmpty else { return Levels(peak: 0, rms: 0) }
        var maximum: Float = 0
        var squares: Double = 0
        for sample in samples {
            let x = sample.isFinite ? Double(sample) : 0
            maximum = max(maximum, Float(abs(x)))
            squares += x * x
        }
        return Levels(peak: maximum, rms: Float(sqrt(squares / Double(samples.count))))
    }

    public static func dBFS(_ amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return -90 }
        return max(-90, min(12, 20 * log10(amplitude)))
    }

    public static func normalized(_ amplitude: Float, floor: Float = -60) -> Float {
        max(0, min(1, (dBFS(amplitude) - floor) / -floor))
    }
}
