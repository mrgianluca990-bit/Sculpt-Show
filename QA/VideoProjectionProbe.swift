// Local hardware smoke test. Generate tone.mp4 and still.png in the supplied folder.
// Link against the DEBUG app/core object files, excluding SculptShowApp.swift.o.
import AppKit
import AVFoundation
import SculptShowCore
@testable import SculptShowApp

@main struct VideoProjectionProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.set(false, forKey: "sculpt.show.projectionEnabled")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let movie = root.appendingPathComponent("tone.mp4")
        let still = root.appendingPathComponent("still.png")
        func require(_ value: Bool, _ message: String) { if !value { fatalError(message) }; print("PASS · \(message)") }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        let image = try await VideoPlayback.loadStillImage(still)
        require(image.width == 320 && image.height == 180, "still image decoding")
        let extracted = try await VideoSoundtrack.prepare(source: movie, directory: root.appendingPathComponent("extracted"), sampleRate: 48000)!
        let source = try AVAudioFile(forReading: extracted)
        require(source.processingFormat.sampleRate == 48000 && source.processingFormat.channelCount == 2 && source.length == 96000, "AAC decoded offline to exact 48k stereo duration")
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![ch][i])) }
        }
        require(peak > 0.01, "decoded soundtrack contains signal")
        // Quiet PCM for actual hardware output; do not emit the unattenuated fixture.
        let quiet = root.appendingPathComponent("quiet.wav")
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![ch][i] *= 0.000001 }
        }
        do { let out = try AVAudioFile(forWriting: quiet, settings: buffer.format.settings); try out.write(from: buffer) }
        let engine = PlaybackEngine(videoPlayback: VideoPlayback(presentsOutput: false))
        engine.refreshRoutingDevices()
        let devices = engine.routingDevices
        guard let device = devices.first(where: { $0.id == RoutedAudioEngine.defaultOutputID() }) else { fatalError("No default hardware") }
        await engine.configureRouting(deviceID: device.id)
        require(engine.routingEnabled, "physical audio engine configured")
        engine.projectAudioReady = true
        var cue = Cue(name: "Movie", mediaPath: quiet.path, fadeOutSeconds: 0, fadeInSeconds: 0, durationSeconds: 2)
        cue.video = CueVideo(sourcePath: movie.path, duration: 2); cue.video?.audioPrepared = true; cue.loop = true
        var naturalEnds = 0; engine.onNaturalFinish = { _ in naturalEnds += 1 }
        require(engine.play(cue), "video GO accepted")
        for _ in 0..<100 { if engine.snapshots[cue.id]?.phase == .playing { break }; await wait(0.05) }
        await wait(0.9)
        require(engine.snapshots[cue.id]?.phase == .playing, "video and soundtrack started: \(engine.errorMessage ?? "OK")")
        let rms = engine.outputMeter(channel: 1).rms
        require(rms > 0.000000001, "nonzero post-mixer physical audio: RMS \(rms)")
        await wait(4.4)
        require(engine.snapshots[cue.id]?.phase == .playing && naturalEnds == 0, "movie and audio survive multiple loops")
        require(engine.video.opacity > 0.9, "loop has no automatic fade to black")
        engine.pause(cue.id); await wait(0.3)
        let paused = engine.snapshots[cue.id]?.elapsed ?? -1
        await wait(0.25)
        require(engine.snapshots[cue.id]?.elapsed == paused, "pause freezes visual/audio clock")
        _ = engine.play(cue); await wait(0.85)
        require(engine.snapshots[cue.id]?.phase == .playing && engine.outputMeter(channel: 1).rms > 0.000000001, "resume restores routed audio")
        engine.setElementMix(cue.audioElements[0].id, for: cue.id, muted: true); await wait(0.45)
        require(engine.outputMeter(channel: 1).rms < 0.0000000001, "soundtrack mute reaches physical matrix")
        engine.setElementMix(cue.audioElements[0].id, for: cue.id, muted: false); await wait(0.45)
        require(engine.outputMeter(channel: 1).rms > 0.000000001, "unmute restores physical signal")
        engine.setLoop(false, for: cue.id); await wait(2.5)
        require(engine.snapshots[cue.id] == nil && naturalEnds == 1, "loop off finishes current cycle once")
        var picture = Cue(name: "Still", fadeOutSeconds: 0, fadeInSeconds: 0, durationSeconds: 0.25)
        picture.video = CueVideo(sourcePath: still.path, duration: 0.25); picture.video?.isImage = true; picture.video?.audioPrepared = true; picture.loop = true
        require(engine.play(picture), "image GO accepted")
        await wait(1.3)
        require(engine.snapshots[picture.id]?.phase == .playing && engine.video.opacity > 0.9, "still remains visible across repeated cycles")
        engine.pause(picture.id); await wait(0.15)
        let frozen = engine.video.elapsed; await wait(0.2)
        require(abs(engine.video.elapsed - frozen) < 0.01, "still pause freezes clock")
        _ = engine.play(picture); await wait(0.2)
        engine.setLoop(false, for: picture.id); await wait(0.5)
        require(engine.snapshots[picture.id] == nil, "still loop off reaches black/end")
        // Unavailable display must not silently replace the operator display.
        let missing = VideoPlayback(); missing.screenID = "missing-test-display"
        do { try missing.showOutput(); fatalError("Unavailable display accepted") } catch { print("PASS · missing display rejected") }
        missing.hideOutput()
        // Exercise the real projection window briefly on the primary display.
        let projection = VideoPlayback()
        guard let screen = NSScreen.screens.first else { fatalError("No display") }
        projection.screenID = VideoPlayback.id(screen)
        try projection.showOutput()
        let geometry = projection.outputGeometry!
        require(geometry.frame == screen.frame && geometry.borderless && geometry.ignoresMouse && !geometry.key, "projection covers exact display with no controls/key focus")
        projection.stop()
        require(projection.outputVisible && projection.opacity == 0, "STOP leaves fullscreen black curtain")
        projection.hideOutput()
        require(!projection.outputVisible, "projection can be disabled")
        // Store path: new imports expose prepared audio; legacy repair preserves mix and does not duplicate.
        let store = ShowStore(); let listID = store.show.cueLists[0].id
        store.addVideo(movie, to: listID)
        for _ in 0..<160 { if store.pendingAudioImports == 0 { break }; await wait(0.05) }
        guard let imported = store.show.cueLists[0].cues.last(where: { $0.video != nil }) else { fatalError(store.errorMessage ?? "Import failed") }
        require(imported.video?.audioPrepared == true && imported.audioElements.count == 1, "new import includes prepared soundtrack atomically")
        let elementID = imported.audioElements[0].id
        store.rebuildVideoSoundtrack(imported.id, in: listID, using: engine)
        for _ in 0..<160 { if !store.preparingSessionAudio { break }; await wait(0.05) }
        let repaired = store.show.cue(imported.id)!
        require(repaired.audioElements.count == 1 && repaired.audioElements[0].id == elementID && repaired.video?.audioPrepared == true && engine.projectAudioReady, "repair replaces soundtrack once and preserves mixer identity: \(store.errorMessage ?? "OK")")
        store.addVideo(still, to: listID)
        for _ in 0..<160 { if store.pendingAudioImports == 0 { break }; await wait(0.05) }
        let importedImage = store.show.cueLists[0].cues.last!
        require(importedImage.video?.isImage == true && importedImage.loop && !importedImage.hasAudio, "image import defaults to held image loop")
        engine.stopAll()
        print("ALL VIDEO/IMAGE/AUDIO/PROJECTION CHECKS PASSED")
        exit(0)
    }
}
