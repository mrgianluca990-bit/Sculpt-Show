import AppKit
import SculptShowCore
@testable import SculptShowApp

/// Audit case: records an existing failure path without changing engine behavior.
@main struct PrewaitFailureAudit {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let store = ShowStore(), engine = PlaybackEngine(videoPlayback: VideoPlayback(presentsOutput: false))
        let list = store.show.cueLists[0].id
        store.addEmptyCue(to: list)
        let id = store.selectedCueID!
        store.setCueDuration(id, in: list, to: 0)
        store.setPreWait(id, in: list, to: 0.1)
        engine.onPlaybackFailed = { store.didStopCue($0) }
        store.playList(list, using: engine)
        guard store.playingLists[list] == id, engine.snapshots[id]?.phase == .waiting else { fatalError("Pre-wait not entered") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        print("AFTER_ERROR", engine.errorMessage ?? "none")
        print("SNAPSHOT_REMOVED", engine.snapshots[id] == nil)
        print("PLAYLIST_STILL_ACTIVE", store.playingLists[list] == id)
        store.setCueDuration(id, in: list, to: 2)
        store.playList(list, using: engine)
        print("RETRY_PLAY_LIST_BLOCKED", engine.snapshots[id] == nil)
        store.stopAll(using: engine)
        store.playList(list, using: engine)
        print("STOP_ALL_RECOVERS", engine.snapshots[id]?.phase == .waiting)
        store.stopAll(using: engine)
    }
}
