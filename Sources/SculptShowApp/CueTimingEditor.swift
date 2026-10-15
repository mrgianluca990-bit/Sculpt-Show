import SwiftUI
import SculptShowCore

/// A cue has one timeline duration regardless of what content it contains.
struct CueTimingEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

    private var displayedLength: Double {
        if cue.durationMode == .fixed { return cue.durationSeconds }
        return max(0.1, cue.audioElements.compactMap { element -> Double? in
            guard let source = playback.mediaDuration(for: Cue(name: element.name, mediaPath: element.sourcePath)) else { return nil }
            let start = min(max(0, element.inSeconds), source)
            let end = max(start, min(element.outSeconds ?? source, source))
            return element.startSeconds + end - start
        }.max() ?? cue.durationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CUE CONTAINER · DURATION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Stepper(value: Binding(
                get: { max(0.1, displayedLength) },
                set: { store.setCueDuration(cue.id, in: listID, to: $0) }
            ), in: 0.1...86400, step: 0.5) {
                HStack {
                    Text("LENGTH")
                    Spacer()
                    Text(String(format: "%.1f s", displayedLength)).monospacedDigit()
                }
            }
            if cue.durationMode == .mediaEnd {
                Text("Imported show: currently follows source duration. Change LENGTH to give this cue its own independent timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if cue.hasAudio {
                Text("Audio beyond this duration is cut off. Shorter audio ends without stopping the cue timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This container runs for its own duration, even with no audio or only Rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
