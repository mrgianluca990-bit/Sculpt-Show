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
