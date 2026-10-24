import AppKit
import AVFoundation
import CoreAudio
import SculptShowCore

/// One silent decoder per cue. Its soundtrack stays in RoutedAudioEngine.
@MainActor
final class VideoVoice {
    let id: UUID
    let player: AVQueuePlayer
    let layer: VideoVisualLayer
    private var asset: AVAsset?
    private var image = false
    private var looping: Bool
    private var duration: Double
    private var stopped = false
    private var isPlaying = false
    private var notBefore: TimeInterval = 0
    private var driftSince: TimeInterval?
    private var lastCorrection: TimeInterval = 0
    private var position: Double = 0
    private var stillStarted: TimeInterval?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var ownedItems: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []
    private(set) var loopCount = 0
    private(set) var correctionCount = 0
    var onEnded: (() -> Void)?
    var onLoop: (() -> Void)?
    var onFailure: ((String) -> Void)?
    init(id: UUID, geometry: CueVideo, looping: Bool) {
        self.id = id; self.looping = looping; duration = geometry.duration
        let queue = AVQueuePlayer(); player = queue
        layer = VideoVisualLayer(id: id, geometry: geometry, player: queue)
        player.isMuted = true; player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = looping ? .advance : .pause
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard let self, !self.stopped, self.ownedItems.contains(ObjectIdentifier(item)) else { return }
                    if name == AVPlayerItem.failedToPlayToEndTimeNotification { self.onFailure?("Video decoding failed."); return }
                    if self.looping {
                        self.ownedItems.remove(ObjectIdentifier(item)); self.loopCount += 1
                        self.fillQueue(); self.onLoop?()
                    } else if item === self.player.currentItem {
                        self.onEnded?()
                    }
                }
            })
        }
    }
    private func appendItem() {
        guard let asset else { return }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.5
        item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 60000)
        ownedItems.insert(ObjectIdentifier(item)); player.insert(item, after: nil)
    }
    private func fillQueue() {
        guard looping, !stopped, asset != nil else { return }
        // The next iterations are queued BEFORE the boundary. Never seek from an END callback.
        while player.items().count < 4 { appendItem() }
    }
    func start(position requested: Double, ready: @escaping (Double) -> UInt64?) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.layer.geometry.isImage == true {
                    let decoded = try await VideoPlayback.loadStillImage(URL(fileURLWithPath: self.layer.geometry.sourcePath))
                    try Task.checkCancellation(); guard !self.stopped else { return }
                    self.image = true; self.layer.setImage(decoded)
                    let host = ready(self.duration); guard !self.stopped else { return }
                    self.startStill(at: requested, host: host); return
                }
                let (composition, length) = try await VideoPlayback.silentAsset(URL(fileURLWithPath: self.layer.geometry.sourcePath))
                _ = try await composition.load(.duration)
                guard let track = try await composition.loadTracks(withMediaType: .video).first else { throw VideoPlayback.Failure("Missing video track") }
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                self.layer.sourceSize = CGRect(origin: .zero, size: size).applying(transform).size
                try Task.checkCancellation(); guard !self.stopped else { return }
                self.asset = composition; self.duration = length
                self.appendItem(); self.fillQueue()
                guard let item = self.player.currentItem else { throw VideoPlayback.Failure("Cannot queue video") }
                let timeout = ProcessInfo.processInfo.systemUptime + 15
                while item.status != .readyToPlay {
                    try Task.checkCancellation()
                    guard item.status != .failed else { throw item.error ?? VideoPlayback.Failure("Unsupported video encoding") }
                    guard ProcessInfo.processInfo.systemUptime < timeout else { throw VideoPlayback.Failure("Video preparation timed out") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let p = min(max(0, requested), max(0, length - 0.001))
                guard await self.player.seek(to: CMTime(seconds: p, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) else { throw VideoPlayback.Failure("Video seek failed") }
                let primed = await self.player.preroll(atRate: 1)
                try Task.checkCancellation(); guard !self.stopped else { return }
                guard primed else { throw VideoPlayback.Failure("Video preroll failed") }
                let host = ready(length); guard !self.stopped else { return }
                self.play(at: p, host: host)
            } catch is CancellationError { }
            catch { if !self.stopped { self.onFailure?(error.localizedDescription) } }
        }
    }
    var elapsed: Double {
        if image { return position + (stillStarted.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0) }
        let time = CMTimeGetSeconds(player.currentTime()); return time.isFinite ? max(0, time) : 0
    }
    var playbackError: String? {
        if player.status == .failed { return player.error?.localizedDescription ?? "Video player failed" }
        if player.currentItem?.status == .failed { return player.currentItem?.error?.localizedDescription ?? "Video decoding failed" }
        return nil
    }
    private func play(at position: Double, host: UInt64?) {
        let deadline = host ?? AudioGetCurrentHostTime()
        notBefore = ProcessInfo.processInfo.systemUptime + max(0, AVAudioTime.seconds(forHostTime: deadline) - AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime()))
        isPlaying = true; driftSince = nil
        player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 60000), atHostTime: CMClockMakeHostTimeFromSystemUnits(deadline))
    }
    private func startStill(at value: Double, host: UInt64?) {
        position = value
        let lead = host.map { max(0, AVAudioTime.seconds(forHostTime: $0) - AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime())) } ?? 0
        stillStarted = ProcessInfo.processInfo.systemUptime + lead; isPlaying = true
    }
    func repeatStill(at value: Double) { if image { loopCount += 1; startStill(at: value, host: nil) } }
    func pause() {
        if image { position = elapsed; stillStarted = nil }
        isPlaying = false; generation = UUID(); player.cancelPendingPrerolls(); player.pause()
    }
    func reposition(_ value: Double, playing: Bool, ready: @escaping () -> UInt64?) {
        let token = UUID(); generation = token
        if image { position = value; stillStarted = nil; let host = ready(); if playing { startStill(at: value, host: host) }; return }
        isPlaying = false; player.pause(); player.cancelPendingPrerolls(); player.currentItem?.cancelPendingSeeks()
        Task { [weak self] in
            guard let self else { return }
            let sought = await self.player.seek(to: CMTime(seconds: value, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !self.stopped, self.generation == token, sought else { return }
            if playing {
                let primed = await self.player.preroll(atRate: 1)
                guard !self.stopped, self.generation == token else { return }
                guard primed else { self.onFailure?("Video preroll failed"); return }
            }
            let host = ready()
            guard !self.stopped, self.generation == token else { return }
            if playing { self.play(at: value, host: host) }
        }
    }
    func setLoop(_ enabled: Bool) {
        guard looping != enabled else { return }
        looping = enabled
        player.actionAtItemEnd = enabled ? .advance : .pause
        if enabled { fillQueue() }
        else {
            for item in player.items().dropFirst() { ownedItems.remove(ObjectIdentifier(item)); player.remove(item) }
        }
    }
    func align(to audio: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !image, isPlaying, !stopped, now >= notBefore, player.timeControlStatus == .playing else { return }
        let delta = VideoSyncPolicy.error(video: elapsed, audio: audio, duration: duration, looping: looping)
        let rate = VideoSyncPolicy.rate(for: delta)
        if abs(player.rate - rate) > 0.002 { player.rate = rate }
        if abs(delta) > 0.25 {
            if driftSince == nil { driftSince = now }
            if now - (driftSince ?? now) > 1.5 && now - lastCorrection > 3 {
                correctionCount += 1; lastCorrection = now; driftSince = nil
                play(at: audio, host: nil)
            }
        } else { driftSince = nil }
    }
    func stop() {
        stopped = true; generation = UUID(); task?.cancel(); task = nil
        player.pause(); player.cancelPendingPrerolls(); player.removeAllItems(); ownedItems.removeAll()
        layer.root.removeFromSuperlayer()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
    }
}
