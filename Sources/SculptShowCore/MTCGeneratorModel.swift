import Foundation

/// MTC frame rate codes exactly as transmitted in the hour byte and QF type 7.
public enum MTCGeneratorRate: Int, CaseIterable, Codable, Sendable {
    case fps24 = 0
    case fps25 = 1
    case fps2997Drop = 2
    case fps30 = 3

    public var nominalFPS: Int { self == .fps24 ? 24 : self == .fps25 ? 25 : 30 }
    public var actualFPS: Double { self == .fps2997Drop ? 30_000.0 / 1001.0 : Double(nominalFPS) }
    public var label: String {
        switch self {
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps2997Drop: return "29.97 DF"
        case .fps30: return "30 fps"
        }
    }
}

/// Pure MIDI Time Code encoder. The CoreMIDI transmitter can be tested without
/// hardware or SwiftUI. Generator output uses real HH:MM:SS:FF, not milliseconds.
public enum MTCGeneratorModel {
    public static func frame(at rawSeconds: Double, rate: MTCGeneratorRate) -> MTCFrame {
        let seconds = rawSeconds.isFinite ? max(0, rawSeconds) : 0
        // Wrap at one 24-hour period, preventing Int overflow from huge input.
        let totalFrames = Int64((seconds.truncatingRemainder(dividingBy: 86_400) * rate.actualFPS).rounded(.down))
        var tcFrames = totalFrames
        if rate == .fps2997Drop {
            // SMPTE drop-frame numbering: 2 labels are skipped every minute
            // except every tenth minute. No audio/video frames are discarded.
            let tenMinuteBlocks = totalFrames / 17_982
            let withinBlock = totalFrames % 17_982
            tcFrames += 18 * tenMinuteBlocks + 2 * max(0, (withinBlock - 2) / 1_798)
        }
        let nominal = Int64(rate.nominalFPS)
        return MTCFrame(hours: Int((tcFrames / (nominal * 3_600)) % 24),
                        minutes: Int((tcFrames / (nominal * 60)) % 60),
                        seconds: Int((tcFrames / nominal) % 60),
                        frames: Int(tcFrames % nominal),
                        nominalFPS: rate.nominalFPS,
                        dropFrame: rate == .fps2997Drop)
    }

    public static func quarterFrameData(_ frame: MTCFrame, rate: MTCGeneratorRate, phase: Int) -> UInt8 {
        let pieces: [UInt8] = [
            UInt8(frame.frames & 0x0F), UInt8((frame.frames >> 4) & 0x01),
            UInt8(frame.seconds & 0x0F), UInt8((frame.seconds >> 4) & 0x03),
            UInt8(frame.minutes & 0x0F), UInt8((frame.minutes >> 4) & 0x03),
            UInt8(frame.hours & 0x0F), UInt8(((frame.hours >> 4) & 0x01) | (rate.rawValue << 1))
        ]
        let p = (phase % 8 + 8) % 8
        return UInt8(p << 4) | pieces[p]
    }

    public static func fullFrameLocate(_ frame: MTCFrame, rate: MTCGeneratorRate) -> [UInt8] {
        [0xF0, 0x7F, 0x7F, 0x01, 0x01,
         UInt8((rate.rawValue << 5) | frame.hours),
         UInt8(frame.minutes), UInt8(frame.seconds), UInt8(frame.frames), 0xF7]
    }

    public static func parsePosition(_ value: String, rate: MTCGeneratorRate) -> Double? {
        let normalized = value.replacingOccurrences(of: ";", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]), let f = Int(parts[3]),
              (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s),
              (0..<rate.nominalFPS).contains(f) else { return nil }
        let totalMinutes = h * 60 + m
        if rate == .fps2997Drop, m % 10 != 0, s == 0, f < 2 { return nil }
        let numberedFrames = (h * 3_600 + m * 60 + s) * rate.nominalFPS + f
        let skippedLabels = rate == .fps2997Drop ? 2 * (totalMinutes - totalMinutes / 10) : 0
        return Double(numberedFrames - skippedLabels) / rate.actualFPS
    }
}
