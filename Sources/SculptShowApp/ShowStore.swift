import AppKit
import AVFAudio
import AVFoundation
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
    var projectIdentity: UUID { showOpenGeneration }

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
        let videos = model.cueLists.flatMap(\.cues).compactMap { $0.video.map { "\($0.sourcePath):\($0.audioPrepared == true)" } }.sorted()
        return videos.joined(separator: "|") + "\(model.sampleRate)|" + paths.joined(separator: "|") + loops.joined(separator: "|")
    }

    @discardableResult
    func applyOutputPatch(_ patch: ShowOutputPatch, expected: ShowOutputPatch,
                          deviceUID: String, projectIdentity: UUID, using playback: PlaybackEngine) -> Bool {
        guard playback.snapshots.isEmpty, !isLoadingProject, !preparingSessionAudio,
              pendingAudioImports == 0, deviceUID == playback.routingDeviceUID, !deviceUID.isEmpty else {
            errorMessage = "Stop all cues, finish media preparation and select a connected interface before applying the patch."
            return false
        }
        guard show.outputPatch == expected, showOpenGeneration == projectIdentity else {
            errorMessage = "The project patch changed while this draft was open. Reload the patch before applying."
            return false
        }
        do { try patch.validate() } catch { errorMessage = error.localizedDescription; return false }
        var updated = show
        updated.outputPatch = patch
        playback.setOutputPatch(patch)
        commit(updated)
        return true
    }

    @discardableResult
    func configureMonitor(_ settings: ShowMonitorSettings, using playback: PlaybackEngine) -> Bool {
        guard playback.snapshots.isEmpty, !isLoadingProject, !preparingSessionAudio, pendingAudioImports == 0 else {
            errorMessage = "Stop all cues and finish media preparation before configuring Monitor outputs."; return false
        }
        do { try settings.validate() } catch { errorMessage = error.localizedDescription; return false }
        guard !settings.enabled || settings.isAvailable(deviceUID: playback.routingDeviceUID, channels: playback.routingOutputCount) else {
            errorMessage = ShowMonitorSettings.Failure.unavailable.localizedDescription; return false
        }
        var updated = show
        updated.monitor = settings
        // Automatic routing consumes only the remaining program pool, in stem order.
        if updated.outputPatch.isAutomatic(on: playback.routingDeviceUID) {
            let count = playback.routingOutputCount - settings.reservedOutputs(deviceUID: playback.routingDeviceUID, channels: playback.routingOutputCount).count
            for list in show.cueLists {
                for cue in list.cues {
                    updated.updateCue(cue.id, in: list.id) { item in
                        let indices = item.elements.indices.filter { item.elements[$0].kind == .audio }
                        let widths = indices.map { ShowWaveformCache.shared.channels(at: item.elements[$0].sourcePath) ??
                            (try? AVAudioFile(forReading: URL(fileURLWithPath: item.elements[$0].sourcePath))).map { Int($0.processingFormat.channelCount) } ?? 2 }
                        let routes = AudioRoutePlan.automaticOutputs(channelCounts: widths, deviceChannels: max(1, count))
                        for (index, route) in zip(indices, routes) { item.elements[index].outputStartChannel = route }
                    }
                }
            }
        }
        playback.setMonitor(settings)
        commit(updated)
        return true
    }

    func setMonitorMix(gain: Double? = nil, pan: Double? = nil, muted: Bool? = nil,
                       excludeFromMuteAll: Bool? = nil, using playback: PlaybackEngine) {
        var updated = show
        if let gain, gain.isFinite { updated.monitor.gain = min(1, max(0, gain)) }
        if let pan, pan.isFinite { updated.monitor.pan = min(1, max(-1, pan)) }
        if let muted { updated.monitor.muted = muted }
        if let excludeFromMuteAll { updated.monitor.excludeFromMuteAll = excludeFromMuteAll }
        playback.setMonitor(updated.monitor)
        commit(updated)
    }

    func setStemMixer(_ elementID: UUID, cueID: UUID, listID: UUID, pan: Double? = nil,
                      sendToMonitor: Bool? = nil, using playback: PlaybackEngine) {
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID && $0.kind == .audio }) else { return }
            if let pan, pan.isFinite { cue.elements[index].pan = min(1, max(-1, pan)) }
            if let sendToMonitor { cue.elements[index].sendToMonitor = sendToMonitor }
        }
        playback.setElementMix(elementID, for: cueID, pan: pan, sendToMonitor: sendToMonitor)
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
                for list in show.cueLists {
                    for cue in list.cues where cue.video?.audioPrepared != true && cue.video != nil && cue.video?.isImage != true {
                        guard let movie = cue.video else { continue }
                        sessionAudioStatus = "Preparing video soundtrack…"
                        let directory = (documentURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory.appendingPathComponent("Sculpt Video Imports")).appendingPathComponent("Audio Files/Video")
                        let audio = try await VideoSoundtrack.prepare(source: URL(fileURLWithPath: movie.sourcePath), directory: directory, sampleRate: show.sampleRate)
                        if let audio {
                            let failed = await ShowWaveformCache.shared.prepare(paths: [audio.path])
                            guard failed.isEmpty else { throw VideoPlayback.Failure("Video audio waveform verification failed") }
                        }
                        guard generation == showOpenGeneration, show.cue(cue.id)?.video == movie else { preparationRequested = true; return }
                        var updated = show
                        updated.updateCue(cue.id, in: list.id) { current in
                            if let audio {
                                if let index = current.elements.firstIndex(where: { $0.kind == .audio }) {
                                    current.elements[index].sourcePath = audio.path
                                    current.elements[index].originalSourcePath = nil
                                } else {
                                    var element = CueElement.audio(audio); element.name = current.name + " · Audio"; current.elements.append(element)
                                }
                            } else { current.elements.removeAll { $0.kind == .audio } }
                            current.video?.audioPrepared = true
                        }
                        // A repair preserves the existing stem's route and mixer settings.
                        if !cue.hasAudio { assignAutomaticOutputs(to: &updated, cueID: cue.id, listID: list.id) }
                        show = updated; dirty = true
                    }
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
        return show.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == cueID })
    }

    func select(_ cueID: UUID, in listID: UUID) {
        guard show.cueLists.first(where: { $0.id == listID })?.cues.contains(where: { $0.id == cueID }) == true else { return }
        selectedListID = listID
        selectedCueID = cueID
    }

    @discardableResult
    func newShow() -> Bool {
        guard !isLoadingProject, confirmDiscard() else { return false }
        showOpenGeneration = UUID()
        cancelPendingRules()
        playingLists.removeAll()
        show = Show()
        clearHistory()
        documentURL = nil
        dirty = false
        selectedCueID = nil
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
        selectedCueID = nil
    }

    func removeList(_ id: UUID) {
        guard show.cueLists.count > 1 else { return }
        var updated = show
        updated.removeList(id)
        commit(updated)
        if selectedListID == id {
            selectedListID = updated.cueLists.first?.id
            selectedCueID = updated.cueLists.first?.cues.first(where: { $0.enabled })?.id
        }
        playingLists.removeValue(forKey: id)
    }

    func renameList(_ id: UUID, to text: String) {
        var updated = show
        updated.renameList(id, to: text)
        commit(updated)
    }

    /// Save one Undo step for a whole list's VCA-style trim, not every cue gain.
    func setCueListTrim(_ id: UUID, decibels: Double) {
        guard decibels.isFinite,
              let index = show.cueLists.firstIndex(where: { $0.id == id }) else { return }
        var updated = show
        updated.cueLists[index].trimDB = max(-60, min(6, decibels))
        commit(updated)
    }

    /// Reads the connected interface when an import/publication is applied.
    var audioOutputCount: () -> Int = { 2 }
    var onSavedMediaMoved: (([String: String]) -> Void)?

    private func assignAutomaticOutputs(to show: inout Show, cueID: UUID, listID: UUID) {
        show.updateCue(cueID, in: listID) { cue in
            let indices = cue.elements.indices.filter { cue.elements[$0].kind == .audio }
            let widths = indices.map { index in
                ShowWaveformCache.shared.channels(at: cue.elements[index].sourcePath) ??
                    (try? AVAudioFile(forReading: URL(fileURLWithPath: cue.elements[index].sourcePath)))
                        .map { Int($0.processingFormat.channelCount) } ?? 2
            }
            let outputs = AudioRoutePlan.automaticOutputs(channelCounts: widths,
                deviceChannels: max(1, audioOutputCount()))
            for (index, output) in zip(indices, outputs) { cue.elements[index].outputStartChannel = output }
        }
    }

    func importVideo(to listID: UUID) {
        let panel = NSOpenPanel(); panel.title = "Import video or image cue"
        panel.allowedContentTypes = [.movie, .image]; panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addVideo(url, to: listID)
    }
    func addVideo(_ url: URL, to listID: UUID) {
        guard pendingAudioImports == 0, !isLoadingProject else { return }
        let generation = showOpenGeneration
        pendingAudioImports += 1; audioImportProgress = "Video"
        Task {
            defer { pendingAudioImports -= 1; audioImportProgress = "" }
            do {
                let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                let duration: Double
                if image { _ = try await VideoPlayback.loadStillImage(url); duration = 10 }
                else { (_, duration) = try await VideoPlayback.silentAsset(url) }
                guard generation == showOpenGeneration, show.cueLists.contains(where: { $0.id == listID }) else { return }
                let directory: URL
                if let documentURL, ShowProjectPackage.isPackaged(documentURL) {
                    directory = documentURL.deletingLastPathComponent().appendingPathComponent("Video Files")
                } else {
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sculpt Video Imports")
                }
                let copy = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                }.value
                guard generation == showOpenGeneration else { try? FileManager.default.removeItem(at: copy); return }
                // Publish the cue only after its soundtrack is decoded and verified.
                // Import completion must never expose a silent, half-prepared movie.
                let audioDirectory = (documentURL?.deletingLastPathComponent() ?? directory).appendingPathComponent("Audio Files/Video")
                let audio = image ? nil : try await VideoSoundtrack.prepare(source: copy, directory: audioDirectory, sampleRate: show.sampleRate)
                if let audio {
                    let failed = await ShowWaveformCache.shared.prepare(paths: [audio.path])
                    guard failed.isEmpty else { throw VideoPlayback.Failure("Cannot verify video soundtrack") }
                }
                guard generation == showOpenGeneration else { return }
                var updated = show
                guard let li = updated.cueLists.firstIndex(where: { $0.id == listID }) else { return }
                var cue = Cue(name: url.deletingPathExtension().lastPathComponent, fadeOutSeconds: 1, fadeInSeconds: 1, durationSeconds: duration)
                cue.video = CueVideo(sourcePath: copy.path, duration: duration)
                cue.video?.isImage = image
                cue.video?.audioPrepared = true
                if image { cue.loop = true }
                if let audio { var stem = CueElement.audio(audio); stem.name = cue.name + " · Audio"; cue.elements.append(stem) }
                updated.cueLists[li].cues.append(cue)
                assignAutomaticOutputs(to: &updated, cueID: cue.id, listID: listID)
                commit(updated); select(cue.id, in: listID)
            } catch { errorMessage = "Video import failed: \(error.localizedDescription)" }
        }
    }
    func setVideoScale(_ value: Double, cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) { $0.video?.scale = value.isFinite ? min(4, max(0.1, value)) : 1 }
    }

    func setVideoPosition(x: Double? = nil, y: Double? = nil, cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) {
            if let x, x.isFinite { $0.video?.offsetX = min(2, max(-2, x)) }
            if let y, y.isFinite { $0.video?.offsetY = min(2, max(-2, y)) }
        }
    }
    func setVideoDimensions(width: Double? = nil, height: Double? = nil, cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) { cue in
            guard var movie = cue.video else { return }
            if let width, width.isFinite {
                movie.widthScale = min(4, max(0.1, width))
                if movie.keepsAspectRatio { movie.heightScale = movie.widthScale }
            }
            if let height, height.isFinite {
                movie.heightScale = min(4, max(0.1, height))
                if movie.keepsAspectRatio { movie.widthScale = movie.heightScale }
            }
            cue.video = movie
        }
    }
    func setVideoAspectLock(_ locked: Bool, cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) { cue in
            guard var movie = cue.video else { return }
            movie.lockAspectRatio = locked
            if locked { movie.heightScale = movie.widthScale ?? 1; if movie.framing == .stretch { movie.framing = .fit } }
            cue.video = movie
        }
    }
    func resetVideoTransform(_ cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) {
            $0.video?.scale = 1; $0.video?.offsetX = 0; $0.video?.offsetY = 0
            $0.video?.widthScale = 1; $0.video?.heightScale = 1; $0.video?.lockAspectRatio = true; $0.video?.framing = .fit
        }
    }

    func rebuildVideoSoundtrack(_ cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        guard playback.snapshots.isEmpty, !preparingSessionAudio, pendingAudioImports == 0,
              let movie = show.cue(cueID)?.video, movie.isImage != true else { return }
        editCue(cueID, list: listID) { $0.video?.audioPrepared = nil }
        requestSessionAudioPreparation(using: playback, force: true)
    }

    func setVideoFraming(_ value: VideoFraming, cueID: UUID, in listID: UUID) {
        editCue(cueID, list: listID) { $0.video?.framing = value; if value == .stretch { $0.video?.lockAspectRatio = false } }
    }
    func setImageDuration(_ value: Double, cueID: UUID, in listID: UUID) {
        guard value.isFinite, show.cue(cueID)?.video?.isImage == true else { return }
        editCue(cueID, list: listID) {
            let duration = min(86400, max(0.1, value))
            $0.video?.duration = duration; $0.durationSeconds = duration
        }
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
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard pendingAudioImports == 0 else {
            errorMessage = "Complete the previous audio import first."
            return
        }
        pendingAudioImports += 1
        audioImportProgress = "0/\(files.count)"
        Task {
            defer { pendingAudioImports -= 1; audioImportProgress = "" }
            let failed = await ShowWaveformCache.shared.prepare(paths: files.map(\.path)) { completed, total in
                self.audioImportProgress = "\(completed)/\(total)"
            }
            guard failed.isEmpty else {
                errorMessage = "Audio import cancelled: waveform/PCM analysis failed for " +
                    failed.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                return
            }
            // Do not display or select new cues until metadata and waveforms exist.
            guard show.cueLists.contains(where: { $0.id == listID }) else { return }
            var updated = show
            let newIDs = updated.addAudio(files, to: listID)
            guard !newIDs.isEmpty else { return }
            for (id, url) in zip(newIDs, files) {
                let length = (try? AVAudioPlayer(contentsOf: url))?.duration ??
                    ShowWaveformCache.shared.envelopes[url.path]?.duration ?? 5
                updated.updateCue(id, in: listID) {
                    $0.durationSeconds = max(0.1, length)
                    $0.durationMode = .fixed
                }
            }
            commit(updated)
            select(newIDs[0], in: listID)
        }
    }

    /// Native Sculpt DAW (.scraft) import; creates a new cue without touching the
    /// current audio or document. Unsupported DAW edits must be bounced first.
    func importFromDAW(to listID: UUID) {
        guard pendingAudioImports == 0, !isLoadingProject else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Sculpt DAW Session"
        panel.message = "Select an aligned, consolidated .scraft session. Split or processed regions require a bounce in Sculpt DAW."
        panel.allowedContentTypes = [UTType(filenameExtension: "scdaw") ?? .json, UTType(filenameExtension: "scraft") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingAudioImports += 1
        audioImportProgress = "READING DAW SESSION"
        Task {
            defer { pendingAudioImports -= 1; audioImportProgress = "" }
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    try SculptDAWSessionImport.read(at: url)
                }.value
                audioImportProgress = "ANALYZING \(session.stems.count) STEMS"
                let failed = await ShowWaveformCache.shared.prepare(paths: session.audioPaths) { completed, total in
                    self.audioImportProgress = "\(completed)/\(total)"
                }
                guard failed.isEmpty else {
                    errorMessage = "DAW import cancelled: unreadable media " + failed.joined(separator: ", ")
                    return
                }
                guard let i = show.cueLists.firstIndex(where: { $0.id == listID }) else { return }
                var updated = show
                var cue = Cue(name: session.name)
                cue.elements = session.stems.map { stem in
                    var element = CueElement.audio(URL(fileURLWithPath: stem.path))
                    element.name = stem.name
                    element.outputStartChannel = stem.output
                    element.gain = stem.gain
                    element.muted = stem.muted
                    return element
                }
                cue.durationMode = .fixed
                cue.durationSeconds = min(86400, max(0.1, session.duration))
                cue.markers = session.markers.map { CueMarker(name: $0.name, positionSeconds: $0.seconds) }
                updated.cueLists[i].cues.append(cue)
                assignAutomaticOutputs(to: &updated, cueID: cue.id, listID: listID)
                commit(updated)
                select(cue.id, in: listID)
                dawBridgeMessage = "DAW session imported: \(session.stems.count) stems, \(session.markers.count) markers."
            } catch {
                errorMessage = "Import from DAW failed: \(error.localizedDescription)"
            }
        }
    }

    func addEmptyCue(to listID: UUID) {
        var updated = show
        let after = selectedListID == listID ? selectedCueID : nil
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
        attachAudioURLs(panel.urls, to: cueID, in: listID, using: playback)
    }

    func attachAudioURLs(_ urls: [URL], to cueID: UUID, in listID: UUID,
                         using playback: PlaybackEngine) {
        guard show.cue(cueID)?.video == nil else { errorMessage = "Use a separate audio cue for the soundtrack."; return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard pendingAudioImports == 0 else {
            errorMessage = "Complete the previous audio import first."
            return
        }
        pendingAudioImports += 1
        audioImportProgress = "0/\(files.count)"
        Task {
            defer { pendingAudioImports -= 1; audioImportProgress = "" }
            let failed = await ShowWaveformCache.shared.prepare(paths: files.map(\.path)) { completed, total in
                self.audioImportProgress = "\(completed)/\(total)"
            }
            guard failed.isEmpty else {
                errorMessage = "Audio attachment cancelled: cannot analyze " +
                    failed.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                return
            }
            guard show.cueLists.contains(where: { $0.id == listID &&
                $0.cues.contains(where: { $0.id == cueID }) }) else { return }
            var updated = show
            // A newly attached stem can extend the cue, even when it already
            // contains audio. Never shorten a manually configured duration.
            let previousLength = updated.cue(cueID)?.durationSeconds ?? 0
            guard updated.appendAudio(files, to: cueID) else { return }
            assignAutomaticOutputs(to: &updated, cueID: cueID, listID: listID)
            let longest = files.compactMap { ShowWaveformCache.shared.envelopes[$0.path]?.duration }.max()
            if let longest, longest.isFinite, longest > previousLength {
                updated.updateCue(cueID, in: listID) {
                    $0.durationSeconds = max(0.1, longest)
                    $0.durationMode = .fixed
                }
            }
            playback.stop(cueID, notifyRules: false)
            commit(updated)
            select(cueID, in: listID)
        }
    }

    /// Rearrange audio stems only. LTC and other non-audio elements retain
    /// their positions, and cue/element identities and routing stay unchanged.
    func moveAudioStem(_ elementID: UUID, in cueID: UUID, listID: UUID, by direction: Int) {
        guard direction == -1 || direction == 1,
              let cue = show.cue(cueID) else { return }
        let positions = cue.elements.indices.filter { cue.elements[$0].kind == .audio }
        guard let position = positions.firstIndex(where: { cue.elements[$0].id == elementID }),
              positions.indices.contains(position + direction) else { return }
        let sourceIndex = positions[position]
        let targetIndex = positions[position + direction]
        editCue(cueID, list: listID) { item in
            item.elements.swapAt(sourceIndex, targetIndex)
        }
    }

    private var pendingDAWPublications: [URL] = []
    private var receivingDAWPublication = false

    func chooseDAWPublication(using playback: PlaybackEngine) {
        let panel = NSOpenPanel()
        panel.title = "Receive DAW Publication"
        panel.allowedContentTypes = [UTType(filenameExtension: "sculptbridge") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        receiveDAWPublication(at: url, using: playback)
    }

    func receiveDAWPublication(at url: URL, using playback: PlaybackEngine) {
        guard url.isFileURL, url.pathExtension.lowercased() == "sculptbridge" else { return }
        if !pendingDAWPublications.contains(url) { pendingDAWPublications.append(url) }
        applyPendingDAWPublications(using: playback)
    }

    func applyPendingDAWPublications(using playback: PlaybackEngine) {
        guard !receivingDAWPublication, !isLoadingProject, pendingAudioImports == 0,
              normalizingCueID == nil, normalizingListID == nil,
              let url = pendingDAWPublications.first else { return }
        receivingDAWPublication = true
        Task {
            defer {
                receivingDAWPublication = false
                if pendingDAWPublications.first != url { applyPendingDAWPublications(using: playback) }
            }
            do {
                let packet = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 8 * 1024 * 1024 else { throw SculptBridgeReturn.Failure.invalid }
                    return try SculptBridgeReturn.decode(Data(contentsOf: url), at: url)
                }.value
                let m = packet.manifest
                let listID = packet.targetSelection ? selectedListID : m.cueListID
                guard let listID else { throw SculptBridgeReturn.Failure.destination }
                let receipt = url.deletingLastPathComponent().appendingPathComponent("receipt.json")
                if let data = try? Data(contentsOf: receipt),
                   let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   record["status"] as? String == "applied",
                   record["publicationID"] as? String == packet.publicationID.uuidString,
                   let rawCue = record["originCue"],
                   let appliedCue = try? JSONDecoder().decode(Cue.self, from: JSONSerialization.data(withJSONObject: rawCue)),
                   let currentCue = show.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == m.cueID }),
                   SculptBridgeReturn.matchesSnapshot(currentCue, appliedCue) {
                    pendingDAWPublications.removeAll { $0 == url }
                    dawBridgeMessage = "This DAW publication has already been applied."
                    return
                }
                // Preflight the model before expensive media work and again after suspension.
                _ = try SculptBridgeReturn.applying(packet, to: show, destinationListID: listID)
                if packet.publishMode == "updateCue", playback.snapshots[m.cueID] != nil {
                    dawBridgeMessage = "DAW update queued. It will be applied when this cue stops."
                    return
                }
                for stem in m.stems {
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: stem.sourcePath))
                    let channels = Int(file.processingFormat.channelCount)
                    guard (1...2).contains(channels), file.length > 0,
                          stem.outputStartChannel + channels - 1 <= 64,
                          abs(Double(file.length) / file.processingFormat.sampleRate - m.durationSeconds) < 0.05 else {
                        throw SculptBridgeReturn.Failure.media
                    }
                }
                let generation = showOpenGeneration
                let failed = await ShowWaveformCache.shared.prepare(paths: m.stems.map(\.sourcePath)) { _, _ in }
                guard failed.isEmpty else { throw SculptBridgeReturn.Failure.media }
                guard generation == showOpenGeneration else { throw SculptBridgeReturn.Failure.destination }
                if packet.publishMode == "updateCue", playback.snapshots[m.cueID] != nil {
                    dawBridgeMessage = "DAW update queued until this cue stops."
                    return
                }
                var updated = try SculptBridgeReturn.applying(packet, to: show, destinationListID: listID)
                assignAutomaticOutputs(to: &updated, cueID: m.cueID, listID: listID)
                commit(updated)
                select(m.cueID, in: listID)
                pendingDAWPublications.removeAll { $0 == url }
                // Receipt means applied in memory; the user still saves the Show normally.
                let cue = updated.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == m.cueID })
                var record: [String: Any] = ["status": "applied", "publicationID": packet.publicationID.uuidString,
                    "cueID": m.cueID.uuidString, "publishMode": packet.publishMode]
                if let cue { record["originCue"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cue)) }
                do {
                    try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: receipt, options: .atomic)
                    appliedDAWReceipts[m.cueID] = receipt
                }
                catch { errorMessage = "Cue updated, but the DAW receipt could not be saved: \(error.localizedDescription)" }
                dawBridgeMessage = "DAW publication applied: \(m.stems.count) stems, \(m.markers.count) markers. Save Show to keep it."
            } catch {
                pendingDAWPublications.removeAll { $0 == url }
                errorMessage = "DAW publication rejected: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sculpt Show ⇄ Sculpt DAW bridge v1
    /// Prepare editable DAW material without changing the loaded show or audio graph.
    /// The script is consumed by `soundcraft-cli script FILE` in Sculpt DAW.
    func exportCueToDAW(_ cueID: UUID, in listID: UUID) {
        do {
            let manifest = try SculptBridge.manifest(show: show, listID: listID, cueID: cueID)
            let supported: Set<String> = ["wav", "wave", "aif", "aiff", "flac"]
            var rate: Int?
            var channels: [UUID: Int] = [:]
            for stem in manifest.stems {
                let url = URL(fileURLWithPath: stem.sourcePath)
                guard url.isFileURL, supported.contains(url.pathExtension.lowercased()),
                      let audio = try? AVAudioFile(forReading: url),
                      (1...2).contains(Int(audio.processingFormat.channelCount)) else {
                    errorMessage = "Cannot send to DAW: unavailable or unsupported mono/stereo WAV, AIFF or FLAC file: \(stem.name)."
                    return
                }
                if rate == nil { rate = Int(audio.processingFormat.sampleRate.rounded()) }
                channels[stem.elementID] = Int(audio.processingFormat.channelCount)
            }
            let savePanel = NSSavePanel()
            savePanel.title = "Send Cue to Sculpt DAW"
            savePanel.allowedContentTypes = [.json]
            let safe = manifest.cueName.replacingOccurrences(of: "/", with: "-")
            savePanel.nameFieldStringValue = "\(safe)-bridge.json"
            savePanel.message = "Creates JSON metadata plus a Sculpt DAW CLI import script. Does not change Show or original media."
            guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
            let base = url.deletingPathExtension()
            let destination = base.appendingPathExtension("scraft")
            let commandsURL = URL(fileURLWithPath: base.path + "-DAW.txt")
            let commands = try SculptBridge.dawImportScript(manifest, sampleRate: rate ?? 48000,
                                                              destination: destination.path,
                                                              channelCounts: channels)
            try SculptBridge.encode(manifest).write(to: url, options: .atomic)
            try Data(commands.utf8).write(to: commandsURL, options: .atomic)
            // No automatic process launch: DAW CLI availability/build differs by installation.
        } catch {
            errorMessage = "Sculpt Bridge export failed: \(error.localizedDescription)"
        }
    }

    /// Show -> DAW Phase 2: direct, non-destructive, editable session handoff.
    /// Does not stop any cue or mutate Show's audio graph / saved document.
    @Published private(set) var dawBridgeBusy = false
    @Published private(set) var dawBridgeCueID: UUID?
    @Published var dawBridgeMessage: String?

    func editCueInDAW(_ cueID: UUID, in listID: UUID) {
        guard !dawBridgeBusy, !preparingSessionAudio, !isLoadingProject, pendingAudioImports == 0 else { return }
        // A saved project anchors every DAW edit inside its own bridge folder.
        if documentURL == nil { saveAs() }
        guard let projectDocument = documentURL else { return }
        do {
            let manifest = try SculptBridge.manifest(show: show, listID: listID, cueID: cueID)
            let preparation = try SculptDAWLaunchBridge.prepare(manifest, projectDocument: projectDocument)
            dawBridgeBusy = true
            dawBridgeCueID = cueID
            dawBridgeMessage = "Preparing Sculpt DAW session…"
            SculptDAWLaunchBridge.run(preparation) { [weak self] result in
                guard let self else { return }
                self.dawBridgeBusy = false
                self.dawBridgeCueID = nil
                switch result {
                case .success(let message): self.dawBridgeMessage = message
                case .failure(let error):
                    self.dawBridgeMessage = nil
                    self.errorMessage = "Sculpt Bridge: \(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = "Sculpt Bridge: \(error.localizedDescription)"
        }
    }

    // MARK: - Offline loudness normalization (REAPER-style workflow)
    @Published private(set) var normalizingCueID: UUID?
    @Published private(set) var normalizingListID: UUID?
    @Published var listNormalizationSummary: String?
    @Published private(set) var normalizationReportCueID: UUID?
    @Published private(set) var normalizationReport: String?

    func normalizeCue(_ cueID: UUID, in listID: UUID,
                      mode: NormalizationTarget, target: Double,
                      peakLimit: Bool, using playback: PlaybackEngine) {
        guard normalizingCueID == nil, normalizingListID == nil else { return }
        guard playback.snapshots.isEmpty else {
            errorMessage = "Stop all cue playback before normalizing. Offline file processing could affect disk performance during a live show."
            return
        }
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = list.cues.first(where: { $0.id == cueID }), cue.hasAudio else { return }
        // Normalized audio must be part of a portable Show project from the
        // start. No hidden external Application Support copies or broken refs.
        guard let showID = documentURL, ShowProjectPackage.isPackaged(showID) else {
            errorMessage = "Save the Show as a portable project before normalizing audio (File > Save As)."
            return
        }
        let outputDirectory: URL
        do {
            outputDirectory = try ShowProjectPackage.audioDirectory(
                for: listID, in: show, documentURL: showID)
        } catch {
            errorMessage = "Normalize Audio: cannot access the project media folder: \(error.localizedDescription)"
            return
        }
        let requested = cue.audioElements.map {
            CueOfflineNormalizer.Request(elementID: $0.id, name: $0.name, originalPath: $0.sourcePath)
        }
        normalizingCueID = cueID
        normalizationReportCueID = cueID
        normalizationReport = "Analyzing and rendering \(requested.count) stem(s)…"
        // Heavy PCM analysis and writing never run on the SwiftUI or audio thread.
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try CueOfflineNormalizer.normalize(requested,
                       outputDirectory: outputDirectory,
                       mode: mode, target: target, peakLimit: peakLimit)
                }.value
                // A normalized cue must display a ready waveform on relink.
                let unreadable = await ShowWaveformCache.shared.prepare(
                    paths: results.map(\.normalizedPath))
                guard unreadable.isEmpty else {
                    for result in results { try? FileManager.default.removeItem(atPath: result.normalizedPath) }
                    self.errorMessage = "The new normalized WAV cannot be decoded for its waveform. Cue unchanged."
                    self.normalizingCueID = nil
                    return
                }
                // Do not link a file into a different show or into a changed cue.
                guard self.documentURL == showID,
                      let current = self.show.cueLists.first(where: { $0.id == listID })?.cues.first(where: { $0.id == cueID }),
                      playback.snapshots.isEmpty,
                      results.allSatisfy({ item in
                          current.audioElements.contains(where: {
                              $0.id == item.elementID && $0.sourcePath == item.originalPath
                          })
                      }) else {
                    for result in results { try? FileManager.default.removeItem(atPath: result.normalizedPath) }
                    self.errorMessage = "The cue changed or playback began during normalization. No files were relinked."
                    self.normalizingCueID = nil
                    return
                }
                self.editCue(cueID, list: listID) { cue in
                    for result in results {
                        if let index = cue.elements.firstIndex(where: { $0.id == result.elementID }) {
                            cue.elements[index].sourcePath = result.normalizedPath
                            cue.elements[index].originalSourcePath = nil
                        }
                    }
                }
                func value(_ x: Double?) -> String {
                    x.map { String(format: "%.1f", $0) } ?? "—"
                }
                self.normalizationReport = results.map {
                    "\($0.name):  \(value($0.beforeLUFS)) LUFS  |  \(value($0.beforePeak)) dBFS peak  |  \(String(format: "%+.1f", $0.gainDB)) dB  →  \(value($0.estimatedAfterLUFS)) LUFS / \(value($0.estimatedAfterPeak)) dBFS"
                }.joined(separator: "\n") + "\n\nNormalized WAV copies written to the project's Audio Files / Cue List folder. Original media are unchanged. Save the Show to persist the new cue references."
                self.normalizingCueID = nil
            } catch {
                self.normalizingCueID = nil
                self.normalizationReport = nil
                self.errorMessage = "Normalize Audio: \(error.localizedDescription)"
            }
        }
    }

    /// One-click, non-destructive -18 LUFS-I normalization for an entire cue
    /// list. Empty/timecode-only cues are skipped. Every mono/stereo stem is
    /// normalized independently, with the existing -1 dBFS sample-peak guard.
    /// A failure rolls back the entire batch; no partial cue-list relinking.
    func normalizeCueList(_ listID: UUID, mode: NormalizationTarget = .integratedLUFS,
                          target: Double = -18, peakLimit: Bool = true,
                          using playback: PlaybackEngine) {
        guard target.isFinite else { return }
        guard normalizingCueID == nil, normalizingListID == nil,
              !isLoadingProject, pendingAudioImports == 0 else { return }
        guard playback.snapshots.isEmpty else {
            errorMessage = "Stop playback before normalizing the cue list."
            return
        }
        guard let list = show.cueLists.first(where: { $0.id == listID }) else { return }
        let requests = list.cues.flatMap { cue in
            cue.audioElements.map { element in
                CueOfflineNormalizer.Request(elementID: element.id,
                    name: "\(cue.name) / \(element.name)", originalPath: element.sourcePath)
            }
        }
        guard !requests.isEmpty else {
            errorMessage = "This cue list has no audio to normalize."
            return
        }
        guard let showID = documentURL, ShowProjectPackage.isPackaged(showID) else {
            errorMessage = "Save the Show as a portable project before normalizing (File > Save As)."
            return
        }
        let folder: URL
        do {
            folder = try ShowProjectPackage.audioDirectory(for: listID, in: show,
                                                            documentURL: showID)
        } catch {
            errorMessage = "Cannot access cue-list media folder: \(error.localizedDescription)"
            return
        }
        normalizingListID = listID
        listNormalizationSummary = nil
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try CueOfflineNormalizer.normalize(requests, outputDirectory: folder,
                        mode: mode, target: target, peakLimit: peakLimit)
                }.value
                // Preload waveforms before publishing any changed source paths.
                let failed = await ShowWaveformCache.shared.prepare(
                    paths: results.map(\.normalizedPath))
                let current = self.show.cueLists.first(where: { $0.id == listID })
                let currentAudio = current?.cues.flatMap { $0.audioElements } ?? []
                let unchanged = currentAudio.count == requests.count &&
                    currentAudio.allSatisfy { element in
                        requests.contains { $0.elementID == element.id &&
                                            $0.originalPath == element.sourcePath }
                    }
                guard failed.isEmpty, self.documentURL == showID,
                      playback.snapshots.isEmpty, unchanged else {
                    for result in results {
                        try? FileManager.default.removeItem(atPath: result.normalizedPath)
                    }
                    self.normalizingListID = nil
                    self.errorMessage = failed.isEmpty
                        ? "The Show changed during normalization. No cue-list files were relinked."
                        : "A normalized waveform could not be verified. Cue list unchanged."
                    return
                }
                let newPaths = Dictionary(uniqueKeysWithValues:
                    results.map { ($0.elementID, $0.normalizedPath) })
                var updated = self.show
                if let li = updated.cueLists.firstIndex(where: { $0.id == listID }) {
                    for ci in updated.cueLists[li].cues.indices {
                        for ei in updated.cueLists[li].cues[ci].elements.indices {
                            let id = updated.cueLists[li].cues[ci].elements[ei].id
                            if let path = newPaths[id] {
                                updated.cueLists[li].cues[ci].elements[ei].sourcePath = path
                                updated.cueLists[li].cues[ci].elements[ei].originalSourcePath = nil
                            }
                        }
                    }
                }
                self.commit(updated)
                self.normalizingListID = nil
                let songCount = list.cues.filter { $0.hasAudio }.count
                self.listNormalizationSummary = "Normalized \(results.count) audio stems across \(songCount) cues in '\(list.name)' toward -18 LUFS-I. Original audio was preserved; normalized files are in Audio Files. Peak protection at -1 dBFS may prevent some files from reaching exactly -18 LUFS. Save the Show to keep the new references."
            } catch {
                self.normalizingListID = nil
                self.errorMessage = "Cue List normalization failed: \(error.localizedDescription)"
            }
        }
    }

    func chooseDAWCLI() {
        do {
            try SculptDAWLaunchBridge.chooseCLI()
            dawBridgeMessage = "Sculpt DAW CLI configured. Next EDIT IN DAW will create a native, editable session."
        } catch { errorMessage = error.localizedDescription }
    }

    /// User explicitly picks a bounced mono/stereo stem to replace one source.
    /// Changes take effect on the NEXT playback, while cue/marker/routing IDs persist.
    func receiveDAWBounce(for elementID: UUID, in cueID: UUID, listID: UUID) {
        guard let element = show.cue(cueID)?.audioElements.first(where: { $0.id == elementID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Receive DAW Bounce — \(element.name)"
        panel.message = "Replace only this audio reference. Markers, routing and LTC remain unchanged."
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let replacement = try? AVAudioFile(forReading: url),
              (1...2).contains(Int(replacement.processingFormat.channelCount)) else {
            errorMessage = "The DAW bounce must be a readable mono or stereo audio file."
            return
        }
        // A stereo replacement cannot overflow the last available physical channel.
        guard element.outputStartChannel + Int(replacement.processingFormat.channelCount) - 1 <= 64 else {
            errorMessage = "The returned stem exceeds the 64-channel output routing limit."
            return
        }
        relinkElement(elementID, in: cueID, listID: listID, to: url)
    }

    func addTimecode(to cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        guard show.cue(cueID)?.video == nil else { errorMessage = "Video cues cannot contain LTC elements."; return }
        // Attaching LTC is non-destructive; a running cue adopts it on next GO.
        editCue(cueID, list: listID) { cue in
            if cue.elements.contains(where: { $0.kind == .timecode }) { return }
            cue.elements.append(.timecode())
        }
    }

    func removeElement(_ elementID: UUID, from cueID: UUID, in listID: UUID, using playback: PlaybackEngine) {
        playback.stop(cueID, notifyRules: false)
        editCue(cueID, list: listID) { $0.elements.removeAll { $0.id == elementID } }
    }

    /// Replace a reference while preserving element UUID, routing, gain and Rules.
    /// Does not stop a currently playing cue: the new path takes effect on next GO.
    func relinkElement(_ elementID: UUID, in cueID: UUID, listID: UUID, to url: URL) {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: {
                $0.id == elementID && $0.kind == .audio
            }) else { return }
            cue.elements[index].sourcePath = url.path
            cue.elements[index].originalSourcePath = nil
        }
    }

    func chooseRelink(for elementID: UUID, cueID: UUID, listID: UUID) {
        guard let element = show.cue(cueID)?.audioElements.first(where: { $0.id == elementID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Relink Audio — \(element.name)"
        panel.message = "Choose the replacement audio file. The active cue will not be interrupted."
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: element.sourcePath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinkElement(elementID, in: cueID, listID: listID, to: url)
    }

    /// Only exact-filename, unambiguous matches are relinked; never guesses
    /// based on partial names. Skips packages and hidden folders, max 10k files.
    /// Can be run while playing: existing audio file handles stay untouched.
    @discardableResult
    func relinkMissingMedia(in folder: URL) -> Int {
        guard folder.isFileURL else { return 0 }
        var existing: [String: [URL]] = [:]
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var inspected = 0
            for case let url as URL in enumerator {
                inspected += 1
                if inspected > 10_000 { break }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                existing[url.lastPathComponent.lowercased(), default: []].append(url)
            }
        }
        var updated = show
        var replacements = 0
        for li in updated.cueLists.indices {
            for ci in updated.cueLists[li].cues.indices {
                for ei in updated.cueLists[li].cues[ci].elements.indices {
                    let item = updated.cueLists[li].cues[ci].elements[ei]
                    guard item.kind == .audio,
                          !FileManager.default.fileExists(atPath: item.sourcePath),
                          let matches = existing[URL(fileURLWithPath: item.sourcePath).lastPathComponent.lowercased()],
                          matches.count == 1 else { continue }
                    updated.cueLists[li].cues[ci].elements[ei].sourcePath = matches[0].path
                    updated.cueLists[li].cues[ci].elements[ei].originalSourcePath = nil
                    replacements += 1
                }
            }
        }
        if replacements > 0 { commit(updated) }
        return replacements
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
        let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID })
        let frameRate = element?.frameRate ?? 25
        guard CueElement.isValidTimecode(value, frameRate: frameRate,
                                         dropFrame: element?.timecodeDropFrame ?? false) else {
            errorMessage = "Use timecode HH:MM:SS:FF with frames below the selected FPS."
            return
        }
        editCue(cueID, list: listID) { cue in
            guard let index = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[index].timecodeStart = value
        }
    }

    func setTimecodeTrim(_ elementID: UUID, in cueID: UUID, listID: UUID, to value: String) {
        guard let element = show.cue(cueID)?.elements.first(where: { $0.id == elementID }) else { return }
        let rate = LTCFrameRate(fps: element.frameRate, drop: element.timecodeDropFrame)
        guard let trim = LTCFrameTrim(text: value, rate: rate) else {
            errorMessage = "LTC trim must be ±HH:MM:SS:FF at the selected frame rate."
            return
        }
        editCue(cueID, list: listID) { cue in
            guard let i = cue.elements.firstIndex(where: { $0.id == elementID }) else { return }
            cue.elements[i].ltcTrim = trim.text
        }
    }

    /// Single-frame SMPTE trim adjustment for a cue-local LTC element.
    /// Keeps the audio timeline, cue start and output routing untouched.
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
                if let old = cue.video?.sourcePath, let new = next.video?.sourcePath, old != new { paths[old] = new }
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
                    if let path = model.cueLists[li].cues[ci].video?.sourcePath, let next = paths[path] { model.cueLists[li].cues[ci].video?.sourcePath = next }
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

    func setCueTriggers(_ triggers: CueTriggers, cueID: UUID, using midi: MIDIControl) {
        guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == cueID }) }) else { return }
        if let error = CueTriggerResolver.conflict(triggers, cueID: cueID, in: show) { errorMessage = error; return }
        if let note = triggers.midi, midi.mappings.values.contains(note) { errorMessage = "This MIDI control is assigned to global transport. Clear that mapping in MIDI Setup first."; return }
        var updated = show; updated.updateCue(cueID, in: list.id) { $0.triggers = triggers }
        // Use the same Undo/save transaction as other inspector controls.
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
