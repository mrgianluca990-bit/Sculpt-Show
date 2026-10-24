import SwiftUI
import SculptShowCore
import AVFAudio

/// An ordered collection of capabilities inside one reusable cue container.
struct CueContentsEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    // Observing the shared cache makes channel routing refresh as soon as
    // prepared mono/stereo metadata arrives, without selecting another cue.
    @ObservedObject private var waveformCache = ShowWaveformCache.shared

    @MainActor
    private func audioChannelCount(at path: String) -> Int {
        if let prepared = waveformCache.channels(at: path) { return prepared }
        // Header-only fallback for old sessions; never label a mono stem stereo
        // merely because waveform analysis is not finished.
        if let file = try? SculptPCMReader(URL(fileURLWithPath: path)) { return file.channels }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CONTENTS (\(cue.elements.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(.secondary)
            }
            if cue.elements.isEmpty {
                Text("Empty container · can run Rules or be filled later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(cue.elements) { element in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: element.kind == .audio ? "waveform" : "clock.arrow.circlepath")
                        Text(element.name).lineLimit(1)
                        Spacer()
                        if element.kind == .audio && cue.audioElements.count > 1 {
                            Button {
                                store.moveAudioStem(element.id, in: cue.id, listID: listID, by: -1)
                            } label: { Image(systemName: "arrow.up") }
                            .disabled(cue.audioElements.first?.id == element.id)
                            .help("Move stem up")
                            Button {
                                store.moveAudioStem(element.id, in: cue.id, listID: listID, by: 1)
                            } label: { Image(systemName: "arrow.down") }
                            .disabled(cue.audioElements.last?.id == element.id)
                            .help("Move stem down")
                        }
                        Button(role: .destructive) {
                            store.removeElement(element.id, from: cue.id, in: listID, using: playback)
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Remove content from container")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    if element.kind == .audio {
                        Button {
                            store.receiveDAWBounce(for: element.id, in: cue.id, listID: listID)
                        } label: {
                            Label("RECEIVE DAW BOUNCE…", systemImage: "square.and.arrow.down")
                        }
                        .controlSize(.small)
                        .help("Replace this stem with an edited WAV/AIFF from DAW. Preserves the cue, element UUID, output, Rules and markers. Applies on next GO.")
                        HStack {
                            Text("ELEMENT LEVEL")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Spacer()
                            Text("\(Int((store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.gain ?? element.gain) * 100)) %")
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.gain ?? element.gain },
                            set: { store.setElementGain(element.id, in: cue.id, listID: listID, to: $0, using: playback) }
                        ), in: 0...1)
                        .controlSize(.small)
                        .help("Independent audio level: 100% = unity, 0% = silence")
                        Toggle("MUTE ELEMENT", isOn: Binding(
                            get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.muted ?? element.muted },
                            set: { store.setElementMuted(element.id, in: cue.id, listID: listID, to: $0, using: playback) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .help("Mute this file without affecting the other elements or stopping its transport")
                        HStack {
                            Text("OUTPUT PATCH")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.outputStartChannel ?? element.outputStartChannel },
                                set: { store.setElementOutput(element.id, in: cue.id, listID: listID, to: $0, using: playback) }
                            )) {
                                ForEach(1...max(1, (store.show.outputPatch.isAutomatic(on: playback.routingDeviceUID) ? playback.programOutputCount : 64) - (audioChannelCount(at: element.sourcePath) == 2 ? 1 : 0)), id: \.self) { channel in
                                    Text(playback.outputRouteLabel(first: channel, channels: audioChannelCount(at: element.sourcePath) == 1 ? 1 : 2)).tag(channel)
                                }
                            }
                            .frame(width: 142)
                            .disabled(!playback.routingEnabled)
                            .help("Current destination: \(playback.outputRouteLabel(first: store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.outputStartChannel ?? element.outputStartChannel, channels: audioChannelCount(at: element.sourcePath) == 1 ? 1 : 2)). Changing routing never restarts playback.")
                        }
                        if !playback.routingEnabled {
                            Text("Audio routing is initializing. Select a device in File → Audio/MIDI Setup if required.")
                                .font(.caption2).foregroundColor(.secondary)
                        } else if let device = playback.routingDevices.first(where: { $0.id == playback.routingDeviceID }) {
                            Text("\(device.name) · \(device.channels) hardware outputs · mono/stereo destinations")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        HStack {
                            Button {
                                store.chooseRelink(for: element.id, cueID: cue.id, listID: listID)
                            } label: {
                                Label("RELINK…", systemImage: "link")
                            }
                            .controlSize(.small)
                            .help("Replace file reference without stopping playback. Change takes effect at next GO.")
                            Spacer()
                        }
                        Text(element.sourcePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        if !FileManager.default.fileExists(atPath: element.sourcePath) {
                            Label("Audio not found", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundColor(.orange)
                        }
                    } else {
                        // Timecode elements can still have an independent offset;
                        // audio stems always start together at the cue's zero point.
                        Stepper(value: Binding(
                            get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.startSeconds ?? element.startSeconds },
                            set: { store.setElementStart(element.id, in: cue.id, listID: listID, to: $0) }
                        ), in: 0...86400, step: 0.5) {
                            HStack {
                                Text("TIMECODE OFFSET")
                                Spacer()
                                Text(String(format: "%.1f s", element.startSeconds)).monospacedDigit()
                            }.font(.caption)
                        }
                        TimecodeEntry(element: element, cueID: cue.id, listID: listID)
                        Text("SMPTE LTC is generated on a dedicated mono Core Audio output. Output must be assigned explicitly; settings take effect at the next GO or PLAY.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            if cue.hasAudio {
                Text("Audio stems: START 00:00 · FULL SOURCE · aligned within the cue. Only the container duration limits playback.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    store.attachAudio(to: cue.id, in: listID, using: playback)
                } label: { Label("Audio +", systemImage: "waveform.badge.plus") }
                Button {
                    store.addTimecode(to: cue.id, in: listID, using: playback)
                } label: { Label("Timecode +", systemImage: "clock") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        // Source changes and cache publication now drive the View directly.
    }

}

private struct TimecodeEntry: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let element: CueElement
    let cueID: UUID
    let listID: UUID
    @State private var value = ""
    @State private var trimDraft = ""
    @State private var invalidStart = false
    @State private var invalidTrim = false
    @FocusState private var focusedField: LTCField?
    private enum LTCField: Hashable { case start, trim }

    private var current: CueElement {
        store.show.cue(cueID)?.elements.first(where: { $0.id == element.id }) ?? element
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("LTC START")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                TextField("HH:MM:SS:FF", text: $value)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .start)
                    .foregroundColor(invalidStart ? .orange : .primary)
                    .onSubmit { commitStart() }
            }
            if invalidStart {
                Text("Use valid HH:MM:SS:FF for the selected frame rate.")
                    .font(.caption2).foregroundColor(.orange)
            }
            HStack(spacing: 6) {
                Text("TC OFFSET")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                TextField("±HH:MM:SS:FF", text: $trimDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .trim)
                    .foregroundColor(invalidTrim ? .orange : .primary)
                    .onSubmit { commitTrim() }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("−1F") { nudge(by: -1) }
                    .help("Subtract one SMPTE frame from the LTC offset")
                Button("+1F") { nudge(by: 1) }
                    .help("Add one SMPTE frame to the LTC offset")
                Button("ZERO") { resetTrim() }
                    .help("Reset to negative zero; audio remains unchanged")
            }
            .controlSize(.small)
            if invalidTrim {
                Text("Use ±HH:MM:SS:FF within the selected frame rate.")
                    .font(.caption2).foregroundColor(.orange)
            }
            Text("Return confirms and closes editing · negative offset subtracts LTC frames")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("LTC LEVEL TRIM")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                Slider(value: Binding(
                    get: { current.ltcLevelTrimDB },
                    set: { store.setTimecodeLevelTrim(element.id, in: cueID, listID: listID,
                                                     to: $0, using: playback) }
                ), in: -36...12, step: 1)
                Text(String(format: "%+.0f dB", current.ltcLevelTrimDB))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 65, alignment: .trailing)
            }
            .help("Live LTC output gain trim, -36 to +12 dB relative to nominal -12 dBFS. No changes to music audio.")
            Picker("LTC FPS", selection: Binding(
                get: { LTCFrameRate(fps: current.frameRate, drop: current.timecodeDropFrame) },
                set: { store.setTimecodeLTCFrameRate(element.id, in: cueID, listID: listID, to: $0) }
            )) {
                ForEach(LTCFrameRate.allCases, id: \.rawValue) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("DEDICATED LTC OUT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
                Picker("", selection: Binding(
                    get: { current.ltcOutputChannel ?? 0 },
                    set: { store.setTimecodeOutput(element.id, in: cueID, listID: listID,
                                                    to: $0 == 0 ? nil : $0) }
                )) {
                    Text("Not assigned").tag(0)
                    ForEach(1...max(1, playback.routingOutputCount), id: \.self) { output in
                        Text("OUT \(output)").tag(output)
                    }
                }
                .frame(width: 156)
            }
            Toggle("LTC ENABLED", isOn: Binding(
                get: { !current.muted },
                set: { store.setTimecodeMuted(element.id, in: cueID, listID: listID, to: !$0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            if current.ltcOutputChannel == nil && !current.muted {
                Label("Select an LTC output before playback", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundColor(.orange)
            }
        }
        .onAppear {
            value = current.timecodeStart
            trimDraft = presentedTrim(current.ltcTrim)
        }
        .onChange(of: element.timecodeStart) { _ in
            if focusedField != .start { value = current.timecodeStart }
        }
        .onChange(of: element.ltcTrim) { _ in
            if focusedField != .trim { trimDraft = presentedTrim(current.ltcTrim) }
        }
    }

    private func presentedTrim(_ text: String) -> String {
        // Explicit non-zero positive trims from existing projects must be preserved.
        // Only the zero sign changes its presentation.
        text == "+00:00:00:00" ? LTCFrameTrim.negativeZero : text
    }

    private func commitStart() {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CueElement.isValidTimecode(text, frameRate: current.frameRate,
                dropFrame: current.timecodeDropFrame) else {
            invalidStart = true
            return
        }
        invalidStart = false
        store.setTimecode(element.id, in: cueID, listID: listID, to: text)
        value = text
        focusedField = nil
    }

    private func commitTrim() {
        let rate = LTCFrameRate(fps: current.frameRate, drop: current.timecodeDropFrame)
        guard let trim = LTCFrameTrim(text: trimDraft, rate: rate) else {
            invalidTrim = true
            return
        }
        invalidTrim = false
        // Canonical negative zero, including un-signed zero entered by the operator.
        let normalized = trim.frames == 0 ? LTCFrameTrim.negativeZero : trim.text
        store.setTimecodeTrim(element.id, in: cueID, listID: listID, to: normalized)
        trimDraft = normalized
        focusedField = nil
    }

    private func nudge(by delta: Int64) {
        // Entered edits must be committed before nudging to avoid silently losing work.
        if focusedField == .trim { commitTrim(); if invalidTrim { return } }
        store.nudgeTimecodeTrim(element.id, in: cueID, listID: listID, by: delta)
        trimDraft = presentedTrim(current.ltcTrim)
        invalidTrim = false
        focusedField = nil
    }

    private func resetTrim() {
        store.setTimecodeTrim(element.id, in: cueID, listID: listID,
                              to: LTCFrameTrim.negativeZero)
        trimDraft = LTCFrameTrim.negativeZero
        invalidTrim = false
        focusedField = nil
    }
}
