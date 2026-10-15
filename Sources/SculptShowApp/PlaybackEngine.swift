import AVFAudio
import Foundation
import SculptShowCore

/// Timeline-based playback: one cue can own zero, one or several audio elements.
/// AVAudioPlayer is retained for 0.6 compatibility; starts are not sample-accurate.
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

    private var tracks: [UUID: [AudioTrack]] = [:]
    private var activeCues: [UUID: Cue] = [:]
    private var startedAt: [UUID: Date] = [:]
    private var elapsedAtStart: [UUID: Double] = [:]
    private var pendingTokens: [UUID: UUID] = [:]
    private var pendingDeadlines: [UUID: Date] = [:]
    private var fadeTokens: [UUID: UUID] = [:]
    private var dimFactors: [UUID: Float] = [:]
    private var durationCache: [String: Double] = [:]
    private var updateTimer: Timer?

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
    func play(_ requestedCue: Cue, overrideFadeInSeconds: Double? = nil) -> Bool {
        guard requestedCue.enabled else { return false }
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
        if cue.preWaitSeconds <= 0 { return playImmediately(cue) }
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
            _ = self.playImmediately(cue)
        }
        return true
    }

    @discardableResult
    private func playImmediately(_ cue: Cue) -> Bool {
        var prepared: [AudioTrack] = []
        do {
            for element in cue.audioElements {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: element.sourcePath))
                let start = min(max(element.inSeconds, 0), player.duration)
                let end = max(start, min(element.outSeconds ?? player.duration, player.duration))
                guard end > start + 0.001 else {
                    errorMessage = "Invalid IN/OUT region in ‘\(element.name)’ of cue ‘\(cue.name)’."
                    return false
                }
                player.numberOfLoops = 0 // The *container*, not each file, controls looping.
                player.currentTime = start
                player.volume = cue.fadeInSeconds > 0 ? 0 : Float(cue.gain)
                player.prepareToPlay()
                prepared.append(AudioTrack(elementID: element.id, player: player,
                    start: max(0, element.startSeconds), sourceIn: start, sourceOut: end))
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
        activeCues[cue.id] = cue
        tracks[cue.id] = prepared
        elapsedAtStart[cue.id] = 0
        startedAt[cue.id] = Date()
        snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: length)
        synchronizeAudio(for: cue.id, elapsed: 0, restart: false)
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

    /// Start due elements; stop an element at its OUT even if the cue continues.
    private func synchronizeAudio(for id: UUID, elapsed: Double, restart: Bool) {
        guard var list = tracks[id], let snapshot = snapshots[id] else { return }
        let playing = snapshot.phase == .playing
        let gain = playerGain(id)
        for i in list.indices {
            let trackDuration = list[i].sourceOut - list[i].sourceIn
            let local = elapsed - list[i].start
            if restart {
                list[i].player.stop()
                list[i].started = false
                list[i].finished = false
            }
            if local < 0 || local >= trackDuration {
                if list[i].started {
                    list[i].player.stop()
                    list[i].started = false
                }
                if local >= trackDuration { list[i].finished = true }
                continue
            }
            if !list[i].started && !list[i].finished {
                list[i].player.currentTime = list[i].sourceIn + local
                let fade = max(0, activeCues[id]?.fadeInSeconds ?? 0)
                list[i].player.volume = fade > 0 ? 0 : gain
                if playing {
                    list[i].started = list[i].player.play()
                    if list[i].started && fade > 0 {
                        list[i].player.setVolume(gain, fadeDuration: fade)
                    }
                } else { list[i].started = true }
            } else if playing && list[i].started && !list[i].player.isPlaying {
                // A media element can end before its containing cue. Never replay it.
                if list[i].player.currentTime >= list[i].sourceOut - 0.03 {
                    list[i].finished = true
                    list[i].started = false
                } else {
                    _ = list[i].player.play() // Resume after Pause.
                }
            }
            if list[i].started && list[i].player.currentTime >= list[i].sourceOut - 0.005 {
                list[i].player.stop()
                list[i].started = false
                list[i].finished = true
            }
        }
        tracks[id] = list
    }

    private func resume(_ id: UUID) {
        guard snapshots[id]?.phase == .paused else { return }
        startedAt[id] = Date()
        snapshots[id]?.phase = .playing
        synchronizeAudio(for: id, elapsed: cueElapsed(id), restart: false)
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
        for track in tracks[id] ?? [] where track.started { track.player.pause() }
        snapshots[id]?.phase = .paused
        snapshots[id]?.elapsed = elapsed
    }

    func stop(_ id: UUID, notifyRules: Bool = true) {
        let previous = snapshots[id]
        pendingTokens.removeValue(forKey: id)
        pendingDeadlines.removeValue(forKey: id)
        fadeTokens.removeValue(forKey: id)
        for track in tracks[id] ?? [] { track.player.stop() }
        tracks.removeValue(forKey: id)
        activeCues.removeValue(forKey: id)
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
        guard seconds > 0, !(tracks[cue.id] ?? []).isEmpty else { stop(cue.id); return }
        let token = UUID()
        fadeTokens[cue.id] = token
        snapshots[cue.id]?.phase = .fading
        onStopped?(cue.id)
        for track in tracks[cue.id] ?? [] where track.started {
            track.player.setVolume(0, fadeDuration: seconds)
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
        for track in tracks[cueID] ?? [] { track.player.volume = playerGain(cueID) }
    }

    func dim(_ id: UUID, by decibels: Double) {
        dimFactors[id] = Float(pow(10.0, max(-80, min(decibels, 0)) / 20.0))
        for track in tracks[id] ?? [] { track.player.setVolume(playerGain(id), fadeDuration: 0.15) }
    }

    func restoreGain(_ id: UUID) {
        dimFactors.removeValue(forKey: id)
        for track in tracks[id] ?? [] { track.player.setVolume(playerGain(id), fadeDuration: 0.15) }
    }

    func seek(_ id: UUID, to fraction: Double) {
        guard let state = snapshots[id], state.phase != .waiting, state.phase != .fading else { return }
        let position = min(max(fraction, 0), 0.9999) * state.duration
        elapsedAtStart[id] = position
        if startedAt[id] != nil { startedAt[id] = Date() }
        snapshots[id]?.elapsed = position
        synchronizeAudio(for: id, elapsed: position, restart: true)
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
            if elapsed >= snapshot.duration {
                if activeCues[id]?.loop == true && snapshot.phase == .playing {
                    elapsedAtStart[id] = 0
                    startedAt[id] = Date()
                    snapshot.elapsed = 0
                    snapshots[id] = snapshot
                    synchronizeAudio(for: id, elapsed: 0, restart: true)
                } else if snapshot.phase == .playing {
                    finishNaturally(id)
                }
                continue
            }
            snapshot.elapsed = elapsed
            snapshots[id] = snapshot
            if snapshot.phase == .playing { synchronizeAudio(for: id, elapsed: elapsed, restart: false) }
        }
    }
}
