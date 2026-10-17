import SwiftUI
import SculptShowCore

/// The normalization uses an offline media copy. No running source or routing
/// state is changed, and full-stem timing/marker positions remain unchanged.
struct CueNormalizationView: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    let cueID: UUID
    let listID: UUID

    @State private var mode: NormalizationTarget = .integratedLUFS
    @State private var target: Double = -18
    @State private var limitPeak = true
    private var busy: Bool { store.normalizingCueID == cueID }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("NORMALIZE AUDIO", systemImage: "waveform.path")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(busy)
            }
            Text("Analyze all mono/stereo stems in the selected cue and create new normalized WAV copies. Original audio, routing, markers and LTC remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Measure", selection: $mode) {
                Text("Integrated LUFS").tag(NormalizationTarget.integratedLUFS)
                Text("Sample Peak").tag(NormalizationTarget.samplePeak)
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            .onChange(of: mode) { newValue in
                target = newValue == .integratedLUFS ? -18 : -1
            }
            HStack {
                Text(mode == .integratedLUFS ? "TARGET LUFS-I" : "TARGET PEAK (dBFS)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Stepper(value: $target,
                        in: mode == .integratedLUFS ? -36 ... -5 : -24 ... 0,
                        step: 0.5) {
                    Text(target, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .frame(width: 65, alignment: .trailing)
                }
                .disabled(busy)
            }
            Toggle("Limit sample peaks to −1 dBFS (avoid clipping)", isOn: $limitPeak)
                .font(.caption)
                .disabled(busy)
                .help("Sample-peak guard, not true-peak limiting. A LUFS target may be missed if this limit is reached.")
            Text("Stop playback before normalizing. Applies separately to each stem, as an item normalization. Existing cue/element fader settings remain unchanged. Gain is applied to a rendered 32-bit floating-point WAV, allowing boosts above unity.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Analyzing / rendering offline…")
                        .foregroundStyle(.secondary)
                }
            } else if store.normalizationReportCueID == cueID,
                      let report = store.normalizationReport {
                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 175)
            }
            HStack {
                Spacer()
                Button("NORMALIZE CUE") {
                    store.normalizeCue(cueID, in: listID, mode: mode,
                        target: target, peakLimit: limitPeak, using: playback)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || store.normalizingCueID != nil ||
                          store.normalizingListID != nil || !playback.snapshots.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 550)
    }
}
