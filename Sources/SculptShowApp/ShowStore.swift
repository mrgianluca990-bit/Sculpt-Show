import AppKit
import AVFAudio
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
    /// When PLAY LIST is active, map each list to its currently expected cue.
    @Published private(set) var playingLists: [UUID: UUID] = [:]
    private var pendingRuleTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRuleTargets: [UUID: Set<UUID>] = [:]
    private var eventGeneration = UUID()
    private var eventTimestamps: [Date] = []

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
        cancelPendingRules()
        playingLists.removeAll()
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
        playingLists.removeValue(forKey: id)
        selectedListID = updated.cueLists.first?.id
    }

    func renameList(_ id: UUID, to text: String) {
        var updated = show
        updated.renameList(id, to: text)
        commit(updated)
    }

    func importAudio(to listID: UUID) {
        let panel = NSOpenPanel()
        panel.message = "Import audio as new cue containers"
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
        // Newly imported audio is still inside a normal, independently timed cue.
        // Initial duration defaults to the media length where available.
        for (id, url) in zip(newIDs, urls.filter(\.isFileURL)) {
            let length = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 5
            updated.updateCue(id, in: listID) {
                $0.durationSeconds = max(0.1, length)
                $0.durationMode = .fixed
            }
        }
        commit(updated)
        cueSelection[listID] = newIDs[0]
        selectedListID = listID
    }

    func addEmptyCue(to listID: UUID) {
        var updated = show
        let after = cueSelection[listID]
        guard let newID = updated.addEmptyCue(to: listID, after: after) else { return }
        commit(updated)
        select(newID, in: listID)
    }

    func chooseMedia(for cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        attachAudio(to: cueID, in: listID, using: playback)
    }

    /// Audio is an element added to the cue container, not a cue type.
    func attachAudio(to cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        let panel = NSOpenPanel()
        panel.title = "Add Audio to Cue Container"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        playback.stop(cueID, notifyRules: false)
        editCue(cueID, list: listID) { cue in
            cue.elements.append(contentsOf: panel.urls.map(CueElement.audio))
        }
    }

    func attachAudioURLs(_ urls: [URL], to cueID: UUID, in listID: UUID,
                         using playback: PlaybackEngine) {
        guard !urls.isEmpty else { return }
        var updated = show
        guard updated.appendAudio(urls, to: cueID) else { return }
        playback.stop(cueID, notifyRules: false)
        commit(updated)
        select(cueID, in: listID)
    }

    func addTimecode(to cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        playback.stop(cueID, notifyRules: false)
        editCue(cueID, list: listID) { $0.elements.append(.timecode()) }
    }

    func removeElement(_ elementID: UUID, from cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        playback.stop(cueID, notifyRules: false)
        editCue(cueID, list: listID) { $0.elements.removeAll { $0.id == elementID } }
    }

    func setElementStart(_ elementID: UUID, in cueID: UUID, listID: UUID, to seconds: Double) {
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[index].startSeconds = max(0, seconds)
        }
    }

    func setElementTrim(_ elementID: UUID, in cueID: UUID, listID: UUID,
                        start: Double? = nil, end: Double? = nil, resetEnd: Bool = false) {
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            if let start { cue.elements[index].inSeconds = max(0, start) }
            if let end { cue.elements[index].outSeconds = max(0, end) }
            if resetEnd { cue.elements[index].outSeconds = nil }
        }
    }

    func setTimecode(_ elementID: UUID, in cueID: UUID, listID: UUID, to value: String) {
        let frameRate = show.cue(cueID)?.elements.first(where: { $0.id == elementID })?.frameRate ?? 25
        guard CueElement.isValidTimecode(value, frameRate: frameRate) else {
            errorMessage = "Use timecode HH:MM:SS:FF with frames below the selected FPS."
            return
        }
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[index].timecodeStart = value
        }
    }

    func setTimecodeFrameRate(_ elementID: UUID, in cueID: UUID, listID: UUID, to fps: Int) {
        guard [24, 25, 30].contains(fps),
              let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID }) else { return }
        guard CueElement.isValidTimecode(element.timecodeStart, frameRate: fps) else {
            errorMessage = "Current timecode frame exceeds the selected FPS. Change the timecode first."
            return
        }
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[index].frameRate = fps
        }
    }

    func clearMedia(for cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        playback.stop(cueID, notifyRules: false)
        editCue(cueID, list: listID) { $0.elements.removeAll { $0.kind == .audio } }
    }

    /// An explicit container duration is independent of the attached media.
    func setCueDuration(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) {
            $0.durationSeconds = min(max(0.1, seconds), 86400)
            $0.durationMode = .fixed
        }
    }

    func useSourceDuration(_ id: UUID, in list: UUID, enabled: Bool) {
        editCue(id, list: list) { $0.durationMode = enabled ? .mediaEnd : .fixed }
    }

    func setTrimIn(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.inPointSeconds = max(0, seconds) }
    }

    func setTrimOut(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.outPointSeconds = max(0, seconds) }
    }

    func resetTrim(_ id: UUID, in list: UUID) {
        editCue(id, list: list) { $0.inPointSeconds = 0; $0.outPointSeconds = nil }
    }

    func setEmptyDuration(_ id: UUID, in list: UUID, to seconds: Double) {
        setCueDuration(id, in: list, to: seconds)
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

    func stopAll(using playback: PlaybackEngine) {
        playingLists.removeAll()
        cancelPendingRules()
        playback.stopAll()
    }

    func stopList(_ listID: UUID, using playback: PlaybackEngine) {
        playingLists.removeValue(forKey: listID)
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        cancelPendingRules(targeting: Set(list.cues.map(\.id)))
        for cue in list.cues { playback.stop(cue.id, notifyRules: false) }
    }

    func fadeList(_ listID: UUID, using playback: PlaybackEngine) {
        playingLists.removeValue(forKey: listID)
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        for cue in list.cues { playback.fadeOut(cue) }
    }

    func moveCue(_ cueID: UUID, in list: UUID, by offset: Int) {
        var updated = show
        updated.moveCue(cueID, in: list, by: offset)
        guard updated != show else { return }
        commit(updated)
    }

    /// Drag-and-drop can reorder inside a list or move a cue between lists.
    /// The active cue is stopped before moving, to keep rules and PLAY LIST deterministic.
    @discardableResult
    func relocateCue(_ cueID: UUID, to listID: UUID, before targetID: UUID?,
                     using playback: PlaybackEngine) -> Bool {
        guard let origin = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }) else { return false }
        var updated = show
        guard updated.relocateCue(cueID, to: listID, before: targetID), updated != show else { return false }
        // Cancel pending rules targeting the moved cue and avoid orphaning a list playback sequence.
        cancelPendingRules(targeting: [cueID])
        playingLists.removeValue(forKey: origin.id)
        if origin.id != listID { playingLists.removeValue(forKey: listID) }
        playback.stop(cueID, notifyRules: false)
        commit(updated)
        if origin.id != listID && cueSelection[origin.id] == cueID {
            cueSelection[origin.id] = updated.cueLists.first(where: { $0.id == origin.id })?.cues.first?.id
        }
        select(cueID, in: listID)
        return true
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

    /// PLAY LIST starts from the selected cue (or first enabled cue) and continues on natural endings.
    func playList(_ listID: UUID, using playback: PlaybackEngine) {
        guard playingLists[listID] == nil else { return }
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = selectedCue(in: listID).flatMap({ $0.enabled ? $0 : nil })
                     ?? list.cues.first(where: { $0.enabled }) else { return }
        guard playback.play(cue) else { return }
        playingLists[listID] = cue.id
        select(cue.id, in: listID)
    }

    func didStopCue(_ cueID: UUID) {
        if let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }),
           playingLists[list.id] == cueID {
            playingLists.removeValue(forKey: list.id)
        }
    }

    /// Called only for a naturally finished file, not Stop, Fade Out or Pause.
    func didFinishNaturally(_ cueID: UUID, using playback: PlaybackEngine) {
        handleRuleEvent(.ending, source: cueID, using: playback)
        if let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }),
           playingLists[list.id] == cueID {
            if let next = show.followingCue(after: cueID), playback.play(next) {
                playingLists[list.id] = next.id
                select(next.id, in: list.id)
            } else {
                playingLists.removeValue(forKey: list.id)
            }
            return
        }
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
        if playingLists[list] == id { playingLists.removeValue(forKey: list) }
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
            cancelPendingRules()
            playingLists.removeAll()
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

    func rules(for scope: RuleScope) -> [InteractionRule] {
        switch scope {
        case .show: return show.rules
        case .cueList(let id): return show.cueLists.first(where: { $0.id == id })?.rules ?? []
        case .cue(let cueID, _): return show.cue(cueID)?.rules ?? []
        }
    }

    func ignoreParentRules(for scope: RuleScope) -> Bool {
        guard case .cue(let id, _) = scope else { return false }
        return show.cue(id)?.ignoreParentRules ?? false
    }

    func updateRules(_ rules: [InteractionRule], for scope: RuleScope, ignoreParent: Bool = false) {
        var updated = show
        switch scope {
        case .show:
            updated.rules = rules
        case .cueList(let id):
            guard let index = updated.cueLists.firstIndex(where: { $0.id == id }) else { return }
            updated.cueLists[index].rules = rules
        case .cue(let cueID, let listID):
            guard updated.cue(cueID) != nil else { return }
            updated.updateCue(cueID, in: listID) {
                $0.rules = rules
                $0.ignoreParentRules = ignoreParent
            }
        }
        guard updated != show else { return }
        commit(updated)
    }

    func handleRuleEvent(_ event: RuleEvent, source cueID: UUID, using playback: PlaybackEngine) {
        // Anti-runaway guard: a misconfigured chain cannot spawn unlimited events.
        let now = Date()
        eventTimestamps.removeAll { now.timeIntervalSince($0) > 1 }
        guard eventTimestamps.count < 64 else {
            errorMessage = "Rule safety limit reached (64 events/second). Check for cyclic rules."
            return
        }
        eventTimestamps.append(now)

        var states: [UUID: RuleCueState] = [:]
        for (id, snapshot) in playback.snapshots {
            switch snapshot.phase {
            case .waiting: states[id] = .waiting
            case .paused: states[id] = .paused
            case .playing, .fading: states[id] = .playing
            }
        }
        let commands = RulePlanner.commands(for: event, source: cueID, in: show, states: states)
        for command in commands {
            let key = UUID()
            let generation = eventGeneration
            let delay = command.rule.delaySeconds
            pendingRuleTargets[key] = Set(command.targets)
            pendingRuleTasks[key] = Task { @MainActor [weak self, weak playback] in
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                } else {
                    await Task.yield() // Do not mutate playback while inside its event callback.
                }
                guard let self, let playback, !Task.isCancelled,
                      self.eventGeneration == generation else { return }
                self.pendingRuleTasks.removeValue(forKey: key)
                self.pendingRuleTargets.removeValue(forKey: key)
                self.execute(command, using: playback)
            }
        }
    }

    private func execute(_ command: RuleCommand, using playback: PlaybackEngine) {
        for targetID in command.targets {
            guard let cue = show.cue(targetID) else { continue }
            switch command.rule.action {
            case .fire: _ = playback.play(cue, overrideFadeInSeconds: command.rule.fireFadeInSeconds)
            case .stop: playback.stop(targetID)
            case .pause: playback.pause(targetID)
            case .fade: playback.fadeOut(cue, overrideSeconds: command.rule.fadeSeconds)
            case .select:
                if let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == targetID }) }) {
                    select(targetID, in: list.id)
                }
            case .dim: playback.dim(targetID, by: command.rule.dimDecibels)
            case .undim: playback.restoreGain(targetID)
            }
        }
    }

    private func cancelPendingRules(targeting targets: Set<UUID>) {
        let matchingKeys = pendingRuleTargets.compactMap { key, pending in
            pending.isDisjoint(with: targets) ? nil : key
        }
        for key in matchingKeys {
            pendingRuleTasks[key]?.cancel()
            pendingRuleTasks.removeValue(forKey: key)
            pendingRuleTargets.removeValue(forKey: key)
        }
    }

    private func cancelPendingRules() {
        eventGeneration = UUID()
        for task in pendingRuleTasks.values { task.cancel() }
        pendingRuleTasks.removeAll()
        pendingRuleTargets.removeAll()
        eventTimestamps.removeAll()
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
