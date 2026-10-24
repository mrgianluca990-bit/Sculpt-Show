import Foundation

/// Output controls are live-only and 1-based. Nothing is written to `.scshow`:
/// every device activation begins with all output channels audible.
public struct OutputMuteSoloState: Equatable, Sendable {
    public let channelCount: Int
    public private(set) var muted: Set<Int> = []
    public private(set) var soloed: Set<Int> = []

    public private(set) var allMuted = false
    public private(set) var excludedFromAll: Set<Int> = []
    public private(set) var soloExempt: Set<Int> = []

    public mutating func setAllMuted(_ muted: Bool, excluding: Set<Int>) { allMuted = muted; excludedFromAll = excluding.filter { isValid($0) } }
    public mutating func setSoloExempt(_ channels: Set<Int>) { soloExempt = channels.filter { isValid($0) } }

    public init(channelCount: Int) {
        self.channelCount = max(0, min(64, channelCount))
    }

    public func isValid(_ channel: Int) -> Bool { channel > 0 && channel <= channelCount }
    public func isMuted(_ channel: Int) -> Bool { muted.contains(channel) || (allMuted && !excludedFromAll.contains(channel)) }
    public func isSoloed(_ channel: Int) -> Bool { soloed.contains(channel) }
    public var anySolo: Bool { !soloed.isEmpty }
    public var soloDescription: String { soloed.sorted().map(String.init).joined(separator: ", ") }
    public var mutedCount: Int { muted.count }
    public var soloCount: Int { soloed.count }

    public func isAudible(_ channel: Int) -> Bool {
        isValid(channel) && !isMuted(channel) && (soloed.isEmpty || soloed.contains(channel) || soloExempt.contains(channel))
    }
    public func outputGain(_ channel: Int) -> Float { isAudible(channel) ? 1 : 0 }

    public mutating func toggleMute(_ channel: Int) {
        guard isValid(channel) else { return }
        if !muted.insert(channel).inserted { muted.remove(channel) }
    }
    public mutating func toggleSolo(_ channel: Int) {
        guard isValid(channel) else { return }
        if !soloed.insert(channel).inserted { soloed.remove(channel) }
    }
    public mutating func clear() { muted.removeAll(); soloed.removeAll(); allMuted = false }
}

public enum OutputMixerBanks {
    public static let bankSize = 16
    public static func banks(channelCount: Int) -> [Int] {
        let count = min(64, max(0, channelCount))
        guard count > 0 else { return [] }
        return [0] + Array(1...((count + bankSize - 1) / bankSize))
    }
    public static func channels(channelCount: Int, bank: Int) -> [Int] {
        let count = min(64, max(0, channelCount))
        guard count > 0 else { return [] }
        guard bank > 0 else { return Array(1...count) }
        let first = (bank - 1) * bankSize + 1
        guard first <= count else { return [] }
        return Array(first...min(count, first + bankSize - 1))
    }
    public static func title(channelCount: Int, bank: Int) -> String {
        guard bank > 0 else { return "All" }
        let first = (bank - 1) * bankSize + 1
        return "\(first)–\(min(channelCount, first + bankSize - 1))"
    }
}
