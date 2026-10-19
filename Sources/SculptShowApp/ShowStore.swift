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
    @Published private(set) var selectedCueID: UUID?
    @Published var errorMessage: String?
    /// A manual GO advances the selected cue to the next enabled row in that list.
    @Published var advanceAfterGO = true
    /// When PLAY LIST is active, map each list to its currently expected cue.
    private var playlistOrders: [UUID: PlaylistOrder] = [:]
    @Published private(set) var playingLists: [UUID: UUID] = [:]
    private var pendingRuleTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRuleTargets: [UUID: Set<UUID>] = [:]
    private var eventGeneration = UUID()
    private var eventTimestamps: [Date] = []
    private var suppressRuleEvents = false

    /// Reversible Show-document state. No audio bytes are deleted by Undo.
    /// Selection is recorded along with content so undoing a deleted cue or
    /// cue list restores a usable cursor position.
    private struct HistoryItem {
        let show: Show
        let selectedListID: UUID?
        let selectedCueID: UUID?
    }
    private var undoStack: [HistoryItem] = []
    private var redoStack: [HistoryItem] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private func snapshot() -> HistoryItem {
        HistoryItem(show: show, selectedListID: selectedListID, selectedCueID: selectedCueID)
    }

    private func syncHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        syncHistoryFlags()
    }

    private func restore(_ item: HistoryItem) {
        show = item.show
        if let id = item.selectedListID, show.cueLists.contains(where: { $0.id == id }) {
            selectedListID = id
        } else {
            selectedListID = show.cueLists.first?.id
        }
        if let id = item.selectedCueID,
           show.cueLists.first(where: { $0.id == selectedListID })?.cues.contains(where: { $0.id == id }) == true {
            selectedCueID = id
        } else {
            selectedCueID = show.cueLists.first(where: { $0.id == selectedListID })?.cues.first?.id
        }
        // Disk saves are not undone; reverting the show marks it as changed.
        dirty = true
    }

    /// Undo every document-model edit, including imported or normalized media
    /// references. Running playback cannot be atomically rewound in this model,
    /// so document Undo is intentionally blocked during live playout.
    func undoEdit(using playback: PlaybackEngine) {
        guard !isLoadingProject, !preparingSessionAudio, pendingAudioImports == 0,
              normalizingCueID == nil, normalizingListID == nil else { return }
        guard playback.snapshots.isEmpty else {
            errorMessage = "Stop playback before Undo: live audio cannot safely roll back."
            return
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        cancelPendingRules()
        playingLists.removeAll()
        restore(previous)
        syncHistoryFlags()
    }

    func redoEdit(using playback: PlaybackEngine) {
        guard !isLoadingProject, !preparingSessionAudio, pendingAudioImports == 0,
              normalizingCueID == nil, normalizingListID == nil else { return }
        guard playback.snapshots.isEmpty else {
            errorMessage = "Stop playback before Redo: live audio cannot safely roll back."
            return
        }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        cancelPendingRules()
        playingLists.removeAll()
        restore(next)
        syncHistoryFlags()
    }
    @Published private(set) var pendingAudioImports = 0
    /// Visible file-level progress for media analysis; not a synthetic timer.
    @Published private(set) var audioImportProgress = ""
    /// The previous Show stays visible until every existing stem has been scanned.
    @Published private(set) var isLoadingProject = false
    private var showOpenGeneration = UUID()

    @Published private(set) var preparingSessionAudio = false
    @Published private(set) var sessionAudioStatus = ""
    private var lastAudioPreparationKey: String?
    private var preparationRequested = false
    private var appliedDAWReceipts: [UUID: URL] = [:]

    private func preparationKey(_ model: Show) -> String {
        let paths = model.cueLists.flatMap { $0.cues.flatMap { $0.audioElements.map { "\($0.id):\($0.sourcePath):\($0.originalSourcePath ?? "")" } } }.sorted()
        let loops = model.cueLists.flatMap(\.cues).filter {
            NativeMarkerLoopPlanner.plan(for: $0)?.conditionCueID != nil
        }.map { $0.id.uuidString }.sorted()
        return "\(model.sampleRate)|" + paths.joined(separator: "|") + loops.joined(separator: "|")
    }

    func changeSessionSampleRate(_ rate: Int, using playback: PlaybackEngine) {
        guard Show.supportedSampleRates.contains(rate), playback.snapshots.isEmpty,
              !preparingSessionAudio, !isLoadingProject, pendingAudioImports == 0 else {
            errorMessage = "Stop all cues and finish media preparation before changing sample rate."
            return
        }
        guard show.sampleRate != rate else { return }
        var updated = show
        updated.sampleRate = rate
        playback.projectAudioReady = false
        commit(updated)
        requestSessionAudioPreparation(using: playback)
    }

    func requestSessionAudioPreparation(using playback: PlaybackEngine, force: Bool = false) {
        playback.knowProject(show)
        let key = preparationKey(show)
        guard force || key != lastAudioPreparationKey else { return }
        if preparingSessionAudio { preparationRequested = true; playback.projectAudioReady = false; return }
        guard !isLoadingProject, !preparingSessionAudio, pendingAudioImports == 0,
              normalizingCueID == nil, normalizingListID == nil else { return }
        lastAudioPreparationKey = key
        preparingSessionAudio = true
        playback.projectAudioReady = false
        sessionAudioStatus = "Checking project sample rate…"
        let generation = showOpenGeneration
        Task { @MainActor in
            defer {
                preparingSessionAudio = false
                if preparationRequested {
                    preparationRequested = false
                    requestSessionAudioPreparation(using: playback)
                }
            }
            do {
                guard await playback.configureProjectSampleRate(show.sampleRate) else {
                    throw SessionAudioPreparation.Failure.invalid(playback.errorMessage ?? "Audio device is not ready")
                }
                let inspected = show
                let needsConversion = try await Task.detached(priority: .userInitiated) {
                    try inspected.cueLists.flatMap(\.cues).flatMap(\.audioElements).contains {
                        let file = try AVAudioFile(forReading: URL(fileURLWithPath: $0.sourcePath))
                        return abs(file.processingFormat.sampleRate - Double(inspected.sampleRate)) > 0.5
                    }
                }.value
                if needsConversion {
                    if documentURL == nil || documentURL.map({ !ShowProjectPackage.isPackaged($0) }) == true { saveAs() }
                    guard let documentURL, ShowProjectPackage.isPackaged(documentURL) else {
                        throw SessionAudioPreparation.Failure.invalid("Save a portable Show project to create converted copies. GO remains blocked.")
                    }
                    let before = show
                    let root = documentURL.deletingLastPathComponent()
                    sessionAudioStatus = "Converting copies to \(show.sampleRate) Hz…"
                    let converted = try await Task.detached(priority: .userInitiated) {
                        try SessionAudioPreparation.preparing(before, projectRoot: root)
                    }.value
                    guard generation == showOpenGeneration, preparationKey(show) == preparationKey(before) else {
                        preparationRequested = true
                        return
                    }
                    if converted != show {
                        // Media preparation belongs to the import/rate-change
                        // operation, not an extra user-visible Undo action.
                        var merged = show
                        for list in converted.cueLists {
                            for cue in list.cues {
                                merged.updateCue(cue.id, in: list.id) { current in
                                    for index in current.elements.indices {
                                        if let prepared = cue.elements.first(where: { $0.id == current.elements[index].id }) {
                                            current.elements[index].sourcePath = prepared.sourcePath
                                            current.elements[index].originalSourcePath = prepared.originalSourcePath
                                        }
                                    }
                                }
                            }
                        }
                        show = merged
                        dirty = true
                        refreshDAWReceipts(from: before, to: merged)
                    }
                    let paths = show.cueLists.flatMap(\.cues).flatMap { $0.audioElements.map(\.sourcePath) }
                    let unreadable = await ShowWaveformCache.shared.prepare(paths: paths)
                    guard unreadable.isEmpty else { throw SessionAudioPreparation.Failure.invalid("Converted media waveform verification failed") }
                }
                sessionAudioStatus = "Preparing conditional-loop audio…"
                let preparedModel = show
                try await playback.prepareConditionalAudio(preparedModel)
                guard generation == showOpenGeneration, preparationKey(show) == preparationKey(preparedModel) else {
                    preparationRequested = true
                    return
                }
                lastAudioPreparationKey = preparationKey(show)
                playback.projectAudioReady = true
                sessionAudioStatus = "Ready · \(show.sampleRate) Hz · live SRC disabled"
            } catch {
                sessionAudioStatus = "Audio not ready · live SRC disabled"
                errorMessage = "Project audio preparation: " + error.localizedDescription
            }
        }
    }

    private func refreshDAWReceipts(from previous: Show, to prepared: Show) {
        for (id, url) in appliedDAWReceipts {
            guard let old = previous.cue(id), let new = prepared.cue(id),
                  let bytes = try? Data(contentsOf: url),
                  var record = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let snapshot = record["originCue"],
                  let snapshotData = try? JSONSerialization.data(withJSONObject: snapshot),
                  let cue = try? JSONDecoder().decode(Cue.self, from: snapshotData), cue == old else { continue }
            do {
                record["originCue"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(new))
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: url, options: .atomic)
            } catch { errorMessage = "Prepared audio, but could not update DAW receipt: " + error.localizedDescription }
        }
    }

    init() {
        selectedListID = show.cueLists.first?.id
    }

    var selectedCue: Cue? {
        guard let listID = selectedListID, let cueID = selectedCueID else { return nil }
        return show.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == cueID })
    }

    func selectedCue(in listID: UUID) -> Cue? {
        guard selectedListID == listID, let cueID = selectedCueID else { return nil }
        return show.cueLists.first(where: { $0.id == listID })?.cues.first(w…10478 tokens truncated…Keeps the audio timeline, cue start and output routing untouched.
    func nudgeTimecodeTrim(_ elementID: UUID, in cueID: UUID, listID: UUID,
                           by frames: Int64) {
        guard let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID }) else { return }
        let rate = LTCFrameRate(fps: element.frameRate, drop: element.timecodeDropFrame)
        guard let offset = LTCFrameTrim(text: element.ltcTrim, rate: rate) else { return }
        let shifted = offset.frames.addingReportingOverflow(frames)
        guard !shifted.overflow else { return }
        let newText = LTCFrameTrim.address(frames: shifted.partialValue, rate: rate)
        guard let validated = LTCFrameTrim(text: newText, rate: rate) else { return }
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].ltcTrim = validated.text
        }
    }

    func setTimecodeLevelTrim(_ elementID: UUID, in cueID: UUID, listID: UUID,
                              to value: Double, using playback: PlaybackEngine) {
        guard value.isFinite else { return }
        let db = min(12, max(-36, value))
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].ltcLevelTrimDB = db
        }
        playback.setLiveLTCLevel(for: cueID, trimDB: db)
    }

    func setTimecodeLTCFrameRate(_ elementID: UUID, in cueID: UUID,
                                 listID: UUID, to rate: LTCFrameRate) {
        guard let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID }),
              CueElement.isValidTimecode(element.timecodeStart,
                  frameRate: rate.nominal, dropFrame: rate == .fps2997DF),
              LTCFrameTrim(text: element.ltcTrim, rate: rate) != nil else {
            errorMessage = "Invalid SMPTE address for the selected rate (29.97 DF skips frames 00/01 at non-tenth minutes)."
            return
        }
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].frameRate = rate.nominal
            cue.elements[i].timecodeDropFrame = rate == .fps2997DF
        }
    }

    func setTimecodeOutput(_ elementID: UUID, in cueID: UUID, listID: UUID,
                           to output: Int?) {
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].ltcOutputChannel = output
        }
    }

    func setTimecodeMuted(_ elementID: UUID, in cueID: UUID, listID: UUID,
                          to muted: Bool) {
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].muted = muted
        }
    }

    func setTimecodeFrameRate(_ elementID: UUID, in cueID: UUID, listID: UUID, to fps: Int) {
        guard [24, 25, 30].contains(fps),
              let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID }) else { return }
        guard CueElement.isValidTimecode(element.timecodeStart, frameRate: fps,
                                          dropFrame: element.timecodeDropFrame && fps == 30) else {
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
            $0.durationSeconds = min(max(0, seconds), 86400)
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

    func setCueTint(_ id: UUID, in list: UUID, to tint: CueTint) {
        editCue(id, list: list) { $0.tint = tint }
    }

    func setGain(_ id: UUID, in list: UUID, to gain: Double) {
        editCue(id, list: list) { $0.gain = min(max(gain, 0), 1) }
    }

    /// Persist and update an individual element's level without restarting playback.
    func setElementGain(_ elementID: UUID, in cueID: UUID, listID: UUID,
                        to gain: Double, using playback: PlaybackEngine) {
        let safe = gain.isFinite ? min(max(gain, 0), 1) : 1
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID && $0.kind == .audio }) else { return }
            cue.elements[index].gain = safe
        }
        playback.setElementMix(elementID, for: cueID, gain: safe)
    }

    /// Repatch an individual stem without changing its transport, timeline or Rules.
    func setElementOutput(_ elementID: UUID, in cueID: UUID, listID: UUID,
                          to firstOutput: Int, using playback: PlaybackEngine) {
        let safe = min(max(firstOutput, 1), 64)
        guard let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID && $0.kind == .audio }),
              element.outputStartChannel != safe else { return }
        guard playback.updateLiveElementOutput(elementID, for: cueID,
                  firstOutput: safe, sourcePath: element.sourcePath) else { return }
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID && $0.kind == .audio }) else { return }
            cue.elements[index].outputStartChannel = safe
        }
    }

    /// Mute changes only the selected audio element; its transport stays aligned.
    func setElementMuted(_ elementID: UUID, in cueID: UUID, listID: UUID,
                         to muted: Bool, using playback: PlaybackEngine) {
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID && $0.kind == .audio }) else { return }
            cue.elements[index].muted = muted
        }
        playback.setElementMix(elementID, for: cueID, muted: muted)
    }

    func setFade(_ id: UUID, in list: UUID, to seconds: Double) {
        editCue(id, list: list) { $0.fadeOutSeconds = max(seconds, 0) }
    }
    /// One undoable edit for all cues in the selected list.
    /// New default is 5 seconds, but existing cues retain their own fade until changed.
    func setFadeOutForList(_ listID: UUID, to seconds: Double) {
        guard seconds.isFinite, (0...600).contains(seconds),
              let i = show.cueLists.firstIndex(where: { $0.id == listID }) else { return }
        var updated = show
        for c in updated.cueLists[i].cues.indices {
            updated.cueLists[i].cues[c].fadeOutSeconds = seconds
        }
        commit(updated)
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

    func moveList(_ id: UUID, before destination: UUID?) {
        guard !isLoadingProject else { return }
        var updated = show
        guard updated.moveList(id, before: destination) else { return }
        commit(updated)
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
        select(cueID, in: listID)
        return true
    }

    func fireSelected(using playback: PlaybackEngine) {
        guard let selectedListID else { return }
        fireSelected(in: selectedListID, using: playback)
    }

    func fireSelected(in listID: UUID, using playback: PlaybackEngine) {
        guard !isLoadingProject else { return }
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = selectedCue(in: listID) ?? list.cues.first(where: { $0.enabled }),
              playback.play(cue, restartPaused: true) else { return }
        selectedListID = listID
        if advanceAfterGO, let next = show.followingCue(after: cue.id) {
            select(next.id, in: listID)
        } else {
            select(cue.id, in: listID)
        }
    }

    /// PLAY LIST starts from the selected cue (or first enabled cue) and continues on natural endings.
    func setPlaylistOptions(_ id: UUID, random: Bool? = nil, repeatAll: Bool? = nil) {
        var updated = show
        guard let index = updated.cueLists.firstIndex(where: { $0.id == id }) else { return }
        if let random { updated.cueLists[index].randomOrder = random }
        if let repeatAll { updated.cueLists[index].repeatAll = repeatAll }
        playlistOrders.removeValue(forKey: id)
        commit(updated)
    }

    func didStartCue(_ cueID: UUID) {
        guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }),
              playingLists[list.id] != nil else { return }
        // A manually chosen song takes over the running playlist before other
        // songs are faded by its Starting rules.
        playingLists[list.id] = cueID
        playlistOrders[list.id, default: PlaylistOrder()].record(cueID)
    }

    func playList(_ listID: UUID, using playback: PlaybackEngine) {
        guard !isLoadingProject else { return }
        guard playingLists[listID] == nil else { return }
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        var order = PlaylistOrder()
        let chosen = list.randomOrder ? order.next(in: list, after: nil) :
            (selectedCue(in: listID).flatMap { $0.enabled ? $0.id : nil } ?? list.cues.first(where: { $0.enabled })?.id)
        guard let chosen, let cue = show.cue(chosen), playback.play(cue) else { return }
        order.record(chosen)
        playlistOrders[listID] = order
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
        guard !isLoadingProject else { return }
        handleRuleEvent(.ending, source: cueID, using: playback)
        if let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }),
           playingLists[list.id] == cueID {
            var order = playlistOrders[list.id] ?? PlaylistOrder()
            let nextID = order.next(in: list, after: cueID)
            playlistOrders[list.id] = order
            if let nextID, let next = show.cue(nextID), playback.play(next) {
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
        if selectedCueID == id {
            selectedCueID = updated.cueLists.first(where: { $0.id == list })?.cues.first(where: { $0.enabled })?.id
        }
    }

    func selectNext(in listID: UUID) {
        selectNeighbor(in: listID, direction: 1)
    }

    func selectPrevious(in listID: UUID) {
        selectNeighbor(in: listID, direction: -1)
    }

    private func selectNeighbor(in listID: UUID, direction: Int) {
        let current = selectedListID == listID ? selectedCueID : nil
        guard let id = CueNavigator.neighbor(in: show, listID: listID,
                                             selectedCueID: current, direction: direction) else { return }
        select(id, in: listID)
    }

    func selectNextList() {
        guard let destination = CueNavigator.nextList(in: show, currentListID: selectedListID) else { return }
        selectedListID = destination
        selectedCueID = show.cueLists.first(where: { $0.id == destination })?.cues.first(where: { $0.enabled })?.id
    }

    /// Pauses every running cue; pressing again resumes all paused cues.
    func togglePauseAll(using playback: PlaybackEngine) {
        let snapshots = playback.snapshots
        let hasPlaying = snapshots.values.contains { $0.phase == .playing }
        for (id, state) in snapshots {
            if hasPlaying && state.phase == .playing { playback.pause(id) }
            else if !hasPlaying && state.phase == .paused { playback.togglePause(id) }
        }
    }

    /// Fade-out is a global safety action: no STOP Rules or delayed Fire rules execute.
    func fadeAll(using playback: PlaybackEngine) {
        playingLists.removeAll()
        cancelPendingRules()
        suppressRuleEvents = true
        for (id, state) in playback.snapshots where state.phase != .waiting {
            if let cue = show.cue(id) { playback.fadeOut(cue) }
        }
        for (id, state) in playback.snapshots where state.phase == .waiting {
            playback.stop(id, notifyRules: false)
        }
        suppressRuleEvents = false
    }

    func save() {
        guard !preparingSessionAudio else { errorMessage = "Wait for audio preparation before saving."; return }
        guard let url = documentURL else { saveAs(); return }
        if ShowProjectPackage.isPackaged(url) { write(to: url) }
        else { saveAs() } // Convert legacy, stand-alone .scshow to a self-contained project.
    }

    /// Save a dated document snapshot; the working show and its main file
    /// stay active. No duplicate Audio Files folder is created.
    func saveVersion() {
        guard !isLoadingProject, !preparingSessionAudio, pendingAudioImports == 0,
              normalizingCueID == nil, normalizingListID == nil else {
            errorMessage = "Finish loading/importing/normalizing before Save Version."
            return
        }
        guard let current = documentURL, ShowProjectPackage.isPackaged(current) else {
            errorMessage = "Save the Show as a portable project first, then use Save Version."
            return
        }
        do {
            let saved = try ShowProjectPackage.saveVersion(show, documentURL: current)
            ProjectDocumentIcon.apply(to: saved.documentURL)
            // Keep this Show's active document and Undo/Redo history unchanged.
            dawBridgeMessage = "Version saved: " + saved.documentURL.lastPathComponent
        } catch {
            errorMessage = "Save Version failed: " + error.localizedDescription
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Sculpt Show"
        panel.nameFieldStringValue = "\(show.name).scshow"
        panel.message = "Creates a portable folder with the .scshow document and Audio Files organized by Cue List. Existing source media are not moved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = url.pathExtension == "scshow" ? url : url.appendingPathExtension("scshow")
        do {
            let saved = try ShowProjectPackage.create(show, requestedDocumentURL: destination)
            ProjectDocumentIcon.apply(to: saved.documentURL)
            ShowWaveformCache.shared.adoptSavedMedia(from: show, to: saved.runtimeShow)
            remapHistoryMedia(from: show, to: saved.runtimeShow)
            show = saved.runtimeShow
            documentURL = saved.documentURL
            dirty = false
        } catch {
            errorMessage = "Unable to create Show project folder: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func openShow() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Open Sculpt Show"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return openShow(at: url)
    }

    /// Called by File > Open and by macOS onOpenURL when a .scshow is opened
    /// directly in Finder. The same decoder and unsaved-changes guard apply.
    @discardableResult
    func openShow(at url: URL) -> Bool {
        guard !isLoadingProject else { return false }
        guard url.isFileURL, url.pathExtension.lowercased() == "scshow" else {
            errorMessage = "Only Sculpt Show .scshow documents can be opened."
            return false
        }
        do {
            let decoded = try ShowCodec.decode(contentsOf: url)
            let next = try ShowProjectPackage.resolve(decoded, documentURL: url)
            guard confirmDiscard() else { return false }
            let generation = UUID()
            showOpenGeneration = generation
            isLoadingProject = true
            // Full media preflight BEFORE publishing next Show. This prevents
            // existing mono stems appearing as stereo and stale waveform views.
            let allPaths = next.cueLists.flatMap { list in
                list.cues.flatMap { cue in cue.audioElements.map(\.sourcePath) }
            }
            Task { @MainActor in
                let unreadable = await ShowWaveformCache.shared.prepare(paths: allPaths)
                guard showOpenGeneration == generation else { return }
                cancelPendingRules()
                playingLists.removeAll()
                show = next
                clearHistory()
                documentURL = url
                selectedListID = next.cueLists.first?.id
                selectedCueID = next.cueLists.first?.cues.first(where: { $0.enabled })?.id
                dirty = false
                isLoadingProject = false
                if !unreadable.isEmpty {
                    errorMessage = "Show opened, but \(unreadable.count) audio file(s) could not be analyzed. Check missing media or unsupported formats in the cue Inspector."
                }
            }
            return true
        } catch {
            isLoadingProject = false
            errorMessage = "Unable to open show: \(error.localizedDescription)"
            return false
        }
    }

    /// Markers are timeline positions inside the cue, never separate cue types.
    @discardableResult
    func addMarker(to cueID: UUID, in listID: UUID, at seconds: Double) -> UUID? {
        guard show.cue(cueID) != nil else { return nil }
        let id = UUID()
        let safe = seconds.isFinite ? min(max(0, seconds), 86400) : 0
        editCue(cueID, list: listID) { cue in
            cue.markers.append(CueMarker(id: id, name: "Marker \(cue.markers.count + 1)", positionSeconds: safe))
        }
        return show.cue(cueID)?.markers.contains(where: { $0.id == id }) == true ? id : nil
    }

    func renameMarker(_ markerID: UUID, cueID: UUID, listID: UUID, to name: String) {
        editCue(cueID, list: listID) { cue in
            guard let i = cue.markers.firstIndex(where: { $0.id == markerID }) else { return }
            cue.markers[i].name = name
        }
    }

    func setMarkerPosition(_ markerID: UUID, cueID: UUID, listID: UUID, to seconds: Double) {
        guard seconds.isFinite else { return }
        editCue(cueID, list: listID) { cue in
            guard let i = cue.markers.firstIndex(where: { $0.id == markerID }) else { return }
            cue.markers[i].positionSeconds = min(max(0, seconds), 86400)
        }
    }

    func removeMarker(_ markerID: UUID, cueID: UUID, listID: UUID) {
        editCue(cueID, list: listID) { cue in
            cue.markers.removeAll { $0.id == markerID }
            // Avoid dangling rule destinations within the source cue.
            for i in cue.markers.indices {
                for j in cue.markers[i].rules.indices where cue.markers[i].rules[j].fireAtMarkerID == markerID {
                    cue.markers[i].rules[j].fireAtMarkerID = nil
                }
            }
            for i in cue.rules.indices where cue.rules[i].fireAtMarkerID == markerID {
                cue.rules[i].fireAtMarkerID = nil
            }
        }
        // Other cue rules may refer to the marker too; clear these stale references.
        var next = show
        var didChange = false
        for li in next.cueLists.indices {
            for ci in next.cueLists[li].cues.indices {
                for ri in next.cueLists[li].cues[ci].rules.indices {
                    if next.cueLists[li].cues[ci].rules[ri].fireAtMarkerID == markerID {
                        next.cueLists[li].cues[ci].rules[ri].fireAtMarkerID = nil
                        didChange = true
                    }
                }
                for mi in next.cueLists[li].cues[ci].markers.indices {
                    for ri in next.cueLists[li].cues[ci].markers[mi].rules.indices {
                        if next.cueLists[li].cues[ci].markers[mi].rules[ri].fireAtMarkerID == markerID {
                            next.cueLists[li].cues[ci].markers[mi].rules[ri].fireAtMarkerID = nil
                            didChange = true
                        }
                    }
                }
            }
        }
        if didChange { commit(next) }
    }

    func rules(for scope: RuleScope) -> [InteractionRule] {
        switch scope {
        case .show: return show.rules
        case .cueList(let id): return show.cueLists.first(where: { $0.id == id })?.rules ?? []
        case .cue(let cueID, _): return show.cue(cueID)?.rules ?? []
        case .marker(let markerID, let cueID):
            return show.cue(cueID)?.markers.first(where: { $0.id == markerID })?.rules ?? []
        }
    }

    func ignoreParentRules(for scope: RuleScope) -> Bool {
        switch scope {
        case .cue(let id, _): return show.cue(id)?.ignoreParentRules ?? false
        case .cueList(let id): return show.cueLists.first(where: { $0.id == id })?.ignoreParentRules ?? false
        default: return false
        }
    }

    func updateRules(_ rules: [InteractionRule], for scope: RuleScope, ignoreParent: Bool = false) {
        var updated = show
        switch scope {
        case .show:
            updated.rules = rules
        case .cueList(let id):
            guard let index = updated.cueLists.firstIndex(where: { $0.id == id }) else { return }
            updated.cueLists[index].rules = rules
            updated.cueLists[index].ignoreParentRules = ignoreParent
        case .cue(let cueID, let listID):
            guard updated.cue(cueID) != nil else { return }
            updated.updateCue(cueID, in: listID) {
                $0.rules = rules
                $0.ignoreParentRules = ignoreParent
            }
        case .marker(let markerID, let cueID):
            guard let listID = updated.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) })?.id else { return }
            updated.updateCue(cueID, in: listID) { cue in
                guard let index = cue.markers.firstIndex(where: { $0.id == markerID }) else { return }
                cue.markers[index].rules = rules
            }
        }
        guard updated != show else { return }
        commit(updated)
    }

    func handleRuleEvent(_ event: RuleEvent, source cueID: UUID, using playback: PlaybackEngine) {
        guard !isLoadingProject else { return }
        guard !suppressRuleEvents else { return }
        // Anti-runaway guard: a misconfigured chain cannot spawn unlimited events.
        let now = Date()
        eventTimestamps.removeAll { now.timeIntervalSince($0) > 1 }
        guard eventTimestamps.count < 64 else {
            errorMessage = "Rule safety limit reached (64 events/second). Check for cyclic rules."
            return
        }
        eventTimestamps.append(now)

        let commands = RulePlanner.commands(for: event, source: cueID, in: show, states: currentRuleStates(using: playback))
        scheduleCommands(commands, using: playback)
    }

    /// Called by the cue playback timeline when the playhead crosses a marker.
    /// Trigger is always Reaching Marker, independent from Starting/Ending/Stopping.
    func handleMarkersReached(_ markerIDs: [UUID], in cueID: UUID, using playback: PlaybackEngine) {
        guard !suppressRuleEvents else { return }
        for markerID in markerIDs {
            let now = Date()
            eventTimestamps.removeAll { now.timeIntervalSince($0) > 1 }
            guard eventTimestamps.count < 64 else {
                errorMessage = "Rule safety limit reached (64 events/second). Check marker loop rules."
                return
            }
            eventTimestamps.append(now)
            let commands = RulePlanner.markerCommands(markerID: markerID, source: cueID,
                in: show, states: currentRuleStates(using: playback)).filter {
                    $0.rule.id != playback.nativeLoopRuleID(for: cueID, markerID: markerID)
                }
            scheduleCommands(commands, using: playback, sourceMarkerID: markerID)
        }
    }

    private func currentRuleStates(using playback: PlaybackEngine) -> [UUID: RuleCueState] {
        var states: [UUID: RuleCueState] = [:]
        for (id, snapshot) in playback.snapshots {
            switch snapshot.phase {
            case .waiting: states[id] = .waiting
            case .paused: states[id] = .paused
            case .playing, .fading: states[id] = .playing
            }
        }
        return states
    }

    private func scheduleCommands(_ commands: [RuleCommand], using playback: PlaybackEngine,
                                  sourceMarkerID: UUID? = nil) {
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
                self.execute(command, using: playback, sourceMarkerID: sourceMarkerID)
            }
        }
    }

    private func execute(_ command: RuleCommand, using playback: PlaybackEngine,
                         sourceMarkerID: UUID? = nil) {
        for targetID in command.targets {
            guard let cue = show.cue(targetID) else { continue }
            switch command.rule.action {
            case .fire:
                let targetMarkerPosition: Double?
                if let markerID = command.rule.fireAtMarkerID {
                    targetMarkerPosition = cue.markers.first(where: { $0.id == markerID })?.positionSeconds
                } else if let sourceMarkerID, targetID == command.sourceCueID {
                    // Ovation-style Fire Itself: return to the preceding marker.
                    targetMarkerPosition = MarkerPlanner.loopDestination(for: sourceMarkerID, in: cue.markers)
                } else {
                    targetMarkerPosition = nil
                }
                if let position = targetMarkerPosition, let state = playback.snapshots[targetID],
                   state.phase == .playing || state.phase == .paused {
                    // Re-fire at a marker of an already active cue without restarting its start rules.
                    playback.seek(targetID, toSeconds: position)
                    if state.phase == .paused { _ = playback.play(cue) }
                } else {
                    // A pending GO cannot be repositioned. Cancel it explicitly and fire the new location.
                    if playback.snapshots[targetID]?.phase == .waiting {
                        playback.stop(targetID, notifyRules: false)
                    }
                    _ = playback.play(cue, overrideFadeInSeconds: command.rule.fireFadeInSeconds,
                                      from: targetMarkerPosition ?? 0)
                }
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
            let saved = try ShowProjectPackage.save(show, documentURL: url)
            ProjectDocumentIcon.apply(to: saved.documentURL)
            ShowWaveformCache.shared.adoptSavedMedia(from: show, to: saved.runtimeShow)
            remapHistoryMedia(from: show, to: saved.runtimeShow)
            show = saved.runtimeShow
            documentURL = saved.documentURL
            dirty = false
        } catch {
            errorMessage = "Unable to save show: \(error.localizedDescription)"
        }
    }

    private func remapHistoryMedia(from old: Show, to saved: Show) {
        var paths: [String: String] = [:]
        for list in old.cueLists {
            for cue in list.cues {
                guard let next = saved.cue(cue.id) else { continue }
                for element in cue.audioElements {
                    if let changed = next.audioElements.first(where: { $0.id == element.id }),
                       changed.sourcePath != element.sourcePath {
                        // A move within the current project includes folder swaps,
                        // where the old pathname may now belong to another list.
                        // Save As copies into a different root and keeps its originals.
                        if let root = documentURL?.deletingLastPathComponent().path,
                           element.sourcePath.hasPrefix(root + "/"),
                           changed.sourcePath.hasPrefix(root + "/") {
                            paths[element.sourcePath] = changed.sourcePath
                        }
                    }
                }
            }
        }
        func remap(_ item: HistoryItem) -> HistoryItem {
            var model = item.show
            for li in model.cueLists.indices {
                for ci in model.cueLists[li].cues.indices {
                    for ei in model.cueLists[li].cues[ci].elements.indices {
                        let path = model.cueLists[li].cues[ci].elements[ei].sourcePath
                        if let next = paths[path] { model.cueLists[li].cues[ci].elements[ei].sourcePath = next }
                    }
                }
            }
            return HistoryItem(show: model, selectedListID: item.selectedListID, selectedCueID: item.selectedCueID)
        }
        undoStack = undoStack.map(remap)
        redoStack = redoStack.map(remap)
        if !paths.isEmpty { onSavedMediaMoved?(paths) }
    }

    private func editCue(_ id: UUID, list: UUID, _ change: (inout Cue) -> Void) {
        var updated = show
        updated.updateCue(id, in: list, change)
        commit(updated)
    }

    private func commit(_ updated: Show) {
        guard updated != show else { return }
        undoStack.append(snapshot())
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
        redoStack.removeAll()
        show = updated
        dirty = true
        syncHistoryFlags()
    }
}
