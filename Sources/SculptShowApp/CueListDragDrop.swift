import AppKit
import Foundation

/// A distinct drag type keeps list reordering separate from cue and file drops.
enum CueListDragDrop {
    static let type = "com.sculptshow.cue-list-id"
    static func provider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
    static func receive(_ providers: [NSItemProvider], perform: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in perform(id) }
        }
        return true
    }
}
