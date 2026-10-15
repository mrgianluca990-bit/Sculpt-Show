import AVFAudio
import CoreAudio
import Foundation
import SculptShowCore

/// Timeline-based playback: one cue can own zero, one or several audio elements.
/// All elements of one cue are scheduled against the SAME output-device clock.
/// AVAudioPlayer.play(atTime:) synchronizes individual players on that device.
/// OUT points still use the UI timer; for sample-accurate edits/routing, the
/// planned AVAudioEngine-based show engine remains necessary.
@MainActor
final class PlaybackEngine: ObservableObject {
    enum Phase: String {
        case waiting = "WAITING"
        case playing = "PLAYING"
        case paused = "PAUSED"
        case fading = "FADING"
    }

    struct Snapshot {
        var phase: Phase
        var elapsed: TimeInterval
        var duration: TimeInterval
        var fraction: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
        var remaining: TimeInterval { max(duration - elapsed, 0) }
    }

    private struct AudioTrack {
        var elementID: UUID
        var player: AVAudioPlayer
        var start: Double
        var sourceIn: Double
        var sourceOut: Double
        var started: Bool = false
        var finished: Bool = false
    }

    @Published private(set) var snapshots: [UUID: Snapshot] = [:]
    @Published var errorMessage: String?
    var onNaturalFinish: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onStopped: ((UUID) -> Void)?
    /// Emits markers when the running playhead crosses them, in chronological order.
    var onMarkersReached: ((UUID, [UUID]) -> Void)?

    private var tracks: [UUID: [AudioTrack]] = [:]
    private var activeCues: [UUID: Cue] = [:]
    /// Last observed timeline position per cue. Reset on seek, restart and new GO.
    private var lastMarkerPosition: [UUID: Double] = [:]
    private var startedAt: [UUID: Date] = [:]
    private var elapsedAtStart: [UUID: Double] = [:]
    private var pendingTokens: [UUID: UUID] = [:]
    private var pendingDeadlines: [UUID: Date] = [:]
    private var fadeTokens: [UUID: UUID] = [:]
    private var dimFactors: [UUID: Float] = [:]
    private var durationCache: [String: Double] = [:]
    private var updateTimer: Timer?
    // Optional engine: does not run unless the operator enables hardware routing.
    private let routedAudio = RoutedAudioEngine()
    private var routedCues = Set<UUID>()
    private var routedFadeStarts: [UUID: (started: Date, seconds: Double)] = [:]
    @Published private(set) var routingEnabled = false
    @Published private(set) var routingDevices: [RoutedAudioEngine.OutputDevice] = []
    @Published private(set) var routingDeviceID: AudioDeviceID?
    /// Global, live-only output Mute/Solo state. Never serialized into a show.
    @Published private(set) var outputControls = OutputMuteSoloState(channelCount: 0)
    @Published private(set) var outputPeaks: [Float] = []
    @Published private(set) var outputRMS: [Float] = []
    private let preferredOutputUIDKey = "SculptShow.preferredCoreAudioOutputUID.v1"
    private var routingStartupAttempted = false

    func outputMeter(channel: Int) -> (peak: Float, rms: Float) {
        let index = channel - 1
        guard index >= 0, index < outputPeaks.count, index < outputRMS.count else { return (0, 0) }
        return (outputPeaks[index], outputRMS[index])
    }

    /// Prevent unattended playback with an unconfigured or wrong physical device.
    func startRoutingAutomatically() async {
        guard !routingStartupAttempted else { return }
        routingStartupAttempted = true
        refreshRoutingDevices()
        guard !routingDevices.isEmpty else {
            errorMessage = "No Core Audio output device is available. Open File → Audio/MIDI Setup and connect one."
            return
        }
        if let uid = UserDefaults.standard.string(forKey: preferredOutputUIDKey), !uid.isEmpty {
            guard let saved = routingDevices.first(where: { $0.uid == uid }) else {
                errorMessage = "The last selected audio interface is disconnected. Select it or another output in File → Audio/MIDI Setup. Audio GO remains disabled."
                return
            }
            await configureRouting(deviceID: saved.id)
        } else {
            let defaultID = RoutedAudioEngine.defaultOutputID()
            let device = routingDevices.first(where: { $0.id == defaultID }) ?? routingDevices[0]
            await configureRouting(deviceID: device.id)
        }
    }

