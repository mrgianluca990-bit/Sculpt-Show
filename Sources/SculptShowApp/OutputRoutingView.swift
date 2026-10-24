import SwiftUI
import SculptShowCore
import CoreAudio

/// Audio setup: the hardware routing engine is activated automatically on launch.
/// Changing physical devices is rejected while cues are active (no interruption).
struct OutputRoutingView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var store: ShowStore
    @Environment(\.dismiss) private var dismiss
    @State private var pickedDevice: AudioDeviceID = 0
    @State private var applying = false
    @State private var testChannel = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("OUTPUT ROUTING", systemImage: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Sculpt Show initializes its Core Audio routing automatically. Select a different interface only when the transport is idle. Individual stem OUT assignments and mixer controls update live without stopping cues.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("AUDIO DEVICE", selection: $pickedDevice) {
                Text("Select an output device").tag(AudioDeviceID(0))
                ForEach(playback.routingDevices) { device in
                    Text("\(device.name) · \(device.channels) channels").tag(device.id)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Button("Refresh devices") { playback.refreshRoutingDevices() }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Apply Audio Device") {
                    applying = true
                    Task { @MainActor in
                        await playback.configureRouting(deviceID: pickedDevice == 0 ? nil : pickedDevice)
                        applying = false
                    }
                }
                .disabled(applying || pickedDevice == 0 ||
                          (playback.routingEnabled && playback.routingDeviceID == pickedDevice))
                .buttonStyle(.borderedProminent)
            }
            Divider()
            Picker("PROJECT SAMPLE RATE", selection: Binding(
                get: { store.show.sampleRate },
                set: { store.changeSessionSampleRate($0, using: playback) })) {
                ForEach(Show.supportedSampleRates, id: \.self) { rate in
                    Text(String(format: "%g kHz", Double(rate) / 1000)).tag(rate)
                }
            }
            .disabled(!playback.snapshots.isEmpty || store.preparingSessionAudio || store.pendingAudioImports > 0 || store.isLoadingProject)
            Text("Files with another sample rate are copied and converted offline into the project. Originals are preserved. GO never performs sample-rate conversion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.preparingSessionAudio { ProgressView().controlSize(.small) }
                Text(store.sessionAudioStatus).font(.caption)
                Spacer()
                Button("Prepare / Verify Audio") {
                    store.requestSessionAudioPreparation(using: playback, force: true)
                }.disabled(store.preparingSessionAudio || store.isLoadingProject || store.pendingAudioImports > 0)
            }
            Text("Device: " + String(format: "%g Hz", playback.deviceSampleRate))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 8) {
                Circle().fill(playback.routingEnabled ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(playback.routingEnabled
                     ? "ROUTED · \(playback.routingOutputCount) physical outputs"
                     : "AUDIO NOT READY · GO BLOCKED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Divider()
            HStack(spacing: 10) {
                Text("SPEAKER TEST · 440 Hz / −30 dBFS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Picker("OUT", selection: $testChannel) {
                    ForEach(1...max(1, playback.routingOutputCount), id: \.self) { n in
                        Text("OUT \(n)").tag(n)
                    }
                }
                .frame(width: 130)
                Button(playback.testToneOutput == testChannel ? "STOP TEST" : "PLAY TEST") {
                    playback.toggleTestTone(output: testChannel)
                }
                .disabled(!playback.routingEnabled || !playback.snapshots.isEmpty)
                .tint(playback.testToneOutput == testChannel ? .red : .orange)
                .buttonStyle(.borderedProminent)
                if playback.testToneOutput != nil && playback.testToneOutput != testChannel {
                    Button("STOP") { playback.stopTestTone() }
                }
            }
            Text("Safety: only available with STOP ALL, independent from show cues. A cue GO automatically stops the tone. The mixer mute/solo is respected.")
                .font(.caption).foregroundStyle(.secondary)
            Text("LIVE SAFETY: Reassign stem outputs and operate the mixer without stopping playback. A hardware device change during playback is refused and the current show continues. Device preference is remembered by Core Audio UID, not transient numeric ID. Routing must be ready before an audio cue can GO. Maximum 16 concurrent mono/stereo stems; MTC controller settings are separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            playback.refreshRoutingDevices()
            pickedDevice = playback.routingDeviceID ?? 0
            testChannel = 1
        }
    }
}
