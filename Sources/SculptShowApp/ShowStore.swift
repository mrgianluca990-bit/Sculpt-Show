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
    @Published private(set) var playingLists: [UUID: UUID] = [:]
    private var pendingRuleTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRuleTargets: [UUID: Set<UUID>] = [:]
    private var eventGeneration = UUID()
    private var eventTimestamps: [Date] = []
    private var suppressRuleEvents = false

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
        guard confirmDiscard() else { return false }
        cancelPendingRules()
        playingLists.removeAll()
        show = Show()
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
        select(newIDs[0], in: listID)
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
        guard !dawBridgeBusy else { return }
        do {
            let manifest = try SculptBridge.manifest(show: show, listID: listID, cueID: cueID)
            let preparation = try SculptDAWLaunchBridge.prepare(manifest)
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
    @Published private(set) var normalizationReportCueID: UUID?
    @Published private(set) var normalizationReport: String?

    func normalizeCue(_ cueID: UUID, in listID: UUID,
                      mode: NormalizationTarget, target: Double,
                      peakLimit: Bool, using playback: PlaybackEngine) {
        guard normalizingCueID == nil else { return }
        guard playback.snapshots.isEmpty else {
            errorMessage = "Stop all cue playback before normalizing. Offline file processing could affect disk performance during a live show."
            return
        }
        guard let list = show.cueLists.first(where: { $0.id == listID }),
              let cue = list.cues.first(where: { $0.id == cueID }), cue.hasAudio else { return }
        let requested = cue.audioElements.map {
            CueOfflineNormalizer.Request(elementID: $0.id, name: $0.name, originalPath: $0.sourcePath)
        }
        let showID = documentURL // not a unique document ID: guarded by cue/source check below
        normalizingCueID = cueID
        normalizationReportCueID = cueID
        normalizationReport = "Analyzing and rendering \(requested.count) stem(s)…"
        // Heavy PCM analysis and writing never run on the SwiftUI or audio thread.
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try CueOfflineNormalizer.normalize(requested, cueID: cueID,
                       mode: mode, target: target, peakLimit: peakLimit)
                }.value
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
                        }
                    }
                }
                func value(_ x: Double?) -> String {
                    x.map { String(format: "%.1f", $0) } ?? "—"
                }
                self.normalizationReport = results.map {
                    "\($0.name):  \(value($0.beforeLUFS)) LUFS  |  \(value($0.beforePeak)) dBFS peak  |  \(String(format: "%+.1f", $0.gainDB)) dB  →  \(value($0.estimatedAfterLUFS)) LUFS / \(value($0.estimatedAfterPeak)) dBFS"
                }.joined(separator: "\n") + "\n\nNormalized copies saved in Music/Sculpt Normalized. Source files and live playback settings are unchanged. Save the Show to preserve the new references."
                self.normalizingCueID = nil
            } catch {
                self.normalizingCueID = nil
                self.normalizationReport = nil
                self.errorMessage = "Normalize Audio: \(error.localizedDescription)"
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
              playback.play(cue, restartPaused: true) else { return }
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
        return openShow(at: url)
    }

    /// Called by File > Open and by macOS onOpenURL when a .scshow is opened
    /// directly in Finder. The same decoder and unsaved-changes guard apply.
    @discardableResult
    func openShow(at url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "scshow" else {
            errorMessage = "Only Sculpt Show .scshow documents can be opened."
            return false
        }
        do {
            let next = try ShowCodec.decode(contentsOf: url)
            guard confirmDiscard() else { return false }
            cancelPendingRules()
            playingLists.removeAll()
            show = next
            documentURL = url
            selectedListID = next.cueLists.first?.id
            selectedCueID = next.cueLists.first?.cues.first(where: { $0.enabled })?.id
            dirty = false
            return true
        } catch {
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
                in: show, states: currentRuleStates(using: playback))
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
