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
                Text("STEMS (\(cue.audioElements.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(.secondary)
            }
            if cue.audioElements.isEmpty {
                Text("Empty container · can run Rules or be filled later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(cue.audioElements) { element in
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

            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        // Source changes and cache publication now drive the View directly.
    }

}
