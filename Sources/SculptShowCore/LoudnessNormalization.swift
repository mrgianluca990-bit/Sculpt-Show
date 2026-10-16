import Foundation

/// Offline meter for mono/stereo PCM. BS.1770-style K weighting + EBU R128
/// absolute (-70 LUFS) and relative (-10 LU) gates, with 400 ms blocks and
/// 100 ms hops. Never used inside the realtime playout render callback.
public struct LoudnessMeter {
    private struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1: Double = 0, z2: Double = 0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        static func highPass(rate: Double) -> Biquad {
            let omega = 2 * Double.pi * 38.13547087602444 / rate
            let alpha = sin(omega) / (2 * 0.5003270373238773)
            let a0 = 1 + alpha
            return Biquad(b0: ((1 + cos(omega)) / 2) / a0,
                          b1: -(1 + cos(omega)) / a0,
                          b2: ((1 + cos(omega)) / 2) / a0,
                          a1: (-2 * cos(omega)) / a0,
                          a2: (1 - alpha) / a0)
        }
        static func shelf(rate: Double) -> Biquad {
            let gainDB = 3.99984385397
            let A = pow(10, gainDB / 40)
            let omega = 2 * Double.pi * 1681.974450955533 / rate
            let alpha = sin(omega) / (2 * 0.7071752369554196)
            let slope = 2 * sqrt(A) * alpha
            let c = cos(omega)
            let a0 = (A + 1) - (A - 1) * c + slope
            return Biquad(b0: (A * ((A + 1) + (A - 1) * c + slope)) / a0,
                          b1: (-2 * A * ((A - 1) + (A + 1) * c)) / a0,
                          b2: (A * ((A + 1) + (A - 1) * c - slope)) / a0,
                          a1: (2 * ((A - 1) - (A + 1) * c)) / a0,
                          a2: ((A + 1) - (A - 1) * c - slope) / a0)
        }
    }

    private var filters: [(Biquad, Biquad)]
    private let windowSamples: Int
    private let hopSamples: Int
    private var ring: [Double]
    private var rollingSum: Double = 0
    private var ringIndex = 0
    private var frames: Int64 = 0
    private var blockEnergies: [Double] = []
    private var maxSample: Double = 0
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        precondition(sampleRate >= 8000 && channels >= 1 && channels <= 2)
        self.channels = channels
        windowSamples = max(1, Int((sampleRate * 0.400).rounded()))
        hopSamples = max(1, Int((sampleRate * 0.100).rounded()))
        filters = (0..<channels).map { _ in (Biquad.shelf(rate: sampleRate), Biquad.highPass(rate: sampleRate)) }
        ring = Array(repeating: 0, count: windowSamples)
    }

    /// Float32 non-interleaved samples, one pointer per channel (AVAudioPCMBuffer compatible).
    public mutating func ingest(_ pcm: UnsafePointer<UnsafeMutablePointer<Float>>, frames count: Int) {
        guard count > 0 else { return }
        for frame in 0..<count {
            var weightedPower: Double = 0
            for ch in 0..<channels {
                let sample = Double(pcm[ch][frame])
                if !sample.isFinite { continue }
                maxSample = max(maxSample, abs(sample))
                let high = filters[ch].0.process(sample)
                let filtered = filters[ch].1.process(high)
                weightedPower += filtered * filtered
            }
            rollingSum += weightedPower - ring[ringIndex]
            ring[ringIndex] = weightedPower
            ringIndex = (ringIndex + 1) % windowSamples
            frames += 1
            if frames >= windowSamples && (frames - Int64(windowSamples)) % Int64(hopSamples) == 0 {
                blockEnergies.append(max(0, rollingSum) / Double(windowSamples))
            }
        }
    }

    public func measure() -> NormalizationMeasurement {
        let peakDB = maxSample > 0 ? 20 * log10(maxSample) : nil
        let gateEnergy = pow(10, (-70 + 0.691) / 10)
        let absolute = blockEnergies.filter { $0 >= gateEnergy }
        guard !absolute.isEmpty else {
            return NormalizationMeasurement(integratedLUFS: nil, samplePeakDBFS: peakDB,
                                            frames: frames, channels: channels)
        }
        let avg = absolute.reduce(0, +) / Double(absolute.count)
        let relativeGate = avg / 10  // -10 LU from absolute-gated ungated loudness
        let gated = absolute.filter { $0 >= relativeGate }
        let energy = gated.reduce(0, +) / Double(max(gated.count, 1))
        let lufs = -0.691 + 10 * log10(max(energy, 1e-300))
        return NormalizationMeasurement(integratedLUFS: lufs,
                                        samplePeakDBFS: peakDB, frames: frames, channels: channels)
    }
}

public struct NormalizationMeasurement: Sendable {
    public let integratedLUFS: Double?
    public let samplePeakDBFS: Double?
    public let frames: Int64
    public let channels: Int
    public init(integratedLUFS: Double?, samplePeakDBFS: Double?, frames: Int64, channels: Int) {
        self.integratedLUFS = integratedLUFS
        self.samplePeakDBFS = samplePeakDBFS
        self.frames = frames
        self.channels = channels
    }
}

public enum NormalizationTarget: String, CaseIterable, Sendable {
    case integratedLUFS = "LUFS-I"
    case samplePeak = "Peak dBFS"
}

public enum NormalizationError: Error, Equatable {
    case silence, invalidTarget
}

public enum NormalizationPlanner {
    /// Returns the offline gain to write into a copy, never into the original media.
    /// The safety ceiling checks sample peaks, NOT inter-sample true peaks.
    public static func gainDB(for measurement: NormalizationMeasurement, mode: NormalizationTarget,
                              target: Double, ceilingDBFS: Double? = -1) throws -> Double {
        guard target.isFinite, (-70...6).contains(target) else { throw NormalizationError.invalidTarget }
        let measured: Double?
        switch mode {
        case .integratedLUFS: measured = measurement.integratedLUFS
        case .samplePeak: measured = measurement.samplePeakDBFS
        }
        guard let measured, measured.isFinite else { throw NormalizationError.silence }
        var gain = min(48, max(-72, target - measured))
        if let ceilingDBFS, let peak = measurement.samplePeakDBFS, ceilingDBFS.isFinite {
            gain = min(gain, ceilingDBFS - peak)
        }
        return gain
    }
}
