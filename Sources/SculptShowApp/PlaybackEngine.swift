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
    private var players: [UUID: AVAudioPlayer] = [:]
    private var finishDelegates: [UUID: AudioFinishDelegate] = [:]
    private var cueGains: [UUID: Float] = [:]
    private var fadeTokens: [UUID: UUID] = [:]
    private var updateTimer: Timer?

    init() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard cue.enabled else { return false }
        // A repeated GO on a paused cue resumes it. A running cue does not restart.
        if let player = players[cue.id] {
            if snapshots[cue.id]?.phase == .paused {
                fadeTokens.removeValue(forKey: cue.id)
                player.setVolume(Float(cue.gain), fadeDuration: 0)
                player.play()
                snapshots[cue.id]?.phase = .playing
                return true
            }
            return false
        }
        do {
            let url = URL(fileURLWithPath: cue.mediaPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioFinishDelegate()
            delegate.didFinish = { [weak self, cueID = cue.id] didSucceed in
                Task { @MainActor [weak self] in
                    self?.handleCompletion(cueID, success: didSucceed)
                }
            }
            player.delegate = delegate
            finishDelegates[cue.id] = delegate
            player.numberOfLoops = cue.loop ? -1 : 0
            player.volume = cue.fadeInSeconds > 0 ? 0 : Float(cue.gain)
            player.prepareToPlay()
            guard player.play() else {
                errorMessage = "Could not start audio playback for \(cue.name)."
                return false
            }
            if cue.fadeInSeconds > 0 {
                player.setVolume(Float(cue.gain), fadeDuration: cue.fadeInSeconds)
            }
            players[cue.id] = player
            cueGains[cue.id] = Float(cue.gain)
            snapshots[cue.id] = Snapshot(phase: .playing, elapsed: 0, duration: player.duration)
            return true
        } catch {
            errorMessage = "Cannot open ‘\(cue.name)’: \(error.localizedDescription)"
            return false
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
        finishDelegates.removeValue(forKey: id)
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

    func seek(_ id: UUID, to fraction: Double) {
        guard let player = players[id], player.duration > 0,
              snapshots[id]?.phase != .fading else { return }
        // Keep the seek position strictly before EOF, preventing an accidental natural completion.
        let position = min(max(fraction, 0), 0.9999) * player.duration
        player.currentTime = position
        snapshots[id]?.elapsed = player.currentTime
    }

    func setLoop(_ enabled: Bool, for id: UUID) {
        players[id]?.numberOfLoops = enabled ? -1 : 0
    }

    func stopAll() {
        for id in Array(players.keys) { stop(id) }
    }

    private func handleCompletion(_ id: UUID, success: Bool) {
        guard players[id] != nil, snapshots[id]?.phase == .playing else { return }
        stop(id)
        if success { onNaturalFinish?(id) }
        else { errorMessage = "Audio playback could not finish successfully." }
    }

    private func refresh() {
        for (id, player) in players {
            guard var state = snapshots[id] else { continue }
            if state.phase != .paused && !player.isPlaying {
                // A completed file is handled by the delegate. Interrupted players
                // must not remain stuck in a misleading PLAYING state.
                if state.phase == .fading { stop(id) }
                continue
            }
            state.elapsed = player.currentTime
            state.duration = player.duration
            snapshots[id] = state
        }
    }
}