    private func updateMeterLevels(peaks: [Float], rms: [Float]) {
        guard routingEnabled else { return }
        outputPeaks = peaks
        outputRMS = rms
    }
    var routingOutputCount: Int { routedAudio.selectedDevice?.channels ?? 0 }

    /// Output-level Mute/Solo goes directly to the MatrixMixer output gain.
    /// Changing these switches does not stop, restart or reschedule audio.
    func toggleOutputMute(_ channel: Int) {
        guard routingEnabled, outputControls.isValid(channel) else { return }
        var next = outputControls
        next.toggleMute(channel)
        applyOutputControls(next)
    }

    func toggleOutputSolo(_ channel: Int) {
        guard routingEnabled, outputControls.isValid(channel) else { return }
        var next = outputControls
        next.toggleSolo(channel)
        applyOutputControls(next)
    }

    func resetOutputMuteSolo() {
        guard routingEnabled else { return }
        var next = outputControls
        next.clear()
        applyOutputControls(next)
    }

    private func applyOutputControls(_ next: OutputMuteSoloState) {
        do {
            try routedAudio.applyOutputControls(next)
            outputControls = next
        } catch {
            errorMessage = "Cannot update output mute/solo: \(error.localizedDescription)"
        }
    }

    func refreshRoutingDevices() {
        routingDevices = RoutedAudioEngine.availableOutputs()
    }

    /// Never interrupts a show. Hardware-device changes require an idle transport.
    /// Normal crosspoint/output mixer edits do NOT reconfigure the engine.
    func configureRouting(deviceID: AudioDeviceID?) async {
        guard let deviceID else {
            errorMessage = "Routing is always enabled when an audio interface is available. Select a Core Audio output device."
            return
        }
        if routingEnabled, routingDeviceID == deviceID { return }
        guard snapshots.isEmpty else {
            errorMessage = "Cannot change audio interface while cues are active. The current audio keeps playing; stop the show before changing hardware."
            return
        }
        refreshRoutingDevices()
        guard let device = routingDevices.first(where: { $0.id == deviceID }) else {
            errorMessage = "Selected output device is not connected. Current routing was not changed."
            return
        }
        routedAudio.teardown()
        routingEnabled = false
        routingDeviceID = nil
        outputControls = OutputMuteSoloState(channelCount: 0)
        outputPeaks = []
        outputRMS = []
        routedAudio.onMeterSample = { [weak self] peaks, rms in
            self?.updateMeterLevels(peaks: peaks, rms: rms)
        }
        do {
            try await routedAudio.configure(device: device)
            let allAudible = OutputMuteSoloState(channelCount: device.channels)
            try routedAudio.applyOutputControls(allAudible)
            outputControls = allAudible
            outputPeaks = [Float](repeating: 0, count: device.channels)
            outputRMS = [Float](repeating: 0, count: device.channels)
            routingEnabled = true
            routingDeviceID = device.id
            if !device.uid.isEmpty {
                UserDefaults.standard.set(device.uid, forKey: preferredOutputUIDKey)
            }
        } catch {
            routedAudio.teardown()
            errorMessage = "Cannot initialize Core Audio output: \(error.localizedDescription). Audio GO stays disabled until setup succeeds."
        }
    }

