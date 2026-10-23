import SwiftUI

/// Only the small playhead/progress leaf runs at display cadence, not the editor.
struct PlaybackPositionView<Content: View>: View {
    let snapshot: PlaybackEngine.Snapshot
    let content: (Double) -> Content
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: snapshot.phase != .playing && snapshot.phase != .fading)) { _ in
            content(snapshot.presentedElapsed(at: ProcessInfo.processInfo.systemUptime))
        }
    }
}
