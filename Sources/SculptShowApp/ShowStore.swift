import AppKit
import Foundation
import SculptShowCore
import UniformTypeIdentifiers

@MainActor
final class ShowStore: ObservableObject {
    @Published private(set) var show = Show()
    @Published private(set) var documentURL: URL?
    @Published private(set) var dirty = false
    @Published var selectedListID: UUID?
    @Published var cueSelection: [UUID: UUID] = [:]
    @Published var errorMessage: String?
    /// A manual GO advances the selected cue to the next enabled row in that list.
    @Published var advanceAfterGO = true

    init() {
        selectedListID = show.cueLists.first?.id
    }

    var selectedCue: Cue? {
        guard let listID = selectedListID,
              let cueID = cueSelection[listID] else { return nil }
        return show.cue(cueID)
    }

    func selectedCue(in listID: UUID) -> Cue? {
        guard let cueID = cueSelection[listID] else { return nil }
        return show.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == cueID })
    }

    func select(_ cueID: UUID, in listID: UUID) {
        selectedListID = listID
        cueSelection[listID] = cueID
    }

    @discardableResult
    func newShow() -> Bool {
        guard confirmDiscard() else { return false }
        show = Show()
        documentURL = nil
        dirty = false
        cueSelection = [:]
        selectedListID = show.cueLists.first?.id
        return true
    }

    func renameShow(_ text: String) {
        guard text != show.name else { return }
        var updated = show
        updated.name = text
        commit(updated)
    }

    func addList() {
        var updated = show
        let newID = updated.addList()
        commit(updated)
        selectedListID = newID
    }

    func removeList(_ id: UUID) {
        guard show.cueLists.count > 1 else { return }
        var updated = show
        updated.removeList(id)
        commit(updated)
        cueSelection.removeValue(forKey: id)
        selectedListID = updated.cueLists.first?.id
    }

    func renameList(_ id: UUID, to text: String) {
        var updated = show
        updated.renameList(id, to: text)
        commit(updated)
    }

    func importAudio(to listID: UUID) {
        let panel = NSOpenPanel()
        panel.message = "Choose one or more audio files to add as cues"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        addAudio(panel.urls, to: listID)
    }

    func addAudio(_ urls: [URL], to listID: UUID) {
        guard !urls.isEmpty else { return }
        var updated = show
        let newIDs = updated.addAudio(urls, to: listID)
        guard !newIDs.isEmpty else { return }
        commit(updated)
        cueSelection[listID] = newIDs[0]
        selectedListID = listID
    }

    func renameCue(_ id: UUID, in list: UUID, to name: String) {
        editCue(id, list: list) { $0.name = name }
    }

    func setGain(_ id: UUID, in list: UUID, to gain: Double) {
        editCue(id, list: list) { $0.gain = min(max(gain, 0), 1) }
    }

    func setFade(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.fadeOutSeconds = max(seconds, 0) }
    }

    func setPreWait(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.preWaitSeconds = min(max(seconds, 0), 600) }
    }

    func setFadeIn(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.fadeInSeconds = max(seconds, 0) }
    }

    func setLoop(_ id: UUID, in list: UUID, to enabled: Bool) {
        editCue(id, list: list) { $0.loop = enabled }
    }

    func setFollow(_ id: UUID, in list: UUID, to enabled: Bool) {
        editCue(id, list: list) { $0.followOnFinish = enabled }
    }

    func duplicateCue(_ cueID: UUID, in listID: UUID) {
        var updated = show
        guard let duplicateID = updated.duplicateCue(cueID, in: listID) else { return }
        commit(updated)
        select(duplicateID, in: listID)
    }

    func stopList(_ listID: UUID, using playback: PlaybackEngine) {
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        for cue in list.cues { playback.stop(cue.id) }
    }

    func fadeList(_ listID: UUID, using playback: PlaybackEngine) {
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        for cue in list.cues { playback.fadeOut(cue) }
    }

    func moveCue(_ cueID: UUID, in list: UUID, by offset: Int) {
        var updated = show
        updated.moveCue(cueID, in: list, by: offset)
        guard updated != show else { return }
        commit(updated)
    }

    func fireSelected(using playback: PlaybackEngine) {
        guard let selectedListID else { return }
        fireSelected(in: selectedListID, using: playback)
    }

    func fireSelected(in listID: UUID, using playback: PlaybackEngine) {
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = selectedCue(in: listID) ?? list.cues.first(where: { $0.enabled }),
              playback.play(cue) else { return }
        selectedListID = listID
        if advanceAfterGO, let next = show.followingCue(after: cue.id) {
            select(next.id, in: listID)
        } else {
            select(cue.id, in: listID)
        }
    }

    /// Called only for a naturally finished file, not Stop, Fade Out or Pause.
    func didFinishNaturally(_ cueID: UUID, using playback: PlaybackEngine) {
        guard let finished = show.cue(cueID), finished.followOnFinish,
              let next = show.followingCue(after: cueID) else { return }
        if playback.play(next), let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == next.id }) }) {
            select(next.id, in: list.id)
            if advanceAfterGO, let following = show.followingCue(after: next.id) {
                select(following.id, in: list.id)
            }
        }
    }

    func setEnabled(_ id: UUID, in list: UUID, to enabled: Bool) {
        editCue(id, list: list) { $0.enabled = enabled }
    }

    func removeCue(_ id: UUID, from list: UUID) {
        var updated = show
        updated.removeCue(id, from: list)
        commit(updated)
        if cueSelection[list] == id {
            cueSelection[list] = updated.cueLists.first(where: { $0.id == list })?.cues.first?.id
        }
    }

    func selectNext(in listID: UUID) {
        guard let list = show.cueLists.first(where: { $0.id == listID }), !list.cues.isEmpty else { return }
        let current = cueSelection[listID]
        let next = list.cues.firstIndex(where: { $0.id == current }).map { ($0 + 1) % list.cues.count } ?? 0
        // Navigation is cyclic, but skips disabled cues where possible.
        let candidates = (0..<list.cues.count).map { list.cues[(next + $0) % list.cues.count] }
        if let cue = candidates.first(where: { $0.enabled }) { select(cue.id, in: listID) }
    }

    func save() {
        guard let url = documentURL else { saveAs(); return }
        write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Sculpt Show"
        panel.nameFieldStringValue = "\(show.name).scshow"
        panel.message = "The show file stores file paths, not the media itself."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = url.pathExtension == "scshow" ? url : url.appendingPathExtension("scshow")
        write(to: destination)
    }

    @discardableResult
    func openShow() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Open Sculpt Show"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let next = try ShowCodec.decode(Data(contentsOf: url))
            guard confirmDiscard() else { return false }
            show = next
            documentURL = url
            cueSelection = [:]
            selectedListID = next.cueLists.first?.id
            for list in next.cueLists { cueSelection[list.id] = list.cues.first?.id }
            dirty = false
            return true
        } catch {
            errorMessage = "Unable to open show: \(error.localizedDescription)"
            return false
        }
    }

    private func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Save the current show before opening or creating another one."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func write(to url: URL) {
        do {
            try ShowCodec.encode(show).write(to: url, options: .atomic)
            documentURL = url
            dirty = false
        } catch {
            errorMessage = "Unable to save show: \(error.localizedDescription)"
        }
    }

    private func editCue(_ id: UUID, list: UUID, _ change: (inout Cue) -> Void) {
        var updated = show
        updated.updateCue(id, in: list, change)
        commit(updated)
    }

    private func commit(_ updated: Show) {
        show = updated
        dirty = true
    }
}
