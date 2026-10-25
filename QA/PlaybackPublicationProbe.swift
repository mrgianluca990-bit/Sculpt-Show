import AppKit
import Combine
import SculptShowCore
@testable import SculptShowApp
@main struct PlaybackPublicationProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let engine = PlaybackEngine()
        var broad = 0
        let observation = engine.objectWillChange.sink { broad += 1 }
        let cue = Cue(name:"UI benchmark",fadeOutSeconds:0,fadeInSeconds:0,durationSeconds:30)
        _ = engine.play(cue)
        try? await Task.sleep(nanoseconds:200_000_000)
        broad = 0
        let start = engine.snapshots[cue.id]!.elapsed
        try? await Task.sleep(nanoseconds:2_000_000_000)
        print("BROAD_PUBLICATIONS_2S",broad,"CLOCK_ADVANCE",engine.snapshots[cue.id]!.elapsed-start)
        guard broad < 4, engine.snapshots[cue.id]!.elapsed-start > 1.5 else { fatalError("Workspace refresh isolation failed") }
        let beforePause = broad
        engine.pause(cue.id)
        guard broad > beforePause, engine.displayClock.snapshots[cue.id]?.phase == .paused else { fatalError("Pause not published") }
        _ = engine.play(cue)
        guard engine.displayClock.snapshots[cue.id]?.phase == .playing else { fatalError("Resume clock stale") }
        engine.stopAll(); guard engine.displayClock.snapshots.isEmpty else { fatalError("STOP clock stale") }
        observation.cancel()
        let reader = LTCInputReader(); var readerBroad = 0
        let readerObservation = reader.objectWillChange.sink { readerBroad += 1 }
        reader.accept(LTCTimecode(text:"00:00:00:00",rate:.fps25)!)
        readerBroad = 0
        for frame in 1...100 { reader.accept(LTCTimecode.at(frameNumber:Int64(frame),rate:.fps25)) }
        guard readerBroad == 0, reader.signal.received == "00:00:04:00", reader.signal.locked else { fatalError("LTC receiver display isolation failed") }
        reader.stop(); readerObservation.cancel()
        let meter = OutputMeterMonitor(); meter.configure(channels:2)
        var meterPublications = 0
        let meterObservation = meter.objectWillChange.sink { meterPublications += 1 }
        for _ in 0..<10 { meter.observe(peaks:[0,0],rms:[0,0]); try? await Task.sleep(nanoseconds:100_000_000) }
        guard meterPublications == 0 else { fatalError("Unchanged silent meter still redraws") }
        meter.observe(peaks:[0.5,0],rms:[0.25,0])
        guard meterPublications == 1, meter.peakHold(channel:1) == 0.5 else { fatalError("Meter peak publication lost") }
        meterObservation.cancel()
        print("PASS · silent meter skips identical redraws while changed levels and held peaks remain visible")
        print("PASS · steady playback and LTC clocks stay local; pause/resume/STOP remain immediate")
    }
}
