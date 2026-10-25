import AppKit
import Darwin
import AVFoundation
import SculptShowCore
@testable import SculptShowApp

@main struct CueRangeProbe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        func require(_ ok:Bool,_ text:String) { if !ok { fatalError(text) }; print("PASS · \(text)") }
        func wait(_ time:Double) async { try? await Task.sleep(nanoseconds:UInt64(time*1e9)) }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), video = VideoPlayback(presentsOutput:false)
        let engine = PlaybackEngine(videoPlayback:video)
        engine.refreshRoutingDevices()
        guard let device = engine.routingDevices.first(where: { $0.id == RoutedAudioEngine.defaultOutputID() }) else { fatalError("No audio device") }
        await engine.configureRouting(deviceID:device.id); engine.projectAudioReady = true
        require(engine.routingEnabled,"hardware routed engine configured")
        var cue = Cue(name:"7 stem trim",fadeOutSeconds:0.1,fadeInSeconds:0.1,durationSeconds:2)
        cue.elements = (0..<7).map { _ in CueElement.audio(root.appendingPathComponent("quiet.wav")) }
        cue.playbackRange = .init(start:0.3,end:1.2); cue.loop = true
        var endings = 0; engine.onNaturalFinish = { _ in endings += 1 }
        require(engine.play(cue),"seven-stem trimmed GO accepted")
        require(engine.snapshots[cue.id]?.elapsed == 0.3 && engine.snapshots[cue.id]?.duration == 1.2,"GO starts at source IN and uses OUT")
        for _ in 0..<45 {
            await wait(0.08)
            guard let snapshot = engine.snapshots[cue.id] else { fatalError("trimmed loop stopped: \(engine.errorMessage ?? "")") }
            require(snapshot.elapsed >= 0.3-0.001 && snapshot.elapsed < 1.201,"native multitrack loop stays inside IN/OUT")
        }
        require(endings == 0,"trimmed loop does not finish prematurely")
        engine.seek(cue.id,toSeconds:0); await wait(0.25)
        require((engine.snapshots[cue.id]?.elapsed ?? -1) >= 0.3,"seek below IN clamps to IN")
        engine.setLoop(false,for:cue.id)
        for _ in 0..<30 { if engine.snapshots[cue.id] == nil { break }; await wait(0.08) }
        require(engine.snapshots[cue.id] == nil && endings == 1,"loop off ends at selected OUT once")
        var movie = Cue(name:"Trim movie",mediaPath:root.appendingPathComponent("quiet.wav").path,fadeOutSeconds:0.1,fadeInSeconds:0.1,durationSeconds:2)
        movie.video = CueVideo(sourcePath:root.appendingPathComponent("tone.mp4").path,duration:2); movie.video?.audioPrepared = true
        movie.playbackRange = .init(start:0.4,end:1.4); movie.loop = true
        require(engine.play(movie),"video/soundtrack trimmed GO accepted")
        for _ in 0..<80 { if engine.snapshots[movie.id]?.phase == .playing { break }; await wait(0.04) }
        require(abs((engine.snapshots[movie.id]?.duration ?? -1) - 1.4) < 0.002,"video clip reports original OUT coordinate: \(String(describing:engine.snapshots[movie.id])), \(engine.errorMessage ?? "OK")")
        let localDuration = CMTimeGetSeconds(try await video.player(for:movie.id)!.currentItem!.asset.load(.duration))
        require(abs(localDuration-1) < 0.002,"queued video composition is trimmed to one second")
        for _ in 0..<30 { await wait(0.08); let t = engine.snapshots[movie.id]?.elapsed ?? -1; require(t >= 0.399 && t <= 1.401,"movie and PCM use same selected interval") }
        engine.pause(movie.id); await wait(0.1); let held = engine.snapshots[movie.id]!.elapsed
        await wait(0.15); require(engine.snapshots[movie.id]?.elapsed == held,"trimmed video pause holds source coordinate")
        _ = engine.play(movie); await wait(0.25); require(engine.snapshots[movie.id]?.phase == .playing,"trimmed video resume succeeds")
        engine.stopAll()
        var still = Cue(name:"Trim still",fadeOutSeconds:0,fadeInSeconds:0,durationSeconds:2)
        still.video = CueVideo(sourcePath:root.appendingPathComponent("still.png").path,duration:2); still.video?.isImage = true; still.video?.audioPrepared = true
        still.playbackRange = .init(start:0.2,end:0.6); still.loop = true
        let before = CueMarker(name:"Excluded",positionSeconds:0.1), inside = CueMarker(name:"Included",positionSeconds:0.3)
        still.markers = [before,inside]
        var markerIDs:[UUID] = []; engine.onMarkersReached = { _, ids in markerIDs += ids }
        require(engine.play(still),"trimmed image GO accepted")
        await wait(1.4)
        require(engine.snapshots[still.id]?.phase == .playing && !markerIDs.contains(before.id) && markerIDs.contains(inside.id),"image loops preserve IN and do not replay excluded markers")
        engine.stopAll()
        let store = ShowStore(); var model = Show(); model.cueLists[0].cues = [Cue(name:"Editable",durationSeconds:5)]
        let fixture = try ShowProjectPackage.create(model,requestedDocumentURL:root.appendingPathComponent("Range-"+UUID().uuidString+".scshow"))
        require(store.openShow(at:fixture.documentURL),"open range fixture")
        for _ in 0..<80 { if !store.isLoadingProject { break }; await wait(0.02) }
        let id = store.show.cueLists[0].cues[0].id,list = store.show.cueLists[0].id
        store.setCuePlaybackRange(id,in:list,start:1,end:4,using:engine)
        require(store.show.cue(id)?.playbackRange == .init(start:1,end:4),"typed/drag range setter stores both points atomically")
        store.undoEdit(using:engine); require(store.show.cue(id)?.playbackRange == nil,"range edit Undo restores full source")
        store.redoEdit(using:engine); require(store.show.cue(id)?.playbackRange?.start == 1,"range edit Redo restores chosen interval")
        _ = engine.play(store.show.cue(id)!)
        store.setCuePlaybackRange(id,in:list,start:2,end:3,using:engine)
        require(store.show.cue(id)?.playbackRange?.start == 1,"running cue rejects range changes")
        engine.stopAll(); print("ALL CUE RANGE CHECKS PASSED")
    }
}
