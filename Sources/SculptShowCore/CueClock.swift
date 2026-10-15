import Foundation

/// Human-editable cue length. Unlike timecode, the last field is milliseconds.
/// A value of 24:00:00:000 is the maximum currently supported cue length.
public enum CueClock {
    public static let maximum: Double = 86_400

    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00:000" }
        let rounded = Int64((min(max(0, seconds), maximum) * 1_000).rounded())
        let h = rounded / 3_600_000
        let m = (rounded / 60_000) % 60
        let s = (rounded / 1_000) % 60
        let ms = rounded % 1_000
        return String(format: "%02lld:%02lld:%02lld:%03lld", h, m, s, ms)
    }

    public static func parse(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              pieces[0].count == 2, pieces[1].count == 2,
              pieces[2].count == 2, pieces[3].count == 3,
              pieces.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let h = Int(pieces[0]), let m = Int(pieces[1]),
              let s = Int(pieces[2]), let ms = Int(pieces[3]),
              (0...24).contains(h), (0..<60).contains(m),
              (0..<60).contains(s), (0..<1_000).contains(ms) else { return nil }
        guard h != 24 || (m == 0 && s == 0 && ms == 0) else { return nil }
        return Double(h * 3_600 + m * 60 + s) + Double(ms) / 1_000
    }
}

/// MIDI Time Code has FRAMES (not milliseconds) in its final field.
public struct MTCFrame: Equatable, Sendable {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let nominalFPS: Int
    public let dropFrame: Bool

    public var display: String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds,
               dropFrame ? ";" : ":", frames)
    }
}

/// Assemble MIDI Time Code quarter-frame messages F1 0n, 1n ... 7n.
/// A coherent timestamp is published only after all eight pieces arrive.
public struct MTCDecoder: Sendable {
    private var nibbles: [UInt8] = Array(repeating: 0, count: 8)
    private var mask: UInt8 = 0
    private var lastType: Int?

    public init() {}

    public mutating func reset() {
        mask = 0
        lastType = nil
    }

    public mutating func ingestQuarterFrame(_ data: UInt8) -> MTCFrame? {
        let type = Int((data >> 4) & 0x07)
        // Packet loss or out-of-order pieces invalidate a partial MTC frame.
        if let previous = lastType, (previous + 1) % 8 != type {
            mask = 0
        }
        nibbles[type] = data & 0x0F
        mask |= UInt8(1 << type)
        lastType = type
        guard mask == 0xFF, type == 7 else { return nil }
        mask = 0
        let ff = Int(nibbles[0] | ((nibbles[1] & 0x01) << 4))
        let ss = Int(nibbles[2] | ((nibbles[3] & 0x03) << 4))
        let mm = Int(nibbles[4] | ((nibbles[5] & 0x03) << 4))
        let hh = Int(nibbles[6] | ((nibbles[7] & 0x01) << 4))
        let rateCode = Int((nibbles[7] >> 1) & 0x03)
        let fps = [24, 25, 30, 30][rateCode]
        guard hh < 24, mm < 60, ss < 60, ff < fps else { return nil }
        return MTCFrame(hours: hh, minutes: mm, seconds: ss, frames: ff,
                        nominalFPS: fps, dropFrame: rateCode == 2)
    }
}
