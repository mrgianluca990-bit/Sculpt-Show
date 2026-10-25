import SwiftUI
import SculptShowCore

/// Document draft: Apply is one Undo step; Cancel/Reload never changes the engine.
struct OutputPatchView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var store: ShowStore
    @State private var base = ShowOutputPatch()
    @State private var draft = ShowOutputPatch()
    @State private var projectIdentity = UUID()
    @State private var uid = ""
    @State private var automatic = true
    @State private var outputs: [Int?] = Array(repeating: nil, count: 64)
    @State private var message = ""
    private var deviceName: String {
        playback.routingDevices.first { $0.uid == playback.routingDeviceUID }?.name ?? "No interface"
    }
    private var idle: Bool { playback.snapshots.isEmpty && !store.isLoadingProject && !store.preparingSessionAudio && store.pendingAudioImports == 0 }
    private var stale: Bool { base != store.show.outputPatch || uid != playback.routingDeviceUID || projectIdentity != store.projectIdentity }
    private var preview: ShowOutputPatch {
        var patch = draft
        patch.setProfile(.init(deviceUID: uid, deviceName: deviceName, automatic: automatic, outputs: outputs))
        return patch
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROJECT OUTPUT PATCH").font(.system(size: 16, weight: .bold, design: .monospaced))
            Text("\(deviceName) · \(playback.routingOutputCount) physical outputs")
                .font(.subheadline)
            Text("Logical channel numbers and names stay with this show. Each interface has its own patch, identified by Core Audio UID. The output mixer and speaker test always address physical outputs; LTC keeps its dedicated physical OUT.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Routing", selection: $automatic) {
                Text("Automatic · cyclic outputs").tag(true)
                Text("Custom · explicit patch").tag(false)
            }.pickerStyle(.segmented)
            if automatic {
                Text("Default routing is preserved: ordered stems reuse the connected outputs; stereo uses adjacent pairs. Names do not change the assignments.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Unpatched or missing outputs block the affected cue before GO. Stereo uses two different physical outputs in L/R order. Shared physical outputs sum their audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("LOGICAL").frame(width: 70, alignment: .leading)
                Text("SHOW NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("PHYSICAL OUT / STATUS").frame(width: 215, alignment: .leading)
            }.font(.system(size: 10, weight: .semibold, design: .monospaced))
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(1...64, id: \.self) { channel in
                        HStack {
                            Text(String(format: "%02d", channel)).monospacedDigit().frame(width: 70, alignment: .leading)
                            TextField("OUT \(channel)", text: Binding(
                                get: { draft.names[String(channel)] ?? "" },
                                set: { draft.names[String(channel)] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            if automatic {
                                Text(playback.outputRouteLabel(first: channel, channels: 1))
                                    .font(.caption).frame(width: 215, alignment: .leading)
                            } else {
                                Picker("Physical output for logical \(channel)", selection: Binding(
                                    get: { outputs[channel - 1] ?? 0 },
                                    set: { outputs[channel - 1] = $0 == 0 ? nil : $0 })) {
                                    Text("Unpatched").tag(0)
                                    ForEach(1...max(1, playback.routingOutputCount), id: \.self) { output in Text("OUT \(output)").tag(output) }
                                    if let missing = outputs[channel - 1], missing > playback.routingOutputCount {
                                        Text("OUT \(missing) · UNAVAILABLE").tag(missing)
                                    }
                                }.labelsHidden().frame(width: 215)
                            }
                        }
                    }
                }.padding(.trailing, 8)
            }.frame(height: 265)
            let issues = store.show.cueLists.flatMap(\.cues).flatMap(\.audioElements).compactMap { element -> String? in
                let channels = ShowWaveformCache.shared.channels(at: element.sourcePath) ?? 2
                do {
                    _ = try preview.crosspoints(firstOutput: element.outputStartChannel, sourceChannels: channels,
                        deviceUID: uid, deviceChannels: playback.routingOutputCount, excluding: playback.monitorOutputs)
                    return nil
                } catch { return error.localizedDescription }
            }
            Text(issues.first ?? "Used routes are mapped. Run Preflight to verify files and LTC conflicts.")
                .font(.caption).foregroundStyle(issues.isEmpty ? Color.secondary : .orange)
            if store.show.monitor.enabled {
                Text("Monitor OUT \(store.show.monitor.leftOutput)/\(store.show.monitor.rightOutput) · reserved · configure in Mixer")
                    .font(.caption).foregroundStyle(SculptTheme.accent)
            }
            if stale { Text("Project or device changed. Reload this draft before Apply.").font(.caption).foregroundStyle(SculptTheme.gold) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel / Reload") { reload() }
                Spacer()
                if !idle { Text("STOP ALL required to apply").font(.caption).foregroundStyle(SculptTheme.gold) }
                Button("Apply Patch") { apply() }.buttonStyle(.borderedProminent)
                    .disabled(!idle || stale || uid.isEmpty || !playback.routingEnabled)
            }
        }
        .padding(24)
        .onAppear { reload() }
        .onChange(of: playback.routingDeviceUID) { _ in reload() }
    }
    private func reload() {
        base = store.show.outputPatch; draft = base; uid = playback.routingDeviceUID; projectIdentity = store.projectIdentity
        let profile = base.profile(for: uid)
        automatic = profile?.automatic ?? true
        outputs = profile?.outputs ?? (1...64).map { $0 <= playback.routingOutputCount ? $0 : nil }
        message = !base.isAutomatic(on: uid) && profile == nil ? "No saved patch for this interface. Choose a mode and Apply before GO." : ""
    }
    private func apply() {
        var patch = preview
        for (key, value) in patch.names { if let channel = Int(key) { patch.rename(channel, to: value) } }
        if store.applyOutputPatch(patch, expected: base, deviceUID: uid, projectIdentity: projectIdentity, using: playback) {
            base = patch; draft = patch; message = "Patch applied. Save the show to keep it with the project."
        }
    }
}
