import AppKit
import CoreAudio
import AVFoundation
import SwiftUI
import ImageIO
import SculptShowCore

@MainActor
final class VideoPlayback: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var owner: UUID?
    @Published private(set) var preparing = false
    @Published private(set) var opacity: Double = 0
    @Published private(set) var scale: Double = 1
    @Published private(set) var availableScreens = NSScreen.screens
    @Published private(set) var projectionEnabled = UserDefaults.standard.bool(forKey: "sculpt.show.projectionEnabled")
    @Published var outputError: String?
    private let presentsOutput: Bool
    private var image: CGImage?
    private var stillPosition: Double = 0
    private var stillStarted: TimeInterval?
    @Published private(set) var framing: VideoFraming = .fit
    @Published var screenID: String = UserDefaults.standard.string(forKey: "sculpt.show.videoScreen") ?? ""
    @Published private(set) var outputVisible = false
    let player = AVPlayer()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var transportGeneration = UUID()
    private var window: NSWindow?
    private var surface: VideoSurface?
    private var observers: [NSObjectProtocol] = []
    var onEnded: ((UUID) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    init(presentsOutput: Bool = true) {
        self.presentsOutput = presentsOutput
        super.init()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem, let id = self.owner else { return }
                    if note.name == AVPlayerItem.didPlayToEndTimeNotification { self.onEnded?(id) }
                    else { self.onFailure?(id, "Video decoding failed.") }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        if projectionEnabled && presentsOutput {
            DispatchQueue.main.async { [weak self] in self?.restoreProjection() }
        }
    }
    static func id(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func selectedDisplay() -> NSScreen? {
        if screenID.isEmpty { return availableScreens.dropFirst().first }
        return availableScreens.first {
            Self.id($0) == screenID || ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == screenID
        }
    }
    private func restoreProjection() {
        do { try showOutput() } catch { outputError = error.localizedDescription }
    }
    func refreshDisplays() {
        availableScreens = NSScreen.screens
        guard projectionEnabled else { return }
        guard let display = selectedDisplay() else {
            if let id = owner { onFailure?(id, "Projection display disconnected. Cue stopped; no fallback to the operator screen.") }
            window?.orderOut(nil); outputVisible = false
            outputError = "Selected display unavailable. Projection will return to black when it reconnects."
            return
        }
        if let old = window?.screen, Self.id(old) != Self.id(display), let id = owner {
            onFailure?(id, "Projection display changed. Cue stopped.")
        }
        restoreProjection()
    }
    static func loadStillImage(_ url: URL) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 8192,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw Failure("Cannot decode this image.") }
            return image
        }.value
    }
    static func silentAsset(_ url: URL) async throws -> (AVMutableComposition, Double) {
        let source = AVURLAsset(url: url)
        guard let track = try await source.loadTracks(withMediaType: .video).first else { throw Failure("The file has no playable video track.") }
        let range = try await track.load(.timeRange)
        let duration = CMTimeGetSeconds(range.duration)
        guard duration.isFinite, duration > 0.001, duration <= 86400 else { throw Failure("Video must have a finite duration of less than 24 hours.") }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure("Cannot create video track.") }
        try target.insertTimeRange(range, of: track, at: .zero)
        target.preferredTransform = try await track.load(.preferredTransform)
        // Only the video track is inserted. There is no audio decoder/output or live SRC.
        return (composition, duration)
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    func start(_ cue: Cue, position: Double, ready: @escaping (Double) -> UInt64?) {
        stop()
        owner = cue.id; preparing = true; scale = cue.video?.scale ?? 1; framing = cue.video?.framing ?? .fit
        let token = generation
        task = Task { [weak self] in
            guard let self, let video = cue.video else { return }
            do {
                if video.isImage == true {
                    let decoded = try await Self.loadStillImage(URL(fileURLWithPath: video.sourcePath))
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.image = decoded
                    try self.showOutput()
                    self.surface?.image = decoded
                    self.preparing = false
                    let host = ready(video.duration)
                    guard self.generation == token else { return }
                    self.startStill(at: position, host: host)
                    return
                }
                let (asset, duration) = try await Self.silentAsset(URL(fileURLWithPath: video.sourcePath))
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let item = AVPlayerItem(asset: asset)
                self.player.replaceCurrentItem(with: item)
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while item.status != .readyToPlay {
                    try Task.checkCancellation()
                    guard item.status != .failed else { throw item.error ?? Failure("Unsupported video encoding.") }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure("Video preparation timed out.") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let p = min(max(0, position), max(0, duration - 0.001))
                let sought = await self.player.seek(to: CMTime(seconds: p, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                guard self.generation == token, sought else { return }
                try self.showOutput()
                self.preparing = false
                self.setOpacity(CueVideo.opacity(elapsed: p, duration: duration, fadeIn: cue.fadeInSeconds, fadeOut: cue.loop ? 0 : cue.fadeOutSeconds))
                let prerolled = await self.player.preroll(atRate: 1)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard prerolled else { throw Failure("Video preroll failed") }
                let host = ready(duration)
                guard self.generation == token, self.owner == cue.id else { return }
                self.play(at: p, host: host)
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.onFailure?(cue.id, error.localizedDescription)
            }
        }
    }
    var elapsed: Double {
        if image != nil { return stillPosition + (stillStarted.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0) }
        let value = CMTimeGetSeconds(player.currentTime()); return value.isFinite ? max(0, value) : 0 }
    var playbackError: String? { player.currentItem?.status == .failed ? player.currentItem?.error?.localizedDescription ?? "Video decoding failed." : nil }
    private func play(at position: Double, host: UInt64?) {
        let deadline = host ?? AudioGetCurrentHostTime()
        player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 60000), atHostTime: CMClockMakeHostTimeFromSystemUnits(deadline))
    }
    private func startStill(at position: Double, host: UInt64?) {
        stillPosition = position
        let lead = host.map { max(0, AVAudioTime.seconds(forHostTime: $0) - AVAudioTime.seconds(forHostTime: AudioGetCurrentHostTime())) } ?? 0
        stillStarted = ProcessInfo.processInfo.systemUptime + lead
    }
    func repeatVideo(at position: Double) {
        if image != nil { startStill(at: position, host: nil) }
        else { play(at: position, host: nil) }
    }
    func pause() {
        if image != nil { stillPosition = elapsed; stillStarted = nil }
        transportGeneration = UUID(); player.cancelPendingPrerolls(); player.pause() }
    func reposition(_ position: Double, playing: Bool, ready: @escaping () -> UInt64?) {
        let token = UUID(); transportGeneration = token
        if image != nil {
            stillPosition = position; stillStarted = nil
            let host = ready()
            if playing { startStill(at: position, host: host) }
            return
        }
        player.pause(); player.cancelPendingPrerolls(); player.currentItem?.cancelPendingSeeks()
        Task { [weak self] in
            guard let self else { return }
            let sought = await self.player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.transportGeneration == token, self.owner != nil, sought else { return }
            if playing {
                let primed = await self.player.preroll(atRate: 1)
                guard self.transportGeneration == token, let id = self.owner else { return }
                guard primed else { self.onFailure?(id, "Video preroll failed"); return }
            }
            let host = ready()
            guard self.transportGeneration == token, self.owner != nil else { return }
            if playing { self.play(at: position, host: host) }
        }
    }
    func align(to position: Double) {
        if image == nil && !preparing && abs(elapsed - position) > 0.1 { play(at: position, host: nil) }
    }
    func stop() {
        generation = UUID(); transportGeneration = UUID(); task?.cancel(); task = nil
        player.cancelPendingPrerolls()
        player.pause(); setOpacity(0); player.replaceCurrentItem(with: nil)
        image = nil; surface?.image = nil; stillStarted = nil; stillPosition = 0
        owner = nil; preparing = false
    }
    func setFraming(_ value: VideoFraming) { framing = value; surface?.framing = value }
    func setScale(_ value: Double) { scale = min(1, max(0.1, value)); surface?.imageScale = scale }
    func setOpacity(_ value: Double) {
        let next = min(1, max(0, value)); if opacity != next { opacity = next }
        surface?.imageOpacity = next
    }
    func selectScreen(_ id: String) {
        guard owner == nil else { return }
        screenID = id; UserDefaults.standard.set(id, forKey: "sculpt.show.videoScreen")
        enableProjection()
    }
    func enableProjection() {
        projectionEnabled = true
        UserDefaults.standard.set(true, forKey: "sculpt.show.projectionEnabled")
        restoreProjection()
    }
    func disableProjection() {
        if let id = owner { onFailure?(id, "Projection disabled. Visual cue stopped.") }
        hideOutput()
    }
    func showOutput() throws {
        guard presentsOutput else { return }
        availableScreens = NSScreen.screens
        guard let screen = selectedDisplay() else {
            throw Failure("Choose a connected display in Screens. Automatic requires a second display.")
        }
        if window == nil {
            let w = VideoOutputWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.title = "SCULPT · PROJECTION"; w.backgroundColor = .black
            w.isReleasedWhenClosed = false; w.delegate = self; w.isOpaque = true; w.hasShadow = false
            w.ignoresMouseEvents = true; w.hidesOnDeactivate = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = VideoSurface(); view.playerLayer.player = player
            w.contentView = view; window = w; surface = view
        }
        surface?.image = image; surface?.imageScale = scale; surface?.framing = framing; surface?.imageOpacity = opacity
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
        outputVisible = true; projectionEnabled = true; outputError = nil
        UserDefaults.standard.set(true, forKey: "sculpt.show.projectionEnabled")
    }
    func hideOutput() {
        window?.orderOut(nil); outputVisible = false; projectionEnabled = false
        UserDefaults.standard.set(false, forKey: "sculpt.show.projectionEnabled")
    }
    func fullscreen() { enableProjection() }
    var outputGeometry: (frame: NSRect, borderless: Bool, ignoresMouse: Bool, key: Bool)? {
        window.map { ($0.frame, $0.styleMask.isEmpty, $0.ignoresMouseEvents, $0.canBecomeKey) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}

final class VideoOutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()
    private let imageContainer = CALayer()
    private let imageLayer = CALayer()
    var image: CGImage? { didSet {
        imageLayer.contents = image; imageContainer.isHidden = image == nil
        playerLayer.isHidden = image != nil; needsLayout = true
    } }
    var framing: VideoFraming = .fit { didSet { needsLayout = true } }
    var imageScale: Double = 1 { didSet { needsLayout = true } }
    var imageOpacity: Double = 0 { didSet {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let previous = playerLayer.presentation()?.opacity ?? playerLayer.opacity
        playerLayer.opacity = Float(imageOpacity); imageContainer.opacity = Float(imageOpacity); CATransaction.commit()
        if imageOpacity > 0 && abs(previous - Float(imageOpacity)) > 0.001 {
            let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = previous
            animation.toValue = Float(imageOpacity); animation.duration = 0.05
            playerLayer.add(animation, forKey: "fade"); imageContainer.add(animation, forKey: "fade")
        } else { playerLayer.removeAnimation(forKey: "fade"); imageContainer.removeAnimation(forKey: "fade") }
    } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect; playerLayer.masksToBounds = true; layer?.masksToBounds = true
        layer?.addSublayer(playerLayer); imageContainer.masksToBounds = true
        imageContainer.addSublayer(imageLayer); imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageContainer); imageContainer.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        let width = bounds.width * imageScale, height = bounds.height * imageScale
        let target = NSRect(x: (bounds.width-width)/2, y: (bounds.height-height)/2, width: width, height: height)
        playerLayer.frame = target; imageContainer.frame = target
        switch framing { case .fit: playerLayer.videoGravity = .resizeAspect; case .fill: playerLayer.videoGravity = .resizeAspectFill; case .stretch: playerLayer.videoGravity = .resize }
        if let image { imageLayer.frame = framing.frame(source: CGSize(width: image.width, height: image.height), in: imageContainer.bounds) }
        CATransaction.commit()
    }
}
struct VideoPreview: View {
    @ObservedObject var video: VideoPlayback
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "display").font(.largeTitle)
                Text(video.preparing ? "Preparing video…" : video.owner == nil ? "VIDEO OUTPUT · BLACK" : "VIDEO OUTPUT · ACTIVE")
                Text("Image is displayed in the separate output window").font(.caption)
            }.foregroundColor(.gray)
        }
    }
}
struct VideoOutputSettings: View {
    @ObservedObject var video: VideoPlayback
    private func displayLabel(_ screen: NSScreen) -> String {
        let width = Int(screen.frame.width), height = Int(screen.frame.height)
        return "\(screen.localizedName) · \(width) × \(height)"
    }
    private var displayPicker: some View {
        Picker("Projection display", selection: Binding(get: { video.screenID }, set: { video.selectScreen($0) })) {
            Text("Automatic · second display").tag("")
            ForEach(video.availableScreens, id: \.self) { screen in
                Text(displayLabel(screen)).tag(VideoPlayback.id(screen))
            }
            if !video.screenID.isEmpty && !video.availableScreens.contains(where: { VideoPlayback.id($0) == video.screenID }) {
                Text("Saved display · disconnected").tag(video.screenID)
            }
        }.disabled(video.owner != nil)
    }
    private var controls: some View {
        HStack {
            Button("Refresh displays") { video.refreshDisplays() }
            Button(video.projectionEnabled ? "Projection enabled" : "Enable projection") { video.enableProjection() }
            Button("Disable projection") { video.disableProjection() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SCREENS · PROJECTION").font(.headline)
            displayPicker
            controls
            VideoPreview(video: video).frame(height: 160)
            Text("The selected display is always fullscreen, with a black background and no title bar or playback controls. It stays black between cues and while SHOW is in the background. Select the external display, not the operator screen.").font(.callout)
            Text("⌥⌘V disables projection from any SHOW window. Screen selection is available with visual cues stopped.").font(.caption)
            if let error = video.outputError { Text(error).foregroundColor(.orange) }
        }.padding(20).frame(width: 650).onAppear { video.refreshDisplays() }
    }
}
