import SwiftUI
import SculptShowCore

/// Edit HH:MM:SS:milliseconds in isolation; never rewrite the field on every keystroke.
struct CueTimingEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    private var displayedLength: Double {
        if cue.durationMode == .fixed { return cue.durationSeconds }
        return max(0.1, cue.alignedAudioElements.compactMap { element -> Double? in
            playback.mediaDuration(for: Cue(name: element.name, mediaPath: element.sourcePath))
        }.max() ?? cue.durationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CUE CONTAINER · DURATION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            HStack(spacing: 8) {
                TextField("HH:MM:SS:MMM", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, design: .monospaced))
                    .monospacedDigit()
                    .focused($editing)
                    .onSubmit {
                        if commit() { editing = false }
                    }
                    .onChange(of: editing) { focused in
                        if !focused && !invalid { _ = commit() }
                    }
            }
            if invalid {
                Text("Use HH:MM:SS:MMM, e.g. 00:01:30:250 (max 24:00:00:000).")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if cue.durationMode == .mediaEnd {
                Text("Legacy cue: change LENGTH to give it its own independent duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Independent container length. Audio beyond its end is cut off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = CueClock.format(displayedLength) }
        .onChange(of: cue.id) { _ in
            editing = false
            invalid = false
            draft = CueClock.format(displayedLength)
        }
        .onChange(of: cue.durationSeconds) { value in
            if !editing && cue.durationMode == .fixed { draft = CueClock.format(value) }
        }
    }

    /// Enter confirms the edit and leaves the text field, just like cue renaming.
    /// Invalid input is retained for correction; duplicate focus-loss events are harmless.
    @discardableResult
    private func commit() -> Bool {
        guard let value = CueClock.parse(draft) else { invalid = true; return false }
        invalid = false
        if cue.durationMode != .fixed || abs(cue.durationSeconds - value) > 0.0005 {
            store.setCueDuration(cue.id, in: listID, to: value)
        }
        draft = CueClock.format(value)
        return true
    }
}
