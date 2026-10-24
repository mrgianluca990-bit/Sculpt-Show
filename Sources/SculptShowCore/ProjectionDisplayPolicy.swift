import Foundation

/// Never reserve the only display, the primary display or SHOW's workspace display.
public enum ProjectionDisplayPolicy {
    public static func eligible(connected: [String], operatorDisplay: String?) -> [String] {
        guard connected.count > 1, let primary = connected.first, !primary.isEmpty else { return [] }
        return connected.filter { !$0.isEmpty && $0 != primary && $0 != operatorDisplay }
    }
    public static func target(connected: [String], operatorDisplay: String?, preferred: String) -> String? {
        let candidates = eligible(connected: connected, operatorDisplay: operatorDisplay)
        return preferred.isEmpty ? candidates.first : candidates.first(where: { $0 == preferred })
    }
}

public enum VideoOutputDestination: Equatable, Sendable {
    case localWindow
    case externalDisplay(String)
    case unavailable
}

extension ProjectionDisplayPolicy {
    /// The local player is always a bounded window, never a projection surface.
    public static func destination(connected: [String], operatorDisplay: String?, preferred: String,
                                   excluded: Set<String> = []) -> VideoOutputDestination {
        guard !connected.isEmpty else { return .unavailable }
        let candidates = eligible(connected: connected, operatorDisplay: operatorDisplay).filter { !excluded.contains($0) }
        guard let first = candidates.first else { return .localWindow }
        if preferred.isEmpty || candidates.count == 1 { return .externalDisplay(first) }
        if candidates.contains(preferred) { return .externalDisplay(preferred) }
        // Migrate old primary/operator selections to Automatic when a projector exists.
        if connected.contains(preferred) { return .externalDisplay(first) }
        return .unavailable
    }
}

public enum LocalVideoWindowGeometry {
    /// Bounds apply to the whole window (including its title bar).
    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let maxWidth = max(1, visible.width * 0.85), maxHeight = max(1, visible.height * 0.85)
        let width = min(maxWidth, max(min(320, maxWidth), frame.width))
        let height = min(maxHeight, max(min(200, maxHeight), frame.height))
        return CGRect(x: min(max(visible.minX, frame.minX), visible.maxX - width),
                      y: min(max(visible.minY, frame.minY), visible.maxY - height), width: width, height: height)
    }
}
