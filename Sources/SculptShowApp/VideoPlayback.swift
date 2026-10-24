import AppKit
import CoreAudio
import AVFoundation
import SwiftUI
import SculptShowCore

@MainActor
final class VideoPlayback: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var owner: UUID?
    @Published private(set) var preparing = false
    @Published private(set) var opacity: Double = 0
    @Published private(set) var scale: Double = 1
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
    override init() {
        super.init()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem, let id = self.owner else { return }
                    if note.name == AVPlayerItem.didPlayToEndTimeNotification { self.setOpacity(0); self.onEnded?(id) }
                    else { self.onFailure?(id, "Video decoding failed.") }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.screenID.isEmpty, !NSScreen.screens.contains(where: { Self.id($0) == self.screenID }) else { return }
                if let id = self.owner { self.onFailure?(id, "Video display disconnected. Select an available display in Video Output.") }
                self.hideOutput()
            }
        })
    }
    static func id(_ screen: NSScreen) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "" }
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
        owner = cue.id; preparing = true; scale = cue.video?.scale ?? 1
        let token = generation
        task = Task { [weak self] in
            guard let self, let video = cue.video else { return }
            do {
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
                self.setOpacity(CueVideo.opacity(elapsed: p, duration: duration, fadeIn: cue.fadeInSeconds, fadeOut: cue.fadeOutSeconds))
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
    var elapsed: Double { let value = CMTimeGetSeconds(player.currentTime()); return value.isFinite ? max(0, value) : 0 }
    var playbackError: String? { player.currentItem?.status == .failed ? player.currentItem?.error?.localizedDescription ?? "Video decoding failed." : nil }
    private func play(at position: Double, host: UInt64?) {
        let deadline = host ?? AudioGetCurrentHostTime()
        player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 60000), atHostTime: CMClockMakeHostTimeFromSystemUnits(deadline))
    }
    func pause() { transportGeneration = UUID(); player.cancelPendingPrerolls(); player.pause() }
    func reposition(_ position: Double, playing: Bool, ready: @escaping () -> UInt64?) {
        let token = UUID(); transportGeneration = token
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
        if !preparing && abs(elapsed - position) > 0.1 { play(at: position, host: nil) }
    }
    func stop() {
        generation = UUID(); transportGeneration = UUID(); task?.cancel(); task = nil
        player.cancelPendingPrerolls()
        player.pause(); setOpacity(0); player.replaceCurrentItem(with: nil)
        owner = nil; preparing = false
    }
    func setScale(_ value: Double) { scale = min(1, max(0.1, value)); surface?.imageScale = scale }
    func setOpacity(_ value: Double) {
        let next = min(1, max(0, value)); if opacity != next { opacity = next }
        surface?.imageOpacity = next
    }
    func selectScreen(_ id: String) {
        screenID = id; UserDefaults.standard.set(id, forKey: "sculpt.show.videoScreen")
        if let window, let screen = NSScreen.screens.first(where: { Self.id($0) == id }) ?? (id.isEmpty ? NSScreen.screens.dropFirst().first ?? NSScreen.screens.first : nil) {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            window.setFrame(NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: min(960, screen.frame.width - 80), height: min(540, screen.frame.height - 80)), display: true)
        }
    }
    func showOutput() throws {
        let chosen: NSScreen?
        if screenID.isEmpty { chosen = NSScreen.screens.dropFirst().first ?? NSScreen.screens.first }
        else { chosen = NSScreen.screens.first(where: { Self.id($0) == screenID }) }
        guard let screen = chosen else { throw Failure("The selected video display is unavailable.") }
        if window == nil {
            let w = VideoOutputWindow(contentRect: NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: min(960, screen.frame.width - 80), height: min(540, screen.frame.height - 80)), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
            w.title = "SCULPT · VIDEO OUTPUT"; w.backgroundColor = .black
            w.isReleasedWhenClosed = false; w.delegate = self; w.collectionBehavior = [.fullScreenPrimary]
            let view = VideoSurface(); view.playerLayer.player = player; view.imageScale = scale; view.imageOpacity = opacity
            w.contentView = view; window = w; surface = view
        }
        window?.orderFront(nil); outputVisible = true
    }
    func hideOutput() { window?.orderOut(nil); outputVisible = false }
    func fullscreen() { do { try showOutput(); window?.toggleFullScreen(nil) } catch { if let id = owner { onFailure?(id, error.localizedDescription) } } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let id = owner { onFailure?(id, "Video output closed. Cue stopped.") }
        hideOutput(); return false
    }
}

final class VideoOutputWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
        else { super.cancelOperation(sender) }
    }
}

final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()
    var imageScale: Double = 1 { didSet { needsLayout = true } }
    var imageOpacity: Double = 0 { didSet {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let previous = playerLayer.presentation()?.opacity ?? playerLayer.opacity
        playerLayer.opacity = Float(imageOpacity); CATransaction.commit()
        if imageOpacity > 0 && abs(previous - Float(imageOpacity)) > 0.001 {
            let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = previous
            animation.toValue = Float(imageOpacity); animation.duration = 0.05
            playerLayer.add(animation, forKey: "fade")
        } else { playerLayer.removeAnimation(forKey: "fade") }
    } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect; layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        let width = bounds.width * imageScale, height = bounds.height * imageScale
        playerLayer.frame = NSRect(x: (bounds.width-width)/2, y: (bounds.height-height)/2, width: width, height: height)
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
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VIDEO OUTPUT").font(.headline)
            Picker("Display", selection: Binding(get: { video.screenID }, set: { video.selectScreen($0) })) {
                Text("Automatic · second display, otherwise main").tag("")
                ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(VideoPlayback.id(screen)) }
                if !video.screenID.isEmpty && !NSScreen.screens.contains(where: { VideoPlayback.id($0) == video.screenID }) { Text("Disconnected display").tag(video.screenID) }
            }.disabled(video.owner != nil)
            HStack {
                Button("Show output") { do { try video.showOutput(); error = "" } catch { self.error = error.localizedDescription } }
                Button("Fullscreen / Window") { video.fullscreen() }
                Button("Hide output") { video.hideOutput() }.disabled(video.owner != nil)
            }
            VideoPreview(video: video).frame(height: 220)
            Text("One video cue at a time. Window is resizable; image scale is set per cue in General. Embedded audio is prepared offline and routed through the SHOW mixer. Fade durations use the cue's Fade In / Fade Out. At the end the output returns to black.").font(.callout)
            if !error.isEmpty { Text(error).foregroundColor(.red) }
        }.padding(20).frame(width: 650)
    }
}
