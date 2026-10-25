import SwiftUI

/// High-frequency data has its own observation boundary; the workspace observes lifecycle only.
@MainActor final class PlaybackDisplayClock: ObservableObject {
    @Published var snapshots: [UUID: PlaybackEngine.Snapshot] = [:]
    @Published var generatedLTC: PlaybackEngine.GeneratedLTC?
}

struct PlaybackPositionView<Content: View>: View {
    let snapshot: PlaybackEngine.Snapshot
    let cueID: UUID
    @ObservedObject var clock: PlaybackDisplayClock
    let content: (Double) -> Content
    var body: some View {
        let current = clock.snapshots[cueID] ?? snapshot
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: current.phase != .playing && current.phase != .fading)) { _ in
            content(current.presentedElapsed(at: ProcessInfo.processInfo.systemUptime))
        }
    }
}

struct PlaybackTimeView<Content: View>: View {
    let snapshot: PlaybackEngine.Snapshot
    let cueID: UUID
    @ObservedObject var clock: PlaybackDisplayClock
    let content: (PlaybackEngine.Snapshot) -> Content
    var body: some View { content(clock.snapshots[cueID] ?? snapshot) }
}
