import SwiftUI
import AppKit

@main
struct SculptShowApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var showStore = ShowStore()
    @StateObject private var playback = PlaybackEngine()
    @StateObject private var midi = MIDIControl()
    @StateObject private var osc = OSCControl()
    @State private var showingAudioMIDISetup = false

    /// Text editors own Cmd-Z/Cmd-Shift-Z while the insertion cursor is active.
    /// Do not accidentally undo a cue edit when undoing typed text.
    private func focusedTextUndo(redo: Bool) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        if let manager = editor.undoManager {
            if redo && manager.canRedo { manager.redo() }
            if !redo && manager.canUndo { manager.undo() }
        }
        return true
    }

    var body: some Scene {
        Window("Sculpt Show", id: "sculpt-show-workspace") {
            WorkspaceView()
                .environmentObject(showStore)
                .environmentObject(playback)
                .environmentObject(midi)
                .preferredColorScheme(.dark)
                .onAppear {
                    osc.handle = { [weak showStore, weak playback] command in
                        guard let showStore, let playback else { return "Show unavailable" }
                        return showStore.performOSC(command, using: playback)
                    }
                    showStore.onSavedMediaMoved = { [weak playback] paths in
                        playback?.remapSavedMedia(paths)
                    }
                    showStore.audioOutputCount = { [weak playback] in
                        let count = playback?.programOutputCount ?? 0
                        return count > 0 ? count : 2
                    }
                }
                .sheet(isPresented: $showingAudioMIDISetup) {
                    AudioMIDISetupView()
                        .environmentObject(osc)
                        .environmentObject(playback)
                        .environmentObject(midi)
                        .environmentObject(showStore)
                }
                .onChange(of: Set(playback.snapshots.keys)) { _ in
                    showStore.applyPendingDAWPublications(using: playback)
                }
                .onChange(of: showStore.isLoadingProject) { loading in
                    playback.projectTransitionInProgress = loading
                    showStore.stopAll(using: playback)
                    if !loading {
                        showStore.requestSessionAudioPreparation(using: playback)
                        showStore.applyPendingDAWPublications(using: playback)
                    }
                }
                .onChange(of: showStore.pendingAudioImports) { _ in
                    showStore.requestSessionAudioPreparation(using: playback)
                    showStore.applyPendingDAWPublications(using: playback)
                }
                .onChange(of: showStore.normalizingCueID) { _ in
                    showStore.requestSessionAudioPreparation(using: playback)
                    showStore.applyPendingDAWPublications(using: playback)
                }
                .onChange(of: showStore.normalizingListID) { _ in
                    showStore.requestSessionAudioPreparation(using: playback)
                    showStore.applyPendingDAWPublications(using: playback)
                }
                .onOpenURL { documentURL in
                    if documentURL.pathExtension.lowercased() == "sculptbridge" {
                        showStore.receiveDAWPublication(at: documentURL, using: playback)
                    } else if showStore.openShow(at: documentURL) {
                        showStore.stopAll(using: playback)
                    }
                }
        }
        .defaultSize(width: 1300, height: 850)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if !focusedTextUndo(redo: false) { showStore.undoEdit(using: playback) }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    if !focusedTextUndo(redo: true) { showStore.redoEdit(using: playback) }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Show") {
                    if showStore.newShow() { showStore.stopAll(using: playback) }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Show…") {
                    if showStore.openShow() { showStore.stopAll(using: playback) }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Receive DAW Publication…") { showStore.chooseDAWPublication(using: playback) }
                Button("Audio/MIDI/Video Setup…") { showingAudioMIDISetup = true }
                    .keyboardShortcut(",", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Show") { showStore.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save Show As…") { showStore.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Save Version") { showStore.saveVersion() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Guida utente italiana di SCULPT SHOW") { openWindow(id:"sculpt-user-guide") }
            }
            CommandMenu("Screens") {
                Button("Show Video") { playback.video.showVideoOutput() }
                Button("Screens Setup…") { openWindow(id: "sculpt-screens") }
                Button("Enable Projection") { playback.video.enableProjection() }
                Button("Disable Projection") { playback.video.disableProjection() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
            }
            CommandMenu("Cues") {
                Button("Duplicate Selected Cue") {
                    if let listID = showStore.selectedListID,
                       let cueID = showStore.selectedCueID {
                        showStore.duplicateCue(cueID, in: listID)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(showStore.selectedCue == nil)

                Button("GO: Fire Selected Cue") {
                    showStore.fireSelected(using: playback)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Select Next Cue") {
                    if let listID = showStore.selectedListID { showStore.selectNext(in: listID) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Button("Previous Cue") {
                    if let id = showStore.selectedListID { showStore.selectPrevious(in: id) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Next Cue List") { showStore.selectNextList() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Pause / Resume All") { showStore.togglePauseAll(using: playback) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Fade All") { showStore.fadeAll(using: playback) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Stop All") { showStore.stopAll(using: playback) }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        Window("Guida utente italiana · SCULPT SHOW", id:"sculpt-user-guide") {
            UserGuideView().preferredColorScheme(.dark)
        }.defaultSize(width:950,height:740)
        Window("Screens", id: "sculpt-screens") {
            VideoOutputSettings(video: playback.video).preferredColorScheme(.dark)
        }.windowResizability(.contentSize)
    }
}
