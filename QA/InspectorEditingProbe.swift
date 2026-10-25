import AppKit
import Darwin
import SwiftUI
import SculptShowCore
@testable import SculptShowApp

@main struct InspectorEditingProbe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        func require(_ ok: Bool, _ text: String) { if !ok { fatalError(text) }; print("PASS · \(text)") }
        func wait(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let video = VideoPlayback(presentsOutput: true)
        var cue = Cue(name:"Typing",fadeOutSeconds:0,fadeInSeconds:0,durationSeconds:2)
        cue.video = CueVideo(sourcePath:root.appendingPathComponent("tone.mp4").path,duration:2)
        cue.loop = true
        video.start(cue,position:0) { _ in nil }
        for _ in 0..<80 { if !video.preparing { break }; await wait() }
        require(video.contains(cue.id) && video.player(for:cue.id)?.rate != 0,"movie plays during numeric edit probe")
        var commits: [Double] = []
        var movie = cue.video!
        let component = ConfirmedNumberField(value:100,range:10...400,label:"Zoom") { value in
            commits.append(value); movie.scale = value/100; video.setGeometry(movie,for:cue.id)
        }
        let host = NSHostingView(rootView:component.frame(width:100,height:30)); host.frame = NSRect(x:0,y:0,width:150,height:50)
        let window = NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); video.stop(); video.hideOutput() }
        host.layoutSubtreeIfNeeded(); await wait()
        func fields(_ view:NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first, let coordinator = field.delegate as? ConfirmedNumberField.Coordinator else { fatalError("Hosted native numeric field missing") }
        window.makeFirstResponder(field); field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { fatalError("Native field editor missing") }
        coordinator.controlTextDidBeginEditing(Notification(name:NSControl.textDidBeginEditingNotification,object:field))
        let initial = video.layerFrame(for:cue.id), initialItem = video.player(for:cue.id)?.currentItem
        for text in ["2","25","250", "250,01"] {
            editor.string = text
            coordinator.synchronize(field,value:100) // render/UI refresh while typing
            require(editor.string == text && commits.isEmpty && movie.scale == 1 && video.layerFrame(for:cue.id) == initial,"unfinished text survives refresh without geometry/commit: \(text)")
            await wait()
        }
        _ = coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        require(commits == [250.01] && abs(movie.scale - 2.5001) < 0.0000001,"Return confirms decimal comma exactly once")
        require(video.player(for:cue.id)?.currentItem === initialItem && video.player(for:cue.id)?.rate != 0,"confirm updates transform without restarting movie")
        window.makeFirstResponder(field); field.selectText(nil)
        let invalidEditor = field.currentEditor() as! NSTextView
        coordinator.controlTextDidBeginEditing(Notification(name:NSControl.textDidBeginEditingNotification,object:field))
        for text in ["", "abc", "nan", "999", "-"] {
            invalidEditor.string = text
            _ = coordinator.control(field,textView:invalidEditor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
            require(commits.count == 1 && coordinator.editing,"invalid input remains uncommitted: \(text)")
        }
        invalidEditor.string = "175"
        _ = coordinator.control(field,textView:invalidEditor,doCommandBy:#selector(NSResponder.cancelOperation(_:)))
        require(commits.count == 1 && coordinator.value == 250.01,"Escape discards edit without model mutation")
        coordinator.controlTextDidBeginEditing(Notification(name:NSControl.textDidBeginEditingNotification,object:field))
        field.stringValue = "300"; coordinator.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
        require(commits.count == 1 && Double(field.stringValue.replacingOccurrences(of:",",with:".")) == 250.01,"blur restores confirmed value without committing")
        // Existing LTC element controls now live under Sends; edit and persistence stay unchanged.
        let store = ShowStore(), playback = PlaybackEngine()
        var model = Show(); model.cueLists[0].cues = [Cue(name:"LTC")]
        let package = try ShowProjectPackage.create(model,requestedDocumentURL:root.appendingPathComponent("Inspector-"+UUID().uuidString+".scshow"))
        require(store.openShow(at:package.documentURL),"open inspector fixture")
        for _ in 0..<80 { if !store.isLoadingProject { break }; await wait() }
        let listID = store.show.cueLists[0].id
        let cueID = store.show.cueLists[0].cues.last!.id
        store.addTimecode(to:cueID,in:listID,using:playback)
        let element = store.show.cue(cueID)!.elements.first { $0.kind == .timecode }!
        store.setTimecode(element.id,in:cueID,listID:listID,to:"01:02:03:04")
        store.setTimecodeTrim(element.id,in:cueID,listID:listID,to:"-00:00:00:02")
        let encoded = try JSONEncoder().encode(store.show), decoded = try JSONDecoder().decode(Show.self,from:encoded)
        require(decoded.cue(cueID)?.elements.first?.id == element.id && decoded.cue(cueID)?.elements.first?.timecodeStart == "01:02:03:04" && decoded.cue(cueID)?.elements.first?.ltcTrim == "-00:00:00:02","relocated LTC preserves identity/start/trim and persistence")
        store.select(cueID,in:listID)
        UserDefaults.standard.set("Inspector",forKey:"SculptShow.RightPanel.v1")
        let midi = MIDIControl()
        let workspace = NSHostingView(rootView:WorkspaceView().environmentObject(store).environmentObject(playback).environmentObject(midi))
        let workspaceWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        workspaceWindow.isReleasedWhenClosed = false; workspaceWindow.contentView = workspace; workspaceWindow.orderFront(nil)
        defer { workspaceWindow.orderOut(nil); playback.stopAll() }
        await wait(0.5)
        require(workspace.window === workspaceWindow && workspace.bounds.width > 0,"reorganized inspector workspace mounts without errors")
        video.stop(); print("ALL INSPECTOR EDITING CHECKS PASSED")
    }
}
