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
                    if showStore.newShow() { playback.stopAll() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Show…") {
                    if showStore.openShow() { playback.stopAll() }
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
                    if let cue = showStore.selectedCue { playback.play(cue) }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Select Next Cue") {
                    if let listID = showStore.selectedListID { showStore.selectNext(in: listID) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Button("Stop All") { playback.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
