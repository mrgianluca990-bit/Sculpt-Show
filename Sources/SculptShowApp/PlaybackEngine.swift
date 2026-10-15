import AVFAudio
import Foundation
import SculptShowCore

private final class AudioFinishDelegate: NSObject, AVAudioPlayerDelegate {
    var didFinish: ((Bool) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish?(flag)
    }
}

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

    @Published private(set) var snapshots: [UUID: Snapshot] = [:]
    @Published var errorMessage: String?
    /// Invoked only when non-looping audio reaches its natural end.
    var onNaturalFinish: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onStopped: ((UUID) -> Void)?
    private var players: [UUID: AVAudioPlayer] = [:]
    /// Pending pre-wait starts are tracked separately from audio players.
    /// Removing a token makes the delayed task harmless after STOP / STOP ALL.
    private var pendingTokens: [UUID: UUID] = [:]
    private var pendingDeadlines: [UUID: Date] = [:]
    private var finishDelegates: [UUID: AudioFinishDelegate] = [:]
    private var cueGains: [UUID: Float] = [:]
    private var dimFactors: [UUID: Float] = [:]
    private var fadeTokens: [UUID: UUID] = [:]
    private var updateTimer: Timer?
    private var clipWindows: [UUID: (start: Double, end: Double)] = [:]
    private var activeLoops: [UUID: Bool] = [:]
    private var silentStartedAt: [UUID: Date] = [:]
    private var silentElapsedAtStart: [UUID: Double] = [:]
    private var silentLoopIDs: Set<UUID> = []
    private var durationCache: [String: Double] = [:]

    func mediaDuration(for cue: Cue) -> Double? {
        guard !cue.isEmpty, FileManager.default.fileExists(atPath: cue.mediaPath) else { return nil }
        if let cached = durationCache[cue.mediaPath] { return cached }
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: cue.mediaPath)) else { return nil }
        durationCache[cue.mediaPath] = player.duration
        return player.duration
    }

    init() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @discardableResult
    func play(_ cue: Cue, overrideFadeInSeconds: Double? = nil) -> Bool {
        guard cue.enabled else { return false }
        var cue = cue
        if let overrideFadeInSeconds { cue.fadeInSeconds = max(0, min(600, overrideFadeInSeconds)) }
        // Already queued or playing cues never receive a duplicate start.
        guard pendingTokens[cue.id] == nil else { return false }
        if cue.isEmpty, let state = snapshots[cue.id] {
            if state.phase == .paused {
                resumeSilent(cue.id)
                return true
            }
            return false
        }
        // A repeated GO on a paused cue resumes it. A running cue does not restart.
        if let player = players[cue.id] {
            if snapshots[cue.id]?.phase == .paused {
                fadeTokens.removeValue(forKey: cue.id)
                player.setVolume((cueGains[cue.id] ?? Float(cue.gain)) * (dimFactors[cue.id] ?? 1), fadeDuration: 0)
                player.play()
                snapshots[cue.id]?.phase = .playing
                return true
            }
            return false
        }
        // Reject missing files before creating a countdown.
        guard cue.isEmpty || FileManager.default.fileExists(atPath: cue.mediaPath) else {
            errorMessage = "Cannot open ‘\(cue.name)’: media file is missing."
            return false
        }
        guard cue.preWaitSeconds > 0 else { return playImmediately(cue) }
        let cueID = cue.id
        let token = UUID()
        pendingTokens[cueID] = token
        pendingDeadlines[cueID] = Date().addingTimeInterval(cue.preWaitSeconds)
        snapshots[cueID] = Snapshot(phase: .waiting, elapsed: 0, duration: cue.preWaitSeconds)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cue.preWaitSeconds * 1_000_000_000))
            guard let self, self.pendingTokens[cueID] == token else { return }
            self.pendingTokens.removeValue(forKey: cueID)
            self.pendingDeadlines.removeValue(forKey: cueID)
            self.snapshots.removeValue(forKey: cueID)
            _ = self.playImmediately(cue)
        }
        return true
    }

    @discardableResult
    private func playImmediately(_ cue: Cue) -> Bool {
        if cue.isEmpty {
            let length = cue.playbackWindow(sourceDuration: 0).duration
            silentElapsedAtStart[cue.id] = 0
            silentStartedAt[cue.id] = Date()
            if cue.loop { silentLoopIDs.insert(cue.id) }
            else { silentLoopIDs.remove(cue.id) }
            snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: length)
            onStarted?(cue.id)
            return true
        }
        do {
            let url = URL(fileURLWithPath: cue.mediaPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            let region = cue.playbackWindow(sourceDuration: player.duration)
            guard region.duration > 0.001 else {
                errorMessage = "The IN/OUT region for ‘\(cue.name)’ is empty. Adjust its trim points."
                return false
            }
            let delegate = AudioFinishDelegate()
            delegate.didFinish = { [weak self, cueID = cue.id] didSucceed in
                Task { @MainActor [weak self] in
                    self?.handleCompletion(cueID, success: didSucceed)
                }
            }
            player.delegate = delegate
            finishDelegates[cue.id] = delegate
            let fullFile = region.start <= 0.001 && region.end >= player.duration - 0.001
            player.numberOfLoops = (cue.loop && fullFile) ? -1 : 0
            player.volume = cue.fadeInSeconds > 0 ? 0 : Float(cue.gain)
            player.prepareToPlay()
            player.currentTime = region.start
            guard player.play() else {
                finishDelegates.removeValue(forKey: cue.id)
                errorMessage = "Could not start audio playback for \(cue.name)."
                return false
            }
            if cue.fadeInSeconds > 0 {
                player.setVolume(Float(cue.gain), fadeDuration: cue.fadeInSeconds)
            }
            players[cue.id] = player
            clipWindows[cue.id] = (region.start, region.end)
            activeLoops[cue.id] = cue.loop
            cueGains[cue.id] = Float(cue.gain)
            snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: region.duration)
            onStarted?(cue.id)
            return true
        } catch {
            errorMessage = "Cannot open ‘\(cue.name)’: \(error.localizedDescription)"
            return false
        }
    }

    func togglePause(_ id: UUID) {
        guard let current = snapshots[id] else { return }
        if silentElapsedAtStart[id] != nil {
            switch current.phase {
            case .playing: pauseSilent(id)
            case .paused: resumeSilent(id)
            case .waiting, .fading: break
            }
            return
        }
        guard let player = players[id] else { return }
        switch current.phase {
        case .waiting:
            return
        case .paused:
            fadeTokens.removeValue(forKey: id)
            player.setVolume((cueGains[id] ?? 1) * (dimFactors[id] ?? 1), fadeDuration: 0)
            player.play()
            snapshots[id]?.phase = .playing
        case .playing, .fading:
            fadeTokens.removeValue(forKey: id)
            player.pause()
            snapshots[id]?.phase = .paused
        }
    }

    func pause(_ id: UUID) {
        guard let state = snapshots[id], state.phase == .playing else { return }
        if silentElapsedAtStart[id] != nil { pauseSilent(id); return }
        guard let player = players[id] else { return }
        player.pause()
        snapshots[id]?.phase = .paused
    }

    private func pauseSilent(_ id: UUID) {
        guard let start = silentStartedAt[id], let base = silentElapsedAtStart[id] else { return }
        let elapsed = min(base + Date().timeIntervalSince(start), snapshots[id]?.duration ?? 0)
        silentElapsedAtStart[id] = elapsed
        silentStartedAt.removeValue(forKey: id)
        snapshots[id]?.elapsed = elapsed
        snapshots[id]?.phase = .paused
    }

    private func resumeSilent(_ id: UUID) {
        guard silentElapsedAtStart[id] != nil else { return }
        silentStartedAt[id] = Date()
        snapshots[id]?.phase = .playing
    }

    func stop(_ id: UUID, notifyRules: Bool = true) {
        let wasActive = snapshots[id] != nil
        let alreadyFading = snapshots[id]?.phase == .fading
        pendingTokens.removeValue(forKey: id)
        pendingDeadlines.removeValue(forKey: id)
        fadeTokens.removeValue(forKey: id)
        players[id]?.stop()
        players.removeValue(forKey: id)
        clipWindows.removeValue(forKey: id)
        activeLoops.removeValue(forKey: id)
        silentStartedAt.removeValue(forKey: id)
        silentElapsedAtStart.removeValue(forKey: id)
        silentLoopIDs.remove(id)
        finishDelegates.removeValue(forKey: id)
        cueGains.removeValue(forKey: id)
        dimFactors.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        if wasActive && notifyRules && !alreadyFading { onStopped?(id) }
    }

    func fadeOut(_ cue: Cue, overrideSeconds: Double? = nil) {
        // A queued cue has not produced audio, so Fade behaves as cancel.
        if pendingTokens[cue.id] != nil { stop(cue.id); return }
        if cue.isEmpty { stop(cue.id); return }
        guard let player = players[cue.id] else { return }
        let seconds = overrideSeconds.map { max(0, min($0, 600)) } ?? cue.fadeOutSeconds
        guard seconds > 0 else { stop(cue.id); return }
        guard snapshots[cue.id]?.phase != .fading else { return }
        let token = UUID()
        fadeTokens[cue.id] = token
        snapshots[cue.id]?.phase = .fading
        onStopped?(cue.id)
        player.setVolume(0, fadeDuration: seconds)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let player, self.fadeTokens[cue.id] == token,
                  self.players[cue.id] === player else { return }
            self.stop(cue.id, notifyRules: false)
        }
    }

    func setGain(_ gain: Double, for cueID: UUID) {
        guard snapshots[cueID]?.phase != .fading else { return }
        cueGains[cueID] = Float(gain)
        players[cueID]?.volume = Float(gain) * (dimFactors[cueID] ?? 1)
    }

    func dim(_ id: UUID, by decibels: Double) {
        guard let player = players[id], snapshots[id]?.phase != .fading else { return }
        let bounded = max(-80, min(0, decibels))
        let factor = Float(pow(10.0, bounded / 20.0))
        dimFactors[id] = factor
        player.setVolume((cueGains[id] ?? 1) * factor, fadeDuration: 0.15)
    }

    func restoreGain(_ id: UUID) {
        dimFactors.removeValue(forKey: id)
        guard snapshots[id]?.phase != .fading else { return }
        players[id]?.setVolume(cueGains[id] ?? 1, fadeDuration: 0.15)
    }

    func seek(_ id: UUID, to fraction: Double) {
        guard let state = snapshots[id], state.phase != .fading, state.phase != .waiting else { return }
        let position = min(max(fraction, 0), 0.9999) * state.duration
        if silentElapsedAtStart[id] != nil {
            silentElapsedAtStart[id] = position
            if silentStartedAt[id] != nil { silentStartedAt[id] = Date() }
            snapshots[id]?.elapsed = position
            return
        }
        guard let player = players[id], let region = clipWindows[id] else { return }
        player.currentTime = region.start + position
        snapshots[id]?.elapsed = position
    }

    func setLoop(_ enabled: Bool, for id: UUID) {
        if silentElapsedAtStart[id] != nil {
            if enabled { silentLoopIDs.insert(id) } else { silentLoopIDs.remove(id) }
        }
        activeLoops[id] = enabled
        if let player = players[id], let region = clipWindows[id] {
            let fullFile = region.start <= 0.001 && region.end >= player.duration - 0.001
            player.numberOfLoops = (enabled && fullFile) ? -1 : 0
        }
    }

    func stopAll() {
        for id in Array(snapshots.keys) { stop(id, notifyRules: false) }
    }

    private func handleCompletion(_ id: UUID, success: Bool) {
        guard let player = players[id], snapshots[id]?.phase == .playing else { return }
        if success, activeLoops[id] == true, let region = clipWindows[id] {
            player.currentTime = region.start
            if player.play() {
                snapshots[id]?.elapsed = 0
                return
            }
        }
        finishNaturally(id, success: success)
    }

    private func finishNaturally(_ id: UUID, success: Bool = true) {
        stop(id, notifyRules: false)
        if success { onNaturalFinish?(id) }
        else { errorMessage = "Audio playback could not finish successfully." }
    }

    private func refresh() {
        for (id, deadline) in pendingDeadlines {
            guard var state = snapshots[id], state.phase == .waiting else { continue }
            state.elapsed = min(max(state.duration - deadline.timeIntervalSinceNow, 0), state.duration)
            snapshots[id] = state
        }
        for (id, player) in players {
            guard var state = snapshots[id], let region = clipWindows[id] else { continue }
            if state.phase != .paused && !player.isPlaying {
                // Natural EOF is delivered by AVAudioPlayerDelegate.
                if state.phase == .fading { stop(id, notifyRules: false) }
                continue
            }
            // Check OUT while playing: the original audio file is never modified.
            if state.phase == .playing && player.currentTime >= region.end - 0.005 {
                if activeLoops[id] == true {
                    player.currentTime = region.start
                    if !player.isPlaying { _ = player.play() }
                    state.elapsed = 0
                    snapshots[id] = state
                } else {
                    finishNaturally(id)
                }
                continue
            }
            state.elapsed = min(max(player.currentTime - region.start, 0), state.duration)
            snapshots[id] = state
        }
        for id in Array(silentStartedAt.keys) {
            guard let started = silentStartedAt[id], let base = silentElapsedAtStart[id],
                  var state = snapshots[id], state.phase == .playing else { continue }
            let elapsed = base + Date().timeIntervalSince(started)
            if elapsed >= state.duration {
                if silentLoopIDs.contains(id) && state.duration > 0 {
                    silentElapsedAtStart[id] = 0
                    silentStartedAt[id] = Date()
                    state.elapsed = 0
                    snapshots[id] = state
                } else {
                    finishNaturally(id)
                }
            } else {
                state.elapsed = elapsed
                snapshots[id] = state
            }
        }
    }
}
