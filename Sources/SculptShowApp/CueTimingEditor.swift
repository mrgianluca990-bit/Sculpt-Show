import SwiftUI
import SculptShowCore

/// Non-destructive clip timing editor. Changes are saved with the cue and take effect on next GO.
struct CueTimingEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(cue.isEmpty ? "SILENT CUE DURATION" : "TRIM · IN / OUT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
            }
            if cue.isEmpty {
                Stepper(value: Binding(
                    get: { store.show.cue(cue.id)?.durationSeconds ?? cue.durationSeconds },
                    set: { store.setEmptyDuration(cue.id, in: listID, to: $0) }
                ), in: 0...3600, step: 0.5) {
                    Text(String(format: "%.1f s", cue.durationSeconds))
                        .monospacedDigit()
                }
                Text("No audio file. The cue runs silently, triggers its Rules and can follow the next cue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let sourceDuration = playback.mediaDuration(for: cue), sourceDuration > 0.01 {
                let start = min(max(cue.inPointSeconds, 0), sourceDuration)
                let end = min(max(cue.outPointSeconds ?? sourceDuration, start), sourceDuration)
                Stepper(value: Binding(
                    get: { min(cue.inPointSeconds, max(0, end - 0.1)) },
                    set: { store.setTrimIn(cue.id, in: listID, to: min($0, max(0, end - 0.1))) }
                ), in: 0...max(0, end - 0.1), step: 0.1) {
                    HStack {
                        Text("IN")
                        Spacer()
                        Text(String(format: "%.1f s", start)).monospacedDigit()
                    }
                }
                Stepper(value: Binding(
                    get: { end },
                    set: { store.setTrimOut(cue.id, in: listID, to: max(start + 0.1, $0)) }
                ), in: min(sourceDuration, start + 0.1)...sourceDuration, step: 0.1) {
                    HStack {
                        Text("OUT")
                        Spacer()
                        Text(String(format: "%.1f s", end)).monospacedDigit()
                    }
                }
                Stepper(value: Binding(
                    get: { max(0, end - start) },
                    set: { store.setTrimOut(cue.id, in: listID, to: min(sourceDuration, start + $0)) }
                ), in: min(0.1, max(0, sourceDuration - start))...max(0.1, sourceDuration - start), step: 0.1) {
                    HStack {
                        Text("DURATION")
                        Spacer()
                        Text(String(format: "%.1f s", cue.playbackWindow(sourceDuration: sourceDuration).duration))
                            .monospacedDigit()
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset IN / OUT") { store.resetTrim(cue.id, in: listID) }
                        .buttonStyle(.borderless)
                }
                Text(String(format: "Source %.1f s · changes apply on next GO", sourceDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Load a valid audio file to edit its trim points.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
