import AppKit
import Foundation

/// Attach the existing bundle icon to newly saved .scshow files, independent
/// of LaunchServices document-type icon caches. Never alters audio or contents.
@MainActor
enum ProjectDocumentIcon {
    static func apply(to file: URL) {
        guard file.isFileURL, file.pathExtension.lowercased() == "scshow",
              let resource = Bundle.main.url(forResource: "SculptShow", withExtension: "icns"),
              let icon = NSImage(contentsOf: resource) else { return }
        _ = NSWorkspace.shared.setIcon(icon, forFile: file.path, options: [])
    }
}
