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
                    if element.kind == .audio {
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
                            Text("PHYSICAL OUTPUT")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { store.show.cue(cue.id)?.elements.first(where: { $0.id == element.id })?.outputStartChannel ?? element.outputStartChannel },
                                set: { store.setElementOutput(element.id, in: cue.id, listID: listID, to: $0, using: playback) }
                            )) {
                                ForEach(1...max(2, playback.routingOutputCount), id: \.self) { channel in
                                    Text("OUT \(channel)").tag(channel)
                                }
                            }
                            .frame(width: 126)
                            .disabled(!playback.routingEnabled)
                            .help("Select the first hardware output channel. Mono uses one output, stereo uses two consecutive outputs.")
                        }
                        if !playback.routingEnabled {
                            Text("Enable OUTPUT ROUTING in global transport to assign physical outputs.")
                                .font(.caption2).foregroundColor(.secondary)
                        } else if let device = playback.routingDevices.first(where: { $0.id == playback.routingDeviceID }) {
                            Text("\(device.name) · \(device.channels) hardware outputs · mono/stereo destinations")
                                .font(.caption2).foregroundColor(.secondary)
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
                        Text("Timecode metadata only · LTC/MTC transmission not implemented.")
                            .font(.caption).foregroundColor(.orange)
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
