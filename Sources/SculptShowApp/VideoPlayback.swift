import AppKit
import CoreAudio
import AVFoundation
import SwiftUI
import ImageIO
import SculptShowCore

@MainActor
final class VideoPlayback: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var activeIDs: [UUID] = []
    @Published private(set) var preparingIDs: Set<UUID> = []
    var owner: UUID? { activeIDs.last }
    var preparing: Bool { !preparingIDs.isEmpty }
    var player: AVQueuePlayer { owner.flatMap { voices[$0]?.player } ?? idlePlayer }
    var elapsed: Double { owner.flatMap { voices[$0]?.elapsed } ?? 0 }
    var opacity: Double { owner.flatMap { voices[$0]?.layer.opacityValue } ?? 0 }
    @Published private(set) var availableScreens = NSScreen.screens
    @Published private(set) var projectionEnabled = UserDefaults.standard.bool(forKey: "sculpt.show.projectionEnabled")
    @Published var outputError: String?
    @Published var screenID: String = UserDefaults.standard.string(forKey: "sculpt.show.videoScreen") ?? ""
    @Published private(set) var outputVisible = false
    @Published private(set) var localPreviewVisible = false
    private let presentsOutput: Bool
    private let idlePlayer = AVQueuePlayer()
    private var voices: [UUID: VideoVoice] = [:]
    private var window: NSWindow?
    private var previewWindow: NSWindow?
    private var surface: VideoSurface?
    private var observers: [NSObjectProtocol] = []
    var onEnded: ((UUID) -> Void)?
    var onLoop: ((UUID) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    init(presentsOutput: Bool = true) {
        self.presentsOutput = presentsOutput
        super.init()
        for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWindow.didChangeScreenNotification, (note.object as? NSWindow)?.title != "Sculpt Show" { return }
                Task { @MainActor in self?.refreshDisplays() }
            })
        }
        if projectionEnabled && presentsOutput { DispatchQueue.main.async { [weak self] in
            guard self?.projectionEnabled == true else { return }; self?.restoreProjection()
        } }
    }
    static func id(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    func contains(_ id: UUID) -> Bool { voices[id] != nil }
    func canStart(_ id: UUID) -> Bool { voices[id] != nil || voices.count < VideoCompositionPolicy.maximumCues }
    func player(for id: UUID) -> AVQueuePlayer? { voices[id]?.player }
    func elapsed(for id: UUID) -> Double { voices[id]?.elapsed ?? 0 }
    func opacity(for id: UUID) -> Double { voices[id]?.layer.opacityValue ?? 0 }
    func queueDepth(for id: UUID) -> Int { voices[id]?.player.items().count ?? 0 }
    func loopCount(for id: UUID) -> Int { voices[id]?.loopCount ?? 0 }
    func correctionCount(for id: UUID) -> Int { voices[id]?.correctionCount ?? 0 }
    var playbackErrors: [UUID: String] { voices.compactMapValues { $0.playbackError } }
    func start(_ cue: Cue, position: Double, ready: @escaping (Double) -> UInt64?) {
        guard let movie = cue.video, canStart(cue.id) else { onFailure?(cue.id, "Maximum simultaneous visual cues reached."); return }
        stop(cue.id)
        let voice = VideoVoice(id: cue.id, geometry: movie, looping: cue.loop)
        voices[cue.id] = voice; activeIDs.append(cue.id); preparingIDs.insert(cue.id)
        surface?.setLayers(activeIDs.compactMap { voices[$0]?.layer })
        voice.onEnded = { [weak self] in self?.onEnded?(cue.id) }
        voice.onLoop = { [weak self] in self?.onLoop?(cue.id) }
        voice.onFailure = { [weak self] message in self?.onFailure?(cue.id, message) }
        voice.start(position: position) { [weak self, weak voice] duration in
            guard let self, let voice, self.voices[cue.id] === voice else { return nil }
            do { try self.prepareOutputForPlayback() }
            catch { self.onFailure?(cue.id, error.localizedDescription); return nil }
            self.preparingIDs.remove(cue.id)
            self.surface?.needsLayout = true
            return ready(duration)
        }
    }
    func stop(_ id: UUID) {
        voices.removeValue(forKey: id)?.stop()
        preparingIDs.remove(id); activeIDs.removeAll { $0 == id }
        surface?.setLayers(activeIDs.compactMap { voices[$0]?.layer })
    }
    func stop() { for id in activeIDs { stop(id) } }
    func pause(_ id: UUID) { voices[id]?.pause() }
    func reposition(_ id: UUID, position: Double, playing: Bool, ready: @escaping () -> UInt64?) { voices[id]?.reposition(position, playing: playing, ready: ready) }
    func repeatVideo(_ id: UUID, at position: Double) { voices[id]?.repeatStill(at: position) }
    func align(_ id: UUID, to position: Double) { voices[id]?.align(to: position) }
    func setLoop(_ enabled: Bool, for id: UUID) { voices[id]?.setLoop(enabled) }
    func setOpacity(_ value: Double, for id: UUID) { voices[id]?.layer.setOpacity(value) }
    func setGeometry(_ value: CueVideo, for id: UUID) {
        guard value.isValid, let voice = voices[id] else { return }
        voice.layer.geometry = value; surface?.needsLayout = true; surface?.layoutSubtreeIfNeeded()
    }
    func bringToFront(_ id: UUID) { guard contains(id) else { return }; activeIDs.removeAll { $0 == id }; activeIDs.append(id); surface?.setLayers(activeIDs.compactMap { voices[$0]?.layer }) }
    func sendToBack(_ id: UUID) { guard contains(id) else { return }; activeIDs.removeAll { $0 == id }; activeIDs.insert(id, at: 0); surface?.setLayers(activeIDs.compactMap { voices[$0]?.layer }) }
    func layerFrame(for id: UUID) -> CGRect? { voices[id]?.layer.contentFrame }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    private var operatorScreenID: String? {
        NSApp.windows.first(where: { $0.title == "Sculpt Show" && !($0 is VideoOutputWindow) })?.screen.map(Self.id)
    }
    var projectionScreens: [NSScreen] {
        let ids = ProjectionDisplayPolicy.eligible(connected: availableScreens.map(Self.id), operatorDisplay: operatorScreenID)
        return availableScreens.filter {
            guard ids.contains(Self.id($0)),
                  let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsInMirrorSet(number.uint32Value) == 0
        }
    }
    private func selectedDisplay() -> NSScreen? {
        let preferred = availableScreens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == screenID
        }).map(Self.id) ?? screenID
        let connected = availableScreens.prefix(1).map(Self.id) + projectionScreens.map(Self.id)
        guard let target = ProjectionDisplayPolicy.target(connected: connected,
                operatorDisplay: operatorScreenID, preferred: preferred) else { return nil }
        return projectionScreens.first { Self.id($0) == target }
    }
    private func restoreProjection() {
        do { try showOutput() }
        catch { hideOutput(); outputError = error.localizedDescription }
    }
    private func destination() -> VideoOutputDestination {
        let preferred = availableScreens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == screenID
        }).map(Self.id) ?? screenID
        let excluded = Set(availableScreens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return true }
            return CGDisplayIsInMirrorSet(number.uint32Value) != 0
        }.map(Self.id))
        return ProjectionDisplayPolicy.destination(connected: availableScreens.map(Self.id),
            operatorDisplay: operatorScreenID, preferred: preferred, excluded: excluded)
    }
    func refreshDisplays() {
        availableScreens = NSScreen.screens
        guard presentsOutput else { return }
        let wasProjecting = outputVisible
        let wasPreviewing = localPreviewVisible
        switch destination() {
        case .localWindow:
            if wasProjecting {
                // Never let macOS relocate a fullscreen projection onto the primary.
                hideOutput()
                for id in activeIDs { onFailure?(id, "External display disconnected. Visual cue stopped; local video window available.") }
            }
            if wasProjecting || wasPreviewing || owner != nil { showLocalPreview() }
            else if projectionEnabled { hideOutput() }
        case .externalDisplay:
            guard wasProjecting || wasPreviewing || owner != nil || projectionEnabled else { return }
            do { try prepareOutputForPlayback() } catch { hideOutput(); outputError = error.localizedDescription }
        case .unavailable:
            hideOutput()
            if wasProjecting { for id in activeIDs { onFailure?(id, "Selected projection display unavailable. Visual cue stopped.") } }
            outputError = "Select a connected external display in Screens."
        }
    }
    private func prepareOutputForPlayback() throws {
        guard presentsOutput else { return }
        availableScreens = NSScreen.screens
        switch destination() {
        case .localWindow:
            showLocalPreview()
        case .externalDisplay(let id):
            guard let screen = projectionScreens.first(where: { Self.id($0) == id }) else {
                throw Failure("External display unavailable.")
            }
            if selectedDisplay() == nil {
                screenID = ""; UserDefaults.standard.set("", forKey: "sculpt.show.videoScreen")
            }
            presentExternal(on: screen)
        case .unavailable:
            hideOutput()
            throw Failure("Select a connected external display in Screens, or choose Automatic.")
        }
    }
    func showVideoOutput() {
        do { try prepareOutputForPlayback() } catch { outputError = error.localizedDescription }
    }
    private func attachSurface(to target: NSWindow) {
        if surface == nil { let view = VideoSurface(); view.autoresizingMask = [.width, .height]; surface = view }
        guard let surface else { return }
        if surface.window !== target { surface.window?.contentView = nil; target.contentView = surface }
        surface.setLayers(activeIDs.compactMap { voices[$0]?.layer })
    }
    private func showLocalPreview() {
        guard presentsOutput, let screen = NSApp.windows.first(where: { $0.title == "Sculpt Show" })?.screen ?? NSScreen.screens.first else { return }
        window?.orderOut(nil); outputVisible = false; projectionEnabled = false
        UserDefaults.standard.set(false, forKey: "sculpt.show.projectionEnabled")
        if previewWindow == nil {
            let w = LocalVideoWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "SCULPT · VIDEO"; w.backgroundColor = .black; w.isOpaque = true
            w.isReleasedWhenClosed = false; w.delegate = self; w.collectionBehavior = [.fullScreenNone]
            w.level = .floating; w.hidesOnDeactivate = false
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.center(); _ = w.setFrameAutosaveName("sculpt.show.localVideoWindow")
            _ = w.setFrameUsingName("sculpt.show.localVideoWindow")
            previewWindow = w
        }
        guard let previewWindow else { return }
        let visible = screen.visibleFrame
        previewWindow.minSize = NSSize(width: min(320, visible.width * 0.85), height: min(200, visible.height * 0.85))
        previewWindow.maxSize = NSSize(width: visible.width * 0.85, height: visible.height * 0.85)
        previewWindow.setFrame(LocalVideoWindowGeometry.clamped(previewWindow.frame, in: visible), display: true)
        attachSurface(to: previewWindow)
        if previewWindow.isMiniaturized { previewWindow.deminiaturize(nil) }
        previewWindow.orderFrontRegardless(); localPreviewVisible = true; outputError = nil
    }
    func hideLocalPreview() { previewWindow?.orderOut(nil); localPreviewVisible = false }
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
        for id in activeIDs { onFailure?(id, "Projection disabled. Visual cue stopped.") }
        hideOutput()
    }
    func showOutput() throws {
        guard presentsOutput else { return }
        availableScreens = NSScreen.screens
        guard let screen = selectedDisplay() else {
            hideOutput()
            throw Failure("Connect and select an additional display. Fullscreen projection onto the primary or operator display is disabled.")
        }
        presentExternal(on: screen)
    }
    private func presentExternal(on screen: NSScreen) {
        hideLocalPreview()
        if window == nil {
            let w = VideoOutputWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.title = "SCULPT · PROJECTION"; w.backgroundColor = .black
            w.isReleasedWhenClosed = false; w.delegate = self; w.isOpaque = true; w.hasShadow = false
            w.ignoresMouseEvents = true; w.hidesOnDeactivate = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window = w
        }
        guard let window else { return }
        attachSurface(to: window)
        window.setFrame(screen.frame, display: true); window.orderFrontRegardless()
        outputVisible = true; projectionEnabled = true; outputError = nil
        UserDefaults.standard.set(true, forKey: "sculpt.show.projectionEnabled")
    }
    func hideOutput() {
        window?.orderOut(nil); outputVisible = false; projectionEnabled = false
        hideLocalPreview()
        UserDefaults.standard.set(false, forKey: "sculpt.show.projectionEnabled")
    }
    func fullscreen() { enableProjection() }
    var outputGeometry: (frame: NSRect, borderless: Bool, ignoresMouse: Bool, key: Bool)? {
        window.map { ($0.frame, $0.styleMask.isEmpty, $0.ignoresMouseEvents, $0.canBecomeKey) }
    }
    var localPreviewGeometry: (frame: NSRect, titled: Bool, resizable: Bool, fullScreenAllowed: Bool, surfaceAttached: Bool, alwaysOnTop: Bool)? {
        previewWindow.map { ($0.frame, $0.styleMask.contains(.titled), $0.styleMask.contains(.resizable),
            !$0.collectionBehavior.contains(.fullScreenNone), surface?.window === $0, $0.level == .floating && !$0.hidesOnDeactivate) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === previewWindow { hideLocalPreview() }
        return false
    }
}

