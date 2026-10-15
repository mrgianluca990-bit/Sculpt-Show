import AVFAudio
import Foundation

@MainActor
final class PlaybackEngine: ObservableObject {
    enum Phase: String {
        case playing = "PLAYING"
        case paused = "PAUSED"
        case fading = "FADING"
    }

    struct Snapshot {
        var phase: Phase
        var elapsed: TimeInterval
        var duration: TimeInterval

        var fraction: Double { duration > 0 ? min(elapsed / duration, 1) : 0 }
    }

    @Published private(set) var snapshots: [UUID: Snapshot] = [:]
    @Published var errorMessage: String?
    private var players: [UUID: AVAudioPlayer] = [:]
    private var cueGains: [UUID: Float] = [:]
    private var fadeTokens: [UUID: UUID] = [:]
    private var updateTimer: Timer?

    init() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func play(_ cue: Cue) {
        guard cue.enabled else { return }
        // A repeated GO on a paused cue resumes it. A running cue does not restart.
        if let player = players[cue.id] {
            if snapshots[cue.id]?.phase == .paused {
                fadeTokens.removeValue(forKey: cue.id)
                player.setVolume(Float(cue.gain), fadeDuration: 0)
                player.play()
                snapshots[cue.id]?.phase = .playing
            }
            return
        }
        do {
            let url = URL(fileURLWithPath: cue.mediaPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(cue.gain)
            player.prepareToPlay()
            guard player.play() else {
                errorMessage = "Could not start audio playback for \(cue.name)."
                return
            }
            players[cue.id] = player
            cueGains[cue.id] = Float(cue.gain)
            snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: player.duration)
        } catch {
            errorMessage = "Cannot open ‘\(cue.name)’: \(error.localizedDescription)"
        }
    }

    func togglePause(_ id: UUID) {
        guard let player = players[id], let current = snapshots[id] else { return }
        switch current.phase {
        case .paused:
            fadeTokens.removeValue(forKey: id)
            player.setVolume(cueGains[id] ?? 1, fadeDuration: 0)
            player.play()
            snapshots[id]?.phase = .playing
        case .playing, .fading:
            fadeTokens.removeValue(forKey: id)
            player.pause()
            snapshots[id]?.phase = .paused
        }
    }

    func stop(_ id: UUID) {
        fadeTokens.removeValue(forKey: id)
        players[id]?.stop()
        players.removeValue(forKey: id)
        cueGains.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
    }

    func fadeOut(_ cue: Cue) {
        guard let player = players[cue.id] else { return }
        guard cue.fadeOutSeconds > 0 else { stop(cue.id); return }
        guard snapshots[cue.id]?.phase != .fading else { return }
        let token = UUID()
        fadeTokens[cue.id] = token
        snapshots[cue.id]?.phase = .fading
        player.setVolume(0, fadeDuration: cue.fadeOutSeconds)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: UInt64(cue.fadeOutSeconds * 1_000_000_000))
            guard let self, let player, self.fadeTokens[cue.id] == token,
                  self.players[cue.id] === player else { return }
            self.stop(cue.id)
        }
    }

    func setGain(_ gain: Double, for cueID: UUID) {
        guard snapshots[cueID]?.phase != .fading else { return }
        cueGains[cueID] = Float(gain)
        players[cueID]?.volume = Float(gain)
    }

    func stopAll() {
        for id in Array(players.keys) { stop(id) }
    }

    private func refresh() {
        for (id, player) in players {
            guard var state = snapshots[id] else { continue }
            if state.phase != .paused && !player.isPlaying {
                stop(id)
                continue
            }
            state.elapsed = player.currentTime
            state.duration = player.duration
            snapshots[id] = state
        }
    }
}
