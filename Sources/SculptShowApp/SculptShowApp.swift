import SwiftUI
import AppKit

@main
struct SculptShowApp: App {
    @StateObject private var showStore = ShowStore()
    @StateObject private var playback = PlaybackEngine()
    @StateObject private var midi = MIDIControl()
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
        WindowGroup("Sculpt Show") {
            WorkspaceView()
                .environmentObject(showStore)
                .environmentObject(playback)
                .environmentObject(midi)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $showingAudioMIDISetup) {
                    AudioMIDISetupView()
                        .environmentObject(playback)
                        .environmentObject(midi)
                }
                .onOpenURL { documentURL in
                    if showStore.openShow(at: documentURL) {
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
                Button("Audio/MIDI Setup…") { showingAudioMIDISetup = true }
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
    }
}
