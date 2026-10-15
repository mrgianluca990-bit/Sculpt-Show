import AppKit
import SculptShowCore
import UniformTypeIdentifiers

/// Local-only cue relocation using stable UUID identity; never serializes cue content in a drag.
enum CueDragDrop {
    private static let prefix = "SCULPT_SHOW_CUE:"
    static func provider(for cueID: UUID) -> NSItemProvider {
        NSItemProvider(object: (prefix + cueID.uuidString) as NSString)
    }

    @discardableResult
    static func accept(_ providers: [NSItemProvider], in listID: UUID, before targetID: UUID?,
                       store: ShowStore, playback: PlaybackEngine) -> Bool {
        guard let item = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) }) else { return false }
        _ = item.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { payload, _ in
            let string: String?
            if let data = payload as? Data { string = String(data: data, encoding: .utf8) }
            else if let str = payload as? String { string = str }
            else if let str = payload as? NSString { string = str as String }
            else { string = nil }
            guard let string, string.hasPrefix(prefix),
                  let cueID = UUID(uuidString: String(string.dropFirst(prefix.count))) else { return }
            DispatchQueue.main.async {
                _ = store.relocateCue(cueID, to: listID, before: targetID, using: playback)
            }
        }
        return true
    }
}
