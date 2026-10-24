import Foundation

/// Framing shared by still images and the visual output layers.
public enum VideoFraming: String, Codable, CaseIterable, Sendable {
    case fit, fill, stretch
    public var label: String {
        switch self { case .fit: return "Keep proportions"; case .fill: return "Crop"; case .stretch: return "Stretch" }
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
    public var offsetX: Double? = nil
    public var offsetY: Double? = nil
    public var widthScale: Double? = nil
    public var heightScale: Double? = nil
    public var lockAspectRatio: Bool? = nil
    public var scale: Double
    public init(sourcePath: String, duration: Double, scale: Double = 1) {
        self.sourcePath = sourcePath
        self.duration = duration.isFinite ? min(86400, max(0, duration)) : 0
        self.scale = scale.isFinite ? min(4, max(0.1, scale)) : 1
    }
    public var keepsAspectRatio: Bool { lockAspectRatio ?? (framing != .stretch) }
    public var isValid: Bool {
        !sourcePath.isEmpty && duration.isFinite && duration > 0 && duration <= 86400 && scale.isFinite && (0.1...4).contains(scale) &&
        [offsetX ?? 0, offsetY ?? 0].allSatisfy { $0.isFinite && (-2...2).contains($0) } &&
        [widthScale ?? 1, heightScale ?? 1].allSatisfy { $0.isFinite && (0.1...4).contains($0) }
    }
    public func viewportFrame(in canvas: CGRect) -> CGRect {
        let width = canvas.width * scale * (widthScale ?? 1), height = canvas.height * scale * (heightScale ?? 1)
        return CGRect(x: canvas.midX - width / 2 + (offsetX ?? 0) * canvas.width,
                      y: canvas.midY - height / 2 + (offsetY ?? 0) * canvas.height, width: width, height: height)
    }
    public func contentFrame(source: CGSize, in canvas: CGRect) -> CGRect {
        let base = (framing ?? .fit).frame(source: source, in: canvas)
        // Crop changes the mask, never the source aspect ratio.
        let sx = scale * (framing == .fill ? 1 : (widthScale ?? 1))
        let sy = scale * (framing == .fill ? 1 : (heightScale ?? 1))
        return CGRect(x: canvas.midX + (base.minX - canvas.midX) * sx + (offsetX ?? 0) * canvas.width,
                      y: canvas.midY + (base.minY - canvas.midY) * sy + (offsetY ?? 0) * canvas.height,
                      width: base.width * sx, height: base.height * sy)
    }
    public static func opacity(elapsed: Double, duration: Double, fadeIn: Double, fadeOut: Double) -> Double {
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let incoming = fadeIn > 0 ? min(1, elapsed / fadeIn) : 1
        let outgoing = fadeOut > 0 ? min(1, max(0, duration - elapsed) / fadeOut) : 1
        return max(0, min(incoming, outgoing))
    }
}

public enum VideoCompositionPolicy { public static let maximumCues = 8 }

public enum VideoSyncPolicy {
    public static func error(video: Double, audio: Double, duration: Double, looping: Bool) -> Double {
        var delta = audio - video
        if looping && duration > 0 {
            delta = delta.truncatingRemainder(dividingBy: duration)
            if delta > duration / 2 { delta -= duration }
            if delta < -duration / 2 { delta += duration }
        }
        return delta
    }
    public static func rate(for error: Double) -> Float {
        abs(error) < 0.035 ? 1 : Float(1 + min(0.02, max(-0.02, error * 0.1)))
    }
}
