import Foundation

/// Hardware-agnostic channel assignment; pure and testable on Linux.
/// One-based channel indices match the labels printed on audio interfaces.
public enum AudioRoutePlan {
    public struct Crosspoint: Equatable, Sendable {
        public let sourceChannel: Int // zero based, within a source file
        public let deviceChannel: Int // zero based, within selected device
    }

    /// A mono file uses one output, a stereo file uses two adjacent outputs.
    /// Never fold an invalid route onto outputs 1/2: fail before playback.
    public static func crosspoints(firstOutput: Int, sourceChannels: Int,
                                   deviceChannels: Int) -> [Crosspoint]? {
        guard (1...64).contains(deviceChannels), (1...64).contains(firstOutput),
              (1...2).contains(sourceChannels),
              firstOutput + sourceChannels - 1 <= deviceChannels else { return nil }
        return (0..<sourceChannels).map {
            Crosspoint(sourceChannel: $0, deviceChannel: firstOutput - 1 + $0)
        }
    }

    /// Ordered mono/stereo stems reuse the connected outputs in cyclic banks.
    /// Stereo always occupies an adjacent pair, starting a new bank if needed.
    public static func automaticOutputs(channelCounts: [Int], deviceChannels: Int) -> [Int] {
        let capacity = min(64, max(1, deviceChannels))
        var next = 1
        return channelCounts.map { width in
            let channels = min(2, max(1, width))
            if next + channels - 1 > capacity { next = 1 }
            let output = next
            next += channels
            return output
        }
    }

    public static func wrappedOutput(_ first: Int, sourceChannels: Int, deviceChannels: Int) -> Int {
        guard deviceChannels > 0, first > 0 else { return first }
        let output = (first - 1) % deviceChannels + 1
        return output + sourceChannels - 1 <= deviceChannels ? output : 1
    }

    public static func label(firstOutput: Int, sourceChannels: Int) -> String {
        sourceChannels == 1 ? "OUT \(firstOutput)" : "OUT \(firstOutput)/\(firstOutput + 1)"
    }
}
