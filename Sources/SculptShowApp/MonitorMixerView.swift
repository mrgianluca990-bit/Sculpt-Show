import SwiftUI
import SculptShowCore

struct MonitorInputsView: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    private var lists: [CueList] { store.show.cueLists }
    var body: some View {
        GeometryReader { available in
            let height = max(32, min(140, available.size.height - 160))
            ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(lists) { list in
                            ForEach(list.cues.filter { $0.id == store.selectedCueID || playback.activeInputCueIDs.contains($0.id) }) { cue in
                                ForEach(cue.audioElements) { element in
                                    StemInputStrip(cue: cue, element: element, listID: list.id, faderHeight: height)
                                }
                            }
                        }
                    }.padding(.vertical, 3)
                    if store.selectedCue?.audioElements.isEmpty != false && playback.activeInputCueIDs.isEmpty {
                        Text("Select a cue with stems. Active cues appear here alongside the selected cue.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
                }.frame(maxWidth: .infinity)
                if store.show.monitor.enabled {
                    MonitorMasterStrip(faderHeight: height).frame(width: 132)
                }
            }
            }
        }
    }
}

private struct StemInputStrip: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let element: CueElement
    let listID: UUID
    let faderHeight: CGFloat
    var body: some View {
        VStack(spacing: 4) {
            Text(cue.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Text(element.name).font(.system(size: 10, weight: .bold)).lineLimit(1).help(element.name)
            Text("\(Int(element.gain * 100)) %").font(.system(size: 10, design: .monospaced))
            MixerFader(value: Binding(get: { element.gain }, set: {
                store.setElementGain(element.id, in: cue.id, listID: listID, to: $0, using: playback)
            }), height: faderHeight, name: "Volume " + element.name)
            Text("PAN \(Int(element.pan * 100))").font(.system(size: 9, design: .monospaced))
            Slider(value: Binding(get: { element.pan }, set: {
                store.setStemMixer(element.id, cueID: cue.id, listID: listID, pan: $0, using: playback)
            }), in: -1...1).controlSize(.mini).accessibilityLabel("Pan " + element.name)
                .help("Mono: position in stereo Monitor; direct mono OUT stays mono. Stereo: balance for program and Monitor.")
            HStack {
                MixerSwitch(title: "M", active: element.muted, color: .red) {
                    store.setElementMuted(element.id, in: cue.id, listID: listID, to: !element.muted, using: playback)
                }.accessibilityLabel("Mute " + element.name)
                MixerSwitch(title: "S", active: playback.inputSoloIDs.contains(element.id), color: .yellow) {
                    playback.toggleInputSolo(element.id)
                }.accessibilityLabel("Solo " + element.name)
            }
            if store.show.monitor.enabled {
                Toggle("Send to monitor", isOn: Binding(get: { element.sendToMonitor }, set: {
                    store.setStemMixer(element.id, cueID: cue.id, listID: listID, sendToMonitor: $0, using: playback)
                })).toggleStyle(.checkbox).font(.system(size: 9)).help("Post-fader, after cue gain, fade, mute and input solo")
            }
            Text(playback.outputRouteLabel(first: element.outputStartChannel,
                channels: ShowWaveformCache.shared.channels(at: element.sourcePath) ?? 2))
                .font(.system(size: 8)).lineLimit(1)
        }
        .padding(7).frame(width: 112)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MonitorMasterStrip: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let faderHeight: CGFloat
    var body: some View {
        VStack(spacing: 4) {
            Text("MONITOR").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(.cyan)
            Text("OUT \(store.show.monitor.leftOutput) / \(store.show.monitor.rightOutput)").font(.system(size: 9))
            Text("\(Int(store.show.monitor.gain * 100)) %").font(.system(size: 10, design: .monospaced))
            MixerFader(value: Binding(get: { store.show.monitor.gain }, set: {
                store.setMonitorMix(gain: $0, using: playback)
            }), height: faderHeight, name: "Monitor volume")
            Text("PAN \(Int(store.show.monitor.pan * 100))").font(.system(size: 9, design: .monospaced))
            Slider(value: Binding(get: { store.show.monitor.pan }, set: {
                store.setMonitorMix(pan: $0, using: playback)
            }), in: -1...1).controlSize(.mini).accessibilityLabel("Monitor pan")
            MixerSwitch(title: "MUTE", active: store.show.monitor.muted, color: .red) {
                store.setMonitorMix(muted: !store.show.monitor.muted, using: playback)
            }.accessibilityLabel("Monitor mute")
            if !store.show.monitor.isAvailable(deviceUID: playback.routingDeviceUID, channels: playback.routingOutputCount) {
                Text("UNAVAILABLE").font(.caption2).foregroundStyle(.orange)
            } else if playback.programOutputCount == 0 {
                Text("Monitor only").font(.caption2).foregroundStyle(.cyan)
            } else if playback.monitorOutputs.contains(where: { !playback.outputControls.isAudible($0) }) {
                Text("OUTPUT MUTED").font(.caption2).foregroundStyle(.orange)
            }
            Text("POST-FADER").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.cyan.opacity(0.5)))
    }
}

