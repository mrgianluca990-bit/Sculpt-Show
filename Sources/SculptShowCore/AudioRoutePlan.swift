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

    public static func label(firstOutput: Int, sourceChannels: Int) -> String {
        sourceChannels == 1 ? "OUT \(firstOutput)" : "OUT \(firstOutput)/\(firstOutput + 1)"
    }
}