final class LocalVideoWindow: NSWindow { override var canBecomeMain: Bool { false } }
final class VideoOutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VideoVisualLayer {
    let id: UUID
    let root = CALayer()
    let playerLayer = AVPlayerLayer()
    let imageLayer = CALayer()
    var geometry: CueVideo
    var sourceSize = CGSize(width: 16, height: 9)
    private(set) var opacityValue: Double = 0
    var contentFrame: CGRect { playerLayer.frame.offsetBy(dx: root.frame.minX, dy: root.frame.minY) }
    init(id: UUID, geometry: CueVideo, player: AVPlayer) {
        self.id = id; self.geometry = geometry
        root.masksToBounds = true; root.opacity = 0
        playerLayer.player = player; playerLayer.videoGravity = .resize
        root.addSublayer(playerLayer); root.addSublayer(imageLayer); imageLayer.isHidden = true
        imageLayer.contentsGravity = .resize
    }
    func setImage(_ image: CGImage) {
        imageLayer.contents = image; imageLayer.isHidden = false; playerLayer.isHidden = true
        sourceSize = CGSize(width: image.width, height: image.height)
    }
    func layout(in bounds: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let viewport = geometry.viewportFrame(in: bounds)
        root.frame = viewport
        let absolute = geometry.contentFrame(source: sourceSize, in: bounds)
        let local = absolute.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        playerLayer.frame = local; imageLayer.frame = local
        CATransaction.commit()
    }
    func setOpacity(_ value: Double) {
        let next = min(1, max(0, value)); guard next != opacityValue else { return }
        let previous = root.presentation()?.opacity ?? root.opacity
        opacityValue = next
        CATransaction.begin(); CATransaction.setDisableActions(true); root.opacity = Float(next); CATransaction.commit()
        if next > 0 && abs(previous - Float(next)) > 0.001 {
            let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = previous
            animation.toValue = Float(next); animation.duration = 0.05; root.add(animation, forKey: "fade")
        } else { root.removeAnimation(forKey: "fade") }
    }
}

