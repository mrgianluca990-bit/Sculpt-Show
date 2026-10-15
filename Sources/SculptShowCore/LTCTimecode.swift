import Foundation

/// SMPTE LTC addresses. `29.97 DF` uses an integer nominal 30-frame
/// label space with two skipped labels at every minute except each tenth.
public enum LTCFrameRate: Int, CaseIterable, Codable, Sendable {
    case fps24 = 0
    case fps25 = 1
    case fps2997DF = 2
    case fps30 = 3

    public var nominal: Int { self == .fps24 ? 24 : self == .fps25 ? 25 : 30 }
    public var actual: Double { self == .fps2997DF ? 30_000.0 / 1001.0 : Double(nominal) }
    public var label: String {
        switch self {
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps2997DF: return "29.97 DF"
        case .fps30: return "30 fps"
        }
    }
    public init(fps: Int, drop: Bool) {
        self = fps == 24 ? .fps24 : fps == 25 ? .fps25 : drop ? .fps2997DF : .fps30
    }
}

public struct LTCTimecode: Equatable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var rate: LTCFrameRate

    public init?(text: String, rate: LTCFrameRate) {
        let v = text.replacingOccurrences(of: ";", with: ":")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard v.count == 4, v.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let h = Int(v[0]), let m = Int(v[1]),
              let s = Int(v[2]), let f = Int(v[3]),
              (0..<24).contains(h), (0..<60).contains(m),
              (0..<60).contains(s), (0..<rate.nominal).contains(f),
              !(rate == .fps2997DF && m % 10 != 0 && s == 0 && f < 2)
        else { return nil }
        hours = h; minutes = m; seconds = s; frames = f; self.rate = rate
    }

    public var absoluteFrames: Int64 {
        let label = Int64(((hours*60 + minutes)*60 + seconds)*rate.nominal + frames)
        if rate != .fps2997DF { return label }
        let totalMinutes = hours * 60 + minutes
        return label - Int64(2*(totalMinutes - totalMinutes/10))
    }

    public static func at(frameNumber: Int64, rate: LTCFrameRate) -> LTCTimecode {
        let daily: Int64 = rate == .fps2997DF ? 2_589_408 : Int64(rate.nominal * 86_400)
        let frame = ((frameNumber % daily) + daily) % daily
        let label: Int64
        if rate == .fps2997DF {
            let ten = frame / 17_982
            let within = frame % 17_982
            label = frame + ten * 18 + (within >= 2 ? 2*((within-2)/1798) : 0)
        } else { label = frame }
        let f = Int(label % Int64(rate.nominal))
        let sec = Int(label / Int64(rate.nominal))
        return LTCTimecode(uncheckedHours: (sec/3600)%24, minutes:(sec/60)%60,
                            seconds: sec%60, frames: f, rate: rate)
    }

    public func adding(seconds: Double) -> LTCTimecode {
        guard seconds.isFinite else { return self }
        return Self.at(frameNumber: absoluteFrames + Int64(floor(seconds*rate.actual)), rate: rate)
    }

    public var display: String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds,
               rate == .fps2997DF ? ";" : ":", frames)
    }

    private init(uncheckedHours h: Int, minutes m: Int, seconds s: Int,
                 frames f: Int, rate: LTCFrameRate) {
        hours=h; minutes=m; seconds=s; frames=f; self.rate=rate
    }
}


/// Signed, cue-local LTC offset in SMPTE fields. The trim is a *duration*,
/// not an absolute SMPTE address, so 29.97 DF does not skip 00/01 labels here.
/// A negative trim wraps naturally at the 24-hour SMPTE boundary.
public struct LTCFrameTrim: Equatable, Sendable {
    public let frames: Int64
    public let text: String

    /// Zero has a negative default *presentation*, including legacy +00 trims.
    /// Sign never changes timing at exactly zero.
    public static let negativeZero = "-00:00:00:00"

    /// Converts a signed frame delta to an editable SMPTE duration.
    /// Rounds whole seconds exactly as init(text:rate:) does at 29.97 DF.
    /// Used for one-frame LTC nudge without changing cue audio position.
    public static func address(frames: Int64, rate: LTCFrameRate) -> String {
        let target = min(frames == Int64.min ? Int64.max : abs(frames),
                         Int64((86_399.0 * rate.actual).rounded()) + Int64(rate.nominal - 1))
        var lo = 0
        var hi = 86_399
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let whole = Int64((Double(mid) * rate.actual).rounded())
            if whole <= target { lo = mid } else { hi = mid - 1 }
        }
        let second = lo
        let whole = Int64((Double(second) * rate.actual).rounded())
        let f = min(rate.nominal - 1, max(0, Int(target - whole)))
        return String(format: "%@%02d:%02d:%02d:%02d",
                      frames > 0 ? "+" : "-", second / 3600,
                      (second / 60) % 60, second % 60, f)
    }

    public init?(text: String, rate: LTCFrameRate) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sign: Int64 = raw.first == "-" ? -1 : 1
        let body = raw.first == "-" || raw.first == "+" ? String(raw.dropFirst()) : raw
        let components = body.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let h = Int(components[0]), let m = Int(components[1]),
              let s = Int(components[2]), let f = Int(components[3]),
              (0..<24).contains(h), (0..<60).contains(m),
              (0..<60).contains(s), (0..<rate.nominal).contains(f) else { return nil }
        let whole = Int64(h * 3600 + m * 60 + s)
        // In DF use true 30000/1001 cadence, not nominal 30 seconds.
        frames = sign * (Int64((Double(whole) * rate.actual).rounded()) + Int64(f))
        self.text = String(format: "%@%02d:%02d:%02d:%02d", sign < 0 ? "-" : "+", h, m, s, f)
    }
}
