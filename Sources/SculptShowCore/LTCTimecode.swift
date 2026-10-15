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