private struct MixerFader: View {
    @Binding var value: Double
    let height: CGFloat
    let name: String
    var body: some View {
        Slider(value: $value, in: 0...1).accessibilityLabel(name)
            .frame(width: height, height: 24).rotationEffect(.degrees(-90))
            .frame(width: 28, height: height)
    }
}

private struct MixerSwitch: View {
    let title: String
    let active: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundColor(active ? .black : .white)
                .frame(minWidth: 24, minHeight: 20).padding(.horizontal, 3)
                .background(active ? color : Color.gray.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
        }.buttonStyle(.plain).accessibilityValue(active ? "On" : "Off")
    }
}

struct MonitorSetupView: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var left = 1
    @State private var right = 2
    @State private var deviceUID = ""
    @State private var project = UUID()
    private var idle: Bool { playback.snapshots.isEmpty && !store.isLoadingProject && !store.preparingSessionAudio }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACTIVATE MONITOR").font(.headline)
            Text("Choose two physical outputs. They are reserved for the post-fader Monitor send and skipped by automatic program routing. All stems send by default; use Send to monitor to exclude individual stems.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("LEFT", selection: $left) { ForEach(1...max(1, playback.routingOutputCount), id: \.self) { Text("OUT \($0)").tag($0) } }
            Picker("RIGHT", selection: $right) { ForEach(1...max(1, playback.routingOutputCount), id: \.self) { Text("OUT \($0)").tag($0) } }
            if playback.routingOutputCount == 2 { Text("This interface will carry Monitor only. Program outputs return when Monitor is disabled.").font(.caption).foregroundStyle(.orange) }
            if !idle { Text("STOP ALL required to configure outputs").foregroundStyle(.orange) }
            if store.show.monitor.enabled {
                Button("Disable Monitor") {
                    var settings = store.show.monitor; settings.enabled = false
                    if store.configureMonitor(settings, using: playback) { dismiss() }
                }.disabled(!idle || project != store.projectIdentity)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply") {
                    var settings = store.show.monitor
                    settings.enabled = true; settings.deviceUID = deviceUID
                    settings.leftOutput = left; settings.rightOutput = right
                    if store.configureMonitor(settings, using: playback) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(!idle || left == right || playback.routingOutputCount < 2 ||
                        deviceUID != playback.routingDeviceUID || project != store.projectIdentity)
            }
        }.padding(24).frame(width: 440)
        .onAppear {
            deviceUID = playback.routingDeviceUID; project = store.projectIdentity
            if store.show.monitor.isAvailable(deviceUID: deviceUID, channels: playback.routingOutputCount) {
                left = store.show.monitor.leftOutput; right = store.show.monitor.rightOutput
            }
        }
    }
}
