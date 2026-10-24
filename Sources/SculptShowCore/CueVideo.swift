import Foundation

/// Framing shared by still images and the single visual output layer.
public enum VideoFraming: String, Codable, CaseIterable, Sendable {
    case fit, fill, stretch
    public var label: String {
        switch self { case .fit: return "Keep proportions"; case .fill: return "Fill / crop"; case .stretch: return "Stretch" }
    }
    public func frame(source: CGSize, in canvas: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return canvas }
        if self == .stretch { return canvas }
        let x = canvas.width / source.width, y = canvas.height / source.height
        let ratio = self == .fit ? min(x, y) : max(x, y)
        let width = source.width * ratio, height = source.height * ratio
        return CGRect(x: canvas.midX - width / 2, y: canvas.midY - height / 2, width: width, height: height)
    }
}

public struct CueVideo: Codable, Equatable, Sendable {
    public var isImage: Bool? = nil
    public var framing: VideoFraming? = nil
    public var sourcePath: String
    public var duration: Double
    public var audioPrepared: Bool? = nil
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
