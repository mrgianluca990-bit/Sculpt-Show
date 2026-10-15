import SwiftUI

@main
struct SculptShowApp: App {
    @StateObject private var showStore = ShowStore()
    @StateObject private var playback = PlaybackEngine()

    var body: some Scene {
        WindowGroup("Sculpt Show") {
            WorkspaceView()
                .environmentObject(showStore)
                .environmentObject(playback)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1300, height: 790)
        .commands {
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
            CommandGroup(replacing: .saveItem) {
                Button("Save Show") { showStore.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save Show As…") { showStore.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Cues") {
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