@MainActor
final class VideoSurface: NSView {
    private var visuals: [VideoVisualLayer] = []
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func setLayers(_ next: [VideoVisualLayer]) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        for visual in visuals where !next.contains(where: { $0 === visual }) { visual.root.removeFromSuperlayer() }
        visuals = next
        for (index, visual) in next.enumerated() {
            if visual.root.superlayer !== layer { layer?.addSublayer(visual.root) }
            visual.root.zPosition = CGFloat(index)
        }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() { super.layout(); for visual in visuals { visual.layout(in: bounds) } }
}
struct VideoPreview: View {
    @ObservedObject var video: VideoPlayback
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "display").font(.largeTitle)
                Text("Active visuals: \(video.activeIDs.count) / \(VideoCompositionPolicy.maximumCues)").font(.caption)
                Text(video.preparing ? "Preparing video…" : video.localPreviewVisible ? "LOCAL VIDEO WINDOW" : !video.outputVisible ? "VIDEO OUTPUT · OFF" : video.owner == nil ? "VIDEO OUTPUT · BLACK" : "VIDEO OUTPUT · ACTIVE")
                Text(video.localPreviewVisible ? "Video plays in the resizable window" : video.outputVisible ? "Image is displayed on the external output" : "Use Show Video to open the output").font(.caption)
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
            ForEach(video.projectionScreens, id: \.self) { screen in
                Text(displayLabel(screen)).tag(VideoPlayback.id(screen))
            }
            if !video.screenID.isEmpty && !video.projectionScreens.contains(where: { VideoPlayback.id($0) == video.screenID }) {
                Text("Saved display · unavailable for projection").tag(video.screenID).disabled(true)
            }
        }.disabled(video.owner != nil)
    }
    private var controls: some View {
        HStack {
            Button("Refresh displays") { video.refreshDisplays() }
            Button("Show Video") { video.showVideoOutput() }
            Button(video.projectionEnabled ? "Projection enabled" : "Enable projection") { video.enableProjection() }.disabled(video.projectionScreens.isEmpty)
            Button("Disable projection") { video.disableProjection() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SCREENS · PROJECTION").font(.headline)
            displayPicker
            controls
            VideoPreview(video: video).frame(height: 160)
            Text("The selected display is always fullscreen, with a black background and no title bar or playback controls. It stays black between cues and while SHOW is in the background. The primary and operator displays cannot be selected. With one display, video opens in a resizable window. With an additional display, video is projected fullscreen there; the operator display remains available.").font(.callout)
            Text("⌥⌘V disables projection from any SHOW window. Screen selection is available with visual cues stopped.").font(.caption)
            if let error = video.outputError { Text(error).foregroundColor(.orange) }
        }.padding(20).frame(width: 650).onAppear { video.refreshDisplays() }
    }
}
