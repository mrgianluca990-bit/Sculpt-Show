import SwiftUI
import AppKit

/// Sculpt CH/BUS finish. Static colors only: no textures, filters, clocks or
/// graphics resources are created by playback updates. Geometry stays at call sites.
enum SculptTheme {
    static let base = Color(red: 0.025, green: 0.043, blue: 0.052)
    static let panel = Color(red: 0.043, green: 0.067, blue: 0.078)
    static let raised = Color(red: 0.074, green: 0.103, blue: 0.116)
    static let stroke = Color(red: 0.22, green: 0.29, blue: 0.32)
    static let gold = Color(red: 0.98, green: 0.68, blue: 0.34)
    static let green = Color(red: 0.34, green: 0.81, blue: 0.53)
    static let soft = Color(red: 0.68, green: 0.75, blue: 0.77)
    static let text = Color(red: 0.94, green: 0.94, blue: 0.90)
    static let accent = Color(red: 0.28, green: 0.80, blue: 0.80)
    static let danger = Color(red: 0.95, green: 0.29, blue: 0.28)
    static let warning = Color(red: 1.0, green: 0.76, blue: 0.29)
    static let selection = Color(red: 0.065, green: 0.20, blue: 0.22)
    static let nsText = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.90, alpha: 1)
    static let nsField = NSColor(srgbRed: 0.035, green: 0.058, blue: 0.068, alpha: 1)

    // Reuse the existing system fonts and sizes; no new font loading or metrics.
    static let separator = stroke
    static let meterGreen = green
    static let meterAmber = warning
    static let meterClip = danger
}

/// Colors and accents propagate through native controls and sheets. Native
/// focus rings, keyboard handling, accessibility and intrinsic sizes are retained.
struct SculptSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(SculptTheme.gold)
            .background(SculptTheme.panel)
    }
}

