import SwiftUI
import SculptShowCore

/// An ordered collection of capabilities inside one reusable cue container.
struct CueContentsEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

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
                        Button(role: .destructive) {
                            store.removeElement(element.id, from: cue.id, in: listID, using: playback)
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Remove content from container")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    Stepper(value: Binding(
                        get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.startSeconds ?? element.startSeconds },
                        set: { store.setElementStart(element.id, in: cue.id, listID: listID, to: $0) }
                    ), in: 0...86400, step: 0.5) {
                        HStack {
                            Text("OFFSET")
                            Spacer()
                            Text(String(format: "%.1f s", element.startSeconds)).monospacedDigit()
                        }.font(.caption)
                    }
                    if element.kind == .audio {
                        Text(element.sourcePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        if let duration = playback.mediaDuration(for: Cue(name: element.name, mediaPath: element.sourcePath)), duration > 0.11 {
                            let start = min(element.inSeconds, max(0, duration - 0.1))
                            let end = max(start + 0.1, min(element.outSeconds ?? duration, duration))
                            Stepper(value: Binding(
                                get: { start },
                                set: { store.setElementTrim(element.id, in: cue.id, listID: listID, start: min($0, end - 0.1)) }
                            ), in: 0...max(0, end - 0.1), step: 0.1) {
                                HStack { Text("IN"); Spacer(); Text(String(format: "%.1f", start)) }
                                    .font(.caption).monospacedDigit()
                            }
                            Stepper(value: Binding(
                                get: { end },
                                set: { store.setElementTrim(element.id, in: cue.id, listID: listID, end: max(start + 0.1, $0)) }
                            ), in: min(duration, start + 0.1)...duration, step: 0.1) {
                                HStack { Text("OUT"); Spacer(); Text(String(format: "%.1f", end)) }
                                    .font(.caption).monospacedDigit()
                            }
                            Button("Reset IN / OUT") {
                                store.setElementTrim(element.id, in: cue.id, listID: listID, start: 0, resetEnd: true)
                            }.buttonStyle(.plain).font(.caption)
                        } else {
                            Label("Audio not found", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundColor(.orange)
                        }
                    } else {
                        TimecodeEntry(element: element, cueID: cue.id, listID: listID)
                        Text("Timecode metadata only · LTC/MTC transmission not implemented.")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
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
    }
}

private struct TimecodeEntry: View {
    @EnvironmentObject private var store: ShowStore
    let element: CueElement
    let cueID: UUID
    let listID: UUID
    @State private var value = ""

    var body: some View {
        TextField("HH:MM:SS:FF", text: $value)
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .onAppear { value = element.timecodeStart }
            .onSubmit { store.setTimecode(element.id, in: cueID, listID: listID, to: value) }
        Picker("FPS", selection: Binding(
            get: { store.show.cue(cueID)?.elements.first(where: { $0.id == element.id })?.frameRate ?? element.frameRate },
            set: { store.setTimecodeFrameRate(element.id, in: cueID, listID: listID, to: $0) }
        )) {
            Text("24").tag(24)
            Text("25").tag(25)
            Text("30").tag(30)
        }
        .pickerStyle(.segmented)
        Button("Apply timecode") {
            store.setTimecode(element.id, in: cueID, listID: listID, to: value)
        }.buttonStyle(.plain).font(.caption)
    }
}
