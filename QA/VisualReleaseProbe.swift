import AppKit
import SwiftUI
import Combine
import Darwin
import SculptShowCore
@testable import SculptShowApp

/// Repeatable hosted workspace benchmark; no synthetic input or altered engine.
@main struct VisualReleaseProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        UserDefaults.standard.set("Inspector", forKey: "SculptShow.RightPanel.v1")
        UserDefaults.standard.set(346.0, forKey: "SculptShow.InspectorWidth.v1")
        let store = ShowStore(), midi = MIDIControl(), engine = PlaybackEngine(videoPlayback: VideoPlayback(presentsOutput: false))
        guard store.openShow(at: fixtures.appendingPathComponent("visual-release.scshow")) else { fatalError("Fixture unavailable") }
        for _ in 0..<100 { if !store.isLoadingProject { break }; await wait(0.05) }
        engine.refreshRoutingDevices()
        guard let device = engine.routingDevices.first(where: { $0.id == RoutedAudioEngine.defaultOutputID() }) else { fatalError("No output") }
        await engine.configureRouting(deviceID: device.id)
        engine.projectAudioReady = true
        let view = WorkspaceView().environmentObject(store).environmentObject(engine).environmentObject(midi).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { engine.stopAll(); window.orderOut(nil) }
        await wait(1)
        func capture(_ name: String, _ size: NSSize) throws {
            window.setContentSize(size); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Snapshot failed") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        try capture("workspace-1280x820", NSSize(width: 1280, height: 820))
        try capture("workspace-1100x680", NSSize(width: 1100, height: 680))
        window.setContentSize(NSSize(width: 1280, height: 820))
        let list = store.show.cueLists[0], cue = list.cues[0]
        var movie = Cue(name: "Benchmark movie", mediaPath: fixtures.appendingPathComponent("quiet.wav").path, fadeOutSeconds: 0, durationSeconds: 2)
        movie.video = CueVideo(sourcePath: fixtures.appendingPathComponent("tone.mp4").path, duration: 2)
        movie.video?.audioPrepared = true; movie.loop = true
        func usage() -> (Double, Int64) {
            var value = rusage(); getrusage(RUSAGE_SELF, &value)
            return (Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6, Int64(value.ru_maxrss))
        }
        var records: [[String: Any]] = []
        for mode in ["7-stems", "7-stems+video"] {
            for trial in 1...3 {
                engine.projectAudioReady = true
                guard engine.play(cue) else { fatalError(engine.errorMessage ?? "GO failed") }
                if mode.contains("video") { guard engine.play(movie) else { fatalError("Video GO failed") } }
                await wait(0.6)
                var broad = 0
                let observation = engine.objectWillChange.sink { broad += 1 }
                let cpu = usage().0, start = ProcessInfo.processInfo.systemUptime
                var gaps: [Double] = [], previous = start, count = 0
                while ProcessInfo.processInfo.systemUptime - start < 8 {
                    await wait(0.02)
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append(max(0, (now - previous - 0.02) * 1000)); previous = now; count += 1
                    if count % 50 == 0 { store.select(list.cues[(count / 50) % list.cues.count].id, in: list.id) }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start, endUsage = usage()
                gaps.sort()
                guard engine.snapshots[cue.id]?.phase == .playing, engine.errorMessage == nil else { fatalError("Playback failed during load") }
                observation.cancel()
                let row: [String: Any] = ["mode": mode, "trial": trial, "cpu_percent_one_core": (endUsage.0 - cpu) / elapsed * 100, "peak_rss_bytes": endUsage.1, "ui_delay_p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)], "ui_delay_max_ms": gaps.last!, "broad_publications": broad]
                records.append(row); print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                engine.stopAll(); await wait(0.15)
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("benchmark.json"))
        print("PASS hosted workspace benchmark, six trials, two workloads, exact snapshot sizes")
    }
}
