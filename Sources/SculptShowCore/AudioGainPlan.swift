import Foundation

/// Preserve intentional positive gain; reject non-finite values before AVAudioMixerNode.
public enum AudioGainPlan {
    public static func linear(cue: Double, element: Double, fade: Float, trim: Float, muted: Bool) -> Float {
        guard !muted, cue.isFinite, element.isFinite, fade.isFinite, trim.isFinite else { return 0 }
        let product = cue * element * Double(fade) * Double(trim)
        guard product.isFinite, product > 0 else { return 0 }
        return Float(min(product, Double(Float.greatestFiniteMagnitude)))
    }
}
