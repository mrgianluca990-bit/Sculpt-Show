import Foundation

/// Silent, single-layer video. Audio is deliberately not part of this transport.
public struct CueVideo: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var duration: Double
    public var scale: Double
    public init(sourcePath: String, duration: Double, scale: Double = 1) {
        self.sourcePath = sourcePath
        self.duration = duration.isFinite ? min(86400, max(0, duration)) : 0
        self.scale = scale.isFinite ? min(1, max(0.1, scale)) : 1
    }
    public var isValid: Bool { !sourcePath.isEmpty && duration.isFinite && duration > 0 && duration <= 86400 && scale.isFinite && (0.1...1).contains(scale) }
    public static func opacity(elapsed: Double, duration: Double, fadeIn: Double, fadeOut: Double) -> Double {
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let incoming = fadeIn > 0 ? min(1, elapsed / fadeIn) : 1
        let outgoing = fadeOut > 0 ? min(1, max(0, duration - elapsed) / fadeOut) : 1
        return max(0, min(incoming, outgoing))
    }
}