    /// Repatch an active voice inside the matrix; it keeps playing continuously.
    /// Validates source channel count and output range before changing anything.
    @discardableResult
    func updateLiveElementOutput(_ elementID: UUID, for cueID: UUID,
                                 firstOutput: Int, sourcePath: String) -> Bool {
        guard routingEnabled else {
            errorMessage = "Audio routing is not ready. Select an interface in File → Audio/MIDI Setup."
            return false
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: sourcePath))
            let sourceChannels = Int(file.processingFormat.channelCount)
            guard AudioRoutePlan.crosspoints(firstOutput: firstOutput,
                sourceChannels: sourceChannels, deviceChannels: routingOutputCount) != nil else {
                errorMessage = "OUT \(firstOutput) is not valid for this \(sourceChannels)-channel file on a \(routingOutputCount)-channel device."
                return false
            }
            try routedAudio.changeOutput(cueID: cueID, elementID: elementID,
                                         firstOutput: firstOutput, sourceChannels: sourceChannels)
            if var cue = activeCues[cueID],
                let index = cue.elements.firstIndex(where: { $0.id == elementID }) {
                cue.elements[index].outputStartChannel = firstOutput
                activeCues[cueID] = cue
            }
            return true
        } catch {
            errorMessage = "Cannot change route while playing: \(error.localizedDescription)"
            return false
        }
    }

    /// Allow all prepared players to receive their play(atTime:) call before the
    /// device deadline. Every element uses the SAME deadline, not a per-file now.
    private func schedulingLead(for count: Int) -> TimeInterval {
        min(0.65, max(0.18, Double(count) * 0.012))
    }

    init() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func mediaDuration(for cue: Cue) -> Double? {
        guard let element = cue.audioElements.first else { return nil }
        return mediaDuration(at: element.sourcePath)
    }

    private func mediaDuration(at path: String) -> Double? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let cached = durationCache[path] { return cached }
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        durationCache[path] = player.duration
        return player.duration
    }

    @discardableResult
    func play(_ requestedCue: Cue, overrideFadeInSeconds: Double? = nil,
              from markerOffsetSeconds: Double = 0) -> Bool {
        guard requestedCue.enabled else { return false }
        // Show mode always requires an active Core Audio route for audio cues.
        // Never silently fall back to system stereo if the hardware is unavailable.
        if requestedCue.hasAudio && !routingEnabled {
            errorMessage = "Audio output is not ready. Open File → Audio/MIDI Setup and select a connected interface."
            return false
        }
        var cue = requestedCue
        if let overrideFadeInSeconds { cue.fadeInSeconds = max(0, min(600, overrideFadeInSeconds)) }
        guard pendingTokens[cue.id] == nil else { return false }
        if let snapshot = snapshots[cue.id] {
            if snapshot.phase == .paused { resume(cue.id); return true }
            return false
        }
        // Reject missing or unsupported media before even entering pre-wait.
        for element in cue.audioElements {
            guard mediaDuration(at: element.sourcePath) != nil else {
                errorMessage = "Cannot open ‘\(cue.name)’: \(element.name) is missing or unsupported."
                return false
            }
        }
        if cue.preWaitSeconds <= 0 { return playImmediately(cue, from: markerOffsetSeconds) }
        let token = UUID()
        pendingTokens[cue.id] = token
        pendingDeadlines[cue.id] = Date().addingTimeInterval(cue.preWaitSeconds)
        snapshots[cue.id] = Snapshot(phase: .waiting, elapsed: 0, duration: cue.preWaitSeconds)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cue.preWaitSeconds * 1_000_000_000))
            guard let self, self.pendingTokens[cue.id] == token else { return }
            self.pendingTokens.removeValue(forKey: cue.id)
            self.pendingDeadlines.removeValue(forKey: cue.id)
            self.snapshots.removeValue(forKey: cue.id)
            _ = self.playImmediately(cue, from: markerOffsetSeconds)
        }
        return true
    }

    /// Hardware-mapped cue: playback occurs in one AVAudioEngine with one host clock.
    /// Failure is visible and does not fall back to stereo outputs 1/2.
    private func playRouted(_ cue: Cue, from requestedPosition: Double = 0) -> Bool {
        do {
            var audioEnds: [Double] = []
            for element in cue.alignedAudioElements {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: element.sourcePath))
                audioEnds.append(Double(file.length) / file.processingFormat.sampleRate)
            }
            let length = cue.timelineLength(audioEnds: audioEnds)
            guard length > 0.001 else {
                errorMessage = "Cue ‘\(cue.name)’ has zero duration."
                return false
            }
            let position = min(max(0, requestedPosition), max(0, length - 0.001))
            let lead = try routedAudio.start(cue, from: position,
                fade: cue.fadeInSeconds > 0 ? 0 : 1)
            routedCues.insert(cue.id)
            activeCues[cue.id] = cue
            tracks[cue.id] = []
            elapsedAtStart[cue.id] = position
            lastMarkerPosition[cue.id] = position > 0 ? position : -0.0001
            startedAt[cue.id] = Date().addingTimeInterval(lead)
            snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: length)
            onStarted?(cue.id)
            return true
        } catch {
            errorMessage = "Routed playback failed for ‘\(cue.name)’: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func playImmediately(_ cue: Cue, from requestedPosition: Double = 0) -> Bool {
        if routingEnabled && cue.hasAudio { return playRouted(cue, from: requestedPosition) }
        var prepared: [AudioTrack] = []
        do {
            for element in cue.alignedAudioElements {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: element.sourcePath))
                guard player.duration > 0.001 else {
                    errorMessage = "Audio source ‘\(element.name)’ is empty."
                    return false
                }
                // Every stem plays from sample zero at the same device deadline.
                // Its effective OUT is the earlier of source end or cue end.
                player.numberOfLoops = 0 // The *container*, not each file, controls looping.
                player.currentTime = 0
                player.volume = cue.fadeInSeconds > 0 || element.muted ? 0 : Float(cue.gain * element.gain)
                player.prepareToPlay()
                prepared.append(AudioTrack(elementID: element.id, player: player,
                    start: 0, sourceIn: 0, sourceOut: player.duration))
            }
        } catch {
            errorMessage = "Cannot prepare audio for ‘\(cue.name)’: \(error.localizedDescription)"
            return false
        }
        let ends = prepared.map { $0.start + ($0.sourceOut - $0.sourceIn) }
        let length = cue.timelineLength(audioEnds: ends)
        guard length > 0.001 else {
            errorMessage = "Cue ‘\(cue.name)’ has zero duration. Set a container length."
            return false
        }
        let position = min(max(0, requestedPosition), max(0, length - 0.001))
        activeCues[cue.id] = cue
        tracks[cue.id] = prepared
        elapsedAtStart[cue.id] = position
        lastMarkerPosition[cue.id] = position > 0 ? position : -0.0001
        snapshots[cue.id] = Snapshot(phase: .playing, elapsed: position, duration: length)
        armAudio(for: cue.id, from: position)
        onStarted?(cue.id)
        return true
    }

    private func cueElapsed(_ id: UUID) -> Double {
        let base = elapsedAtStart[id] ?? 0
        return max(0, base + (startedAt[id].map { Date().timeIntervalSince($0) } ?? 0))
    }

    private func playerGain(_ id: UUID) -> Float {
        Float(activeCues[id]?.gain ?? 1) * (dimFactors[id] ?? 1)
    }

    /// Combine the cue-level gain and dim with this element's individual fader/mute.
    private func trackGain(_ cueID: UUID, elementID: UUID) -> Float {
        guard let element = activeCues[cueID]?.elements.first(where: { $0.id == elementID }),
              !element.muted else { return 0 }
        return playerGain(cueID) * Float(element.gain)
    }

    /// Change an individual element live, without stopping or re-scheduling any player.
    func setElementMix(_ elementID: UUID, for cueID: UUID,
                       gain: Double? = nil, muted: Bool? = nil) {
        guard var cue = activeCues[cueID],
              let index = cue.elements.firstIndex(where: { $0.id == elementID && $0.kind == .audio }) else { return }
        if let gain { cue.elements[index].gain = gain.isFinite ? min(max(gain, 0), 1) : 1 }
        if let muted { cue.elements[index].muted = muted }
        activeCues[cueID] = cue
        if snapshots[cueID]?.phase == .playing {
            refreshAudio(for: cueID, elapsed: cueElapsed(cueID))
        }
    }

    /// Schedule the ENTIRE cue at once using one AVAudioPlayer device timestamp.
    /// All audio stems share the same scheduled start (device clock).
    /// Never start individual stems from the UI refresh timer.
    private func armAudio(for id: UUID, from elapsed: Double, leadOverride: Double? = nil) {
        if routedCues.contains(id), let cue = activeCues[id] {
            do {
                let lead = try routedAudio.start(cue, from: elapsed,
                    fade: cue.fadeInSeconds > 0 ? 0 : 1,
                    hostLead: leadOverride ?? 0.22)
                elapsedAtStart[id] = elapsed
                startedAt[id] = Date().addingTimeInterval(lead)
            } catch {
                errorMessage = "Cannot re-arm routed cue: \(error.localizedDescription)"
                stop(id, notifyRules: false)
            }
            return
        }
        guard var list = tracks[id], let cue = activeCues[id] else { return }
        // Empty containers keep their existing immediate timeline behavior.
        guard !list.isEmpty else {
            elapsedAtStart[id] = elapsed
            startedAt[id] = Date()
            return
        }

        // First cancel ALL previously queued starts before reading the device
        // clock. When its last player stops, the output clock may reset to zero.
        for index in list.indices {
            list[index].player.stop()
            list[index].started = false
            list[index].finished = false
        }

        // Single-file cues start immediately unless they need a timed offset.
        // Multiple files must share a future device deadline for alignment.
        let lead = leadOverride ?? (list.count > 1 ? schedulingLead(for: list.count) : 0)
        var instructions: [(Int, AudioStartInstruction)] = []
        for index in list.indices {
            let track = list[index]
            guard let instruction = AudioStartPlanner.instruction(
                elementOffset: track.start,
                sourceIn: track.sourceIn,
                sourceOut: track.sourceOut,
                cuePosition: elapsed
            ) else {
                list[index].finished = true
                continue
            }
            track.player.currentTime = instruction.positionInFile
            track.player.volume = cue.fadeInSeconds > 0 ? 0 : trackGain(id, elementID: track.elementID)
            if track.player.prepareToPlay() {
                instructions.append((index, instruction))
            } else {
                errorMessage = "Cannot prepare synchronized audio ‘\(cue.name)’ (element \(index + 1))."
            }
        }

        // Read device time only AFTER cancelling/repreparing all players.
        // Every schedule is measured against this one immutable timestamp.
        let anchor = (list.first?.player.deviceCurrentTime ?? 0) + lead
        let wallClockAnchor = Date().addingTimeInterval(lead)
        elapsedAtStart[id] = elapsed
        startedAt[id] = wallClockAnchor
        for (index, instruction) in instructions {
            let player = list[index].player
            let success: Bool
            if lead == 0 && instruction.delayFromCueAnchor == 0 && list.count == 1 {
                success = player.play()
            } else {
                success = player.play(atTime: anchor + instruction.delayFromCueAnchor)
            }
            list[index].started = success
            if !success {
                errorMessage = "Cannot schedule audio ‘\(cue.name)’ (element \(index + 1))."
            }
        }
        tracks[id] = list
    }

    /// Poll only for stopping at OUT and for fade/gain envelopes. Never start an
    /// audio player from the timer: that caused the multitrack misalignment.
    private func refreshAudio(for id: UUID, elapsed: Double) {
        if routedCues.contains(id), let cue = activeCues[id] {
            let fade = max(0, cue.fadeInSeconds)
            let fadeInFactor = fade > 0 ? Float(min(1, max(0, elapsed / fade))) : 1
            var fadeOutFactor: Float = 1
            if let data = routedFadeStarts[id] {
                let elapsedFade = Date().timeIntervalSince(data.started)
                fadeOutFactor = Float(max(0, 1 - elapsedFade / max(0.001, data.seconds)))
            }
            routedAudio.updateMix(cue, fadeFactor: fadeInFactor * fadeOutFactor,
                                  dimFactor: dimFactors[id] ?? 1)
            return
        }
        guard var list = tracks[id], let cue = activeCues[id] else { return }
        for index in list.indices where list[index].started && !list[index].finished {
            let local = elapsed - list[index].start
            let length = list[index].sourceOut - list[index].sourceIn
            if local >= length {
                list[index].player.stop()
                list[index].started = false
                list[index].finished = true
                continue
            }
            // Apply fade-in relative to each element's timeline position.
            // Do not prematurely fade an element before its scheduled offset.
            let fade = max(0, cue.fadeInSeconds)
            let fadeFactor = fade > 0 ? min(1, max(0, local / fade)) : 1
            list[index].player.volume = trackGain(id, elementID: list[index].elementID) * Float(fadeFactor)
        }
        tracks[id] = list
    }

    private func resume(_ id: UUID) {
        guard snapshots[id]?.phase == .paused else { return }
        let position = elapsedAtStart[id] ?? 0
        snapshots[id]?.phase = .playing
        armAudio(for: id, from: position)
    }

    func togglePause(_ id: UUID) {
        guard let snapshot = snapshots[id] else { return }
        switch snapshot.phase {
        case .paused: resume(id)
        case .playing: pause(id)
        case .waiting, .fading: break
        }
    }

    func pause(_ id: UUID) {
        guard snapshots[id]?.phase == .playing else { return }
        let elapsed = cueElapsed(id)
        elapsedAtStart[id] = elapsed
        startedAt.removeValue(forKey: id)
        // Cancel even a future scheduled start: a player may not be audible yet.
        if routedCues.contains(id) { routedAudio.stop(id) }
        for track in tracks[id] ?? [] { track.player.stop() }
        snapshots[id]?.phase = .paused
        snapshots[id]?.elapsed = elapsed
    }

    func stop(_ id: UUID, notifyRules: Bool = true) {
        let previous = snapshots[id]
        pendingTokens.removeValue(forKey: id)
        pendingDeadlines.removeValue(forKey: id)
        fadeTokens.removeValue(forKey: id)
        routedFadeStarts.removeValue(forKey: id)
        if routedCues.remove(id) != nil { routedAudio.stop(id) }
        for track in tracks[id] ?? [] { track.player.stop() }
        tracks.removeValue(forKey: id)
        activeCues.removeValue(forKey: id)
        lastMarkerPosition.removeValue(forKey: id)
        startedAt.removeValue(forKey: id)
        elapsedAtStart.removeValue(forKey: id)
        dimFactors.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        if previous != nil && previous?.phase != .fading && notifyRules { onStopped?(id) }
    }

    func fadeOut(_ cue: Cue, overrideSeconds: Double? = nil) {
        guard let state = snapshots[cue.id] else { return }
        if state.phase == .waiting { stop(cue.id); return }
        guard state.phase != .fading else { return }
        let seconds = overrideSeconds.map { max(0, min($0, 600)) } ?? cue.fadeOutSeconds
        guard seconds > 0, !(tracks[cue.id] ?? []).isEmpty || routedCues.contains(cue.id) else { stop(cue.id); return }
        let token = UUID()
        fadeTokens[cue.id] = token
        snapshots[cue.id]?.phase = .fading
        onStopped?(cue.id)
        if routedCues.contains(cue.id) {
            routedFadeStarts[cue.id] = (Date(), seconds)
        }
        for track in tracks[cue.id] ?? [] where track.started {
            if track.player.isPlaying {
                track.player.setVolume(0, fadeDuration: seconds)
            } else {
                // Do not let a future element start during the stop/fade.
                track.player.stop()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.fadeTokens[cue.id] == token else { return }
            self.stop(cue.id, notifyRules: false)
        }
    }

    func setGain(_ gain: Double, for cueID: UUID) {
        guard snapshots[cueID]?.phase != .fading else { return }
        activeCues[cueID]?.gain = min(max(gain, 0), 1)
        // Preserve any ongoing fade-in instead of jumping to the final gain.
        if let state = snapshots[cueID], state.phase == .playing {
            refreshAudio(for: cueID, elapsed: cueElapsed(cueID))
        }
    }

    func dim(_ id: UUID, by decibels: Double) {
        dimFactors[id] = Float(pow(10.0, max(-80, min(decibels, 0)) / 20.0))
        if let state = snapshots[id], state.phase == .playing {
            refreshAudio(for: id, elapsed: cueElapsed(id))
        }
    }

    func restoreGain(_ id: UUID) {
        dimFactors.removeValue(forKey: id)
        if let state = snapshots[id], state.phase == .playing {
            refreshAudio(for: id, elapsed: cueElapsed(id))
        }
    }

    func seek(_ id: UUID, to fraction: Double) {
        guard let state = snapshots[id] else { return }
        seek(id, toSeconds: min(max(fraction, 0), 0.9999) * state.duration)
    }

    /// Jump directly to a marker or timeline position, without firing skipped markers.
    /// Routed AVAudioEngine voices are re-armed against one host clock.
    func seek(_ id: UUID, toSeconds seconds: Double) {
        guard let state = snapshots[id], state.phase != .waiting, state.phase != .fading,
              seconds.isFinite else { return }
        let position = min(max(seconds, 0), max(0, state.duration - 0.001))
        elapsedAtStart[id] = position
        lastMarkerPosition[id] = position
        snapshots[id]?.elapsed = position
        if state.phase == .playing {
            armAudio(for: id, from: position)
        } else {
            if routedCues.contains(id) { routedAudio.stop(id) }
            for track in tracks[id] ?? [] { track.player.stop() }
        }
    }

    private func emitCrossedMarkers(_ id: UUID, at elapsed: Double, duration: Double) {
        guard let cue = activeCues[id], !cue.markers.isEmpty else { return }
        let previous = lastMarkerPosition[id] ?? elapsed
        let reached = MarkerPlanner.crossed(cue.markers, from: previous,
                                            to: min(elapsed, duration), duration: duration)
        lastMarkerPosition[id] = min(elapsed, duration)
        if !reached.isEmpty { onMarkersReached?(id, reached.map(\.id)) }
    }

    /// Allow live editing of cue markers without rebuilding the audio graph.
    func updateMarkers(_ markers: [CueMarker], for id: UUID) {
        activeCues[id]?.markers = markers
        if lastMarkerPosition[id] == nil, activeCues[id] != nil {
            lastMarkerPosition[id] = snapshots[id]?.elapsed ?? 0
        }
    }

    func setLoop(_ enabled: Bool, for id: UUID) { activeCues[id]?.loop = enabled }

    func stopAll() {
        for id in Array(snapshots.keys) { stop(id, notifyRules: false) }
    }

    private func finishNaturally(_ id: UUID) {
        stop(id, notifyRules: false)
        onNaturalFinish?(id)
    }

    private func refresh() {
        for (id, deadline) in pendingDeadlines {
            guard var state = snapshots[id], state.phase == .waiting else { continue }
            state.elapsed = min(max(state.duration - deadline.timeIntervalSinceNow, 0), state.duration)
            snapshots[id] = state
        }
        for id in Array(activeCues.keys) {
            guard var snapshot = snapshots[id], snapshot.phase == .playing || snapshot.phase == .fading else { continue }
            let elapsed = cueElapsed(id)
            // Fade-outs may intentionally extend past the cue's nominal length.
            // Keep updating routed gain until the fade task stops the voice.
            if snapshot.phase == .fading {
                snapshot.elapsed = min(snapshot.duration, elapsed)
                snapshots[id] = snapshot
                if routedCues.contains(id) { refreshAudio(for: id, elapsed: elapsed) }
                continue
            }
            // Catch markers crossed since the previous UI tick, including near END.
            emitCrossedMarkers(id, at: elapsed, duration: snapshot.duration)
            if elapsed >= snapshot.duration {
                if activeCues[id]?.loop == true && snapshot.phase == .playing {
                    snapshot.elapsed = 0
                    snapshots[id] = snapshot
                    lastMarkerPosition[id] = -0.0001
                    // Loop re-arms together on the device clock. This is not
                    // yet a gapless loop: that requires the next engine stage.
                    armAudio(for: id, from: 0, leadOverride: 0.08)
                } else if snapshot.phase == .playing {
                    finishNaturally(id)
                }
                continue
            }
            snapshot.elapsed = elapsed
            snapshots[id] = snapshot
            if snapshot.phase == .playing || routedCues.contains(id) { refreshAudio(for: id, elapsed: elapsed) }
        }
    }
}
