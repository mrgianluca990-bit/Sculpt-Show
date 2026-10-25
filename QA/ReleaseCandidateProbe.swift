import AppKit
import SculptShowCore
@testable import SculptShowApp
@main struct ReleaseCandidateProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        func require(_ ok:Bool,_ text:String) { if !ok { fatalError(text) }; print("PASS · \(text)") }
        func wait(_ t:Double) async { try? await Task.sleep(nanoseconds:UInt64(t*1e9)) }
        var commits:[Double] = []
        let component = ConfirmedNumberField(value:12.345,range:0...86400,clock:true,label:"IN") { commits.append($0) }
        let coordinator = component.makeCoordinator(), field = NSTextField(), editor = NSTextView()
        coordinator.synchronize(field,value:12.345)
        require(field.stringValue == "00:00:12:345","IN/OUT format uses hours/minutes/seconds/three milliseconds")
        coordinator.controlTextDidBeginEditing(Notification(name:NSControl.textDidBeginEditingNotification,object:field))
        editor.string = "00:01:02:345"
        require(commits.isEmpty,"clock text stays uncommitted before Return")
        _ = coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        require(commits == [62.345],"Return confirms HH:MM:SS:MMM exactly")
        for invalid in ["12.345","00:01:02:25","00:60:00:000","24:00:00:001"] {
            editor.string = invalid
            _ = coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
            require(commits.count == 1,"invalid clock input rejected: \(invalid)")
        }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), visual = VideoPlayback(presentsOutput:false), engine = PlaybackEngine(videoPlayback:VideoPlayback(presentsOutput:false))
        var cue = Cue(name:"Optional fades",fadeOutSeconds:10,fadeInSeconds:10,durationSeconds:10)
        cue.video = CueVideo(sourcePath:root.appendingPathComponent("still.png").path,duration:10); cue.video?.isImage = true; cue.video?.audioPrepared = true
        cue.playbackRange = .init(start:2,end:8)
        require(engine.play(cue),"optional-fade image starts")
        await wait(0.35)
        require(engine.video.opacity(for:cue.id) == 1,"automatic fades default OFF despite nonzero durations")
        cue.automaticFadeInEnabled = true; engine.setAutomaticFades(cue); await wait(0.1)
        require(engine.video.opacity(for:cue.id) < 0.2,"automatic IN can be enabled independently")
        cue.automaticFadeInEnabled = false; cue.automaticFadeOutEnabled = true; engine.setAutomaticFades(cue); await wait(0.1)
        require(engine.video.opacity(for:cue.id) > 0.2 && engine.video.opacity(for:cue.id) < 0.9,"automatic OUT can be enabled independently")
        cue.automaticFadeOutEnabled = false; engine.setAutomaticFades(cue); await wait(0.1)
        require(engine.video.opacity(for:cue.id) == 1,"disabling automatic fades restores full level")
        engine.fadeOut(cue,overrideSeconds:0.2); await wait(0.4)
        require(engine.snapshots[cue.id] == nil,"manual FADE still works when automatic fades are off")
        visual.stop(); engine.stopAll(); print("ALL RELEASE CANDIDATE CHECKS PASSED")
    }
}
