import SwiftUI
import SculptShowCore

/// The original LTC element UI lives with outgoing trigger messages, not audio stems.
struct CueTimecodeSendEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("TIMECODE · LTC AUDIO OUT", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cue.elements.filter { $0.kind == .timecode }) { element in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(element.name).font(.caption.bold()); Spacer()
                            Button(role: .destructive) {
                                store.removeElement(element.id, from: cue.id, in: listID, using: playback)
                            } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Remove LTC output")
                        }
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
                    }.padding(8).background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                Button { store.addTimecode(to: cue.id, in: listID, using: playback) } label: { Label("Timecode +", systemImage: "clock") }
                    .disabled(cue.video != nil || cue.elements.contains(where: { $0.kind == .timecode }))
                if cue.video != nil { Text("LTC output is available on audio/empty cues; video cues retain their soundtrack.").font(.caption2).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        }
    }
}

struct TimecodeEntry: View {
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
