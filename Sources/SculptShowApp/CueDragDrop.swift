import AppKit
import Foundation

/// Native macOS clipboard transport for an internal cue drag.
/// A tagged NSString works with NSItemProvider/SwiftUI .onDrop even when the app
/// has not installed a custom uniform type declaration.
enum CueDragDrop {
    private static let prefix = "sculpt-cue:"

    static func provider(for id: UUID) -> NSItemProvider {
        NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    static func decode(_ raw: String) -> UUID? {
        guard raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }
}
