import SwiftUI
import SculptShowCore
import CoreAudio

/// Audio setup: the hardware routing engine is activated automatically on launch.
/// Changing physical devices is rejected while cues are active (no interruption).
struct OutputRoutingView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pickedDevice: AudioDeviceID = 0
    @State private var applying = false

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
            HStack(spacing: 8) {
                Circle().fill(playback.routingEnabled ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(playback.routingEnabled
                     ? "ROUTED · \(playback.routingOutputCount) physical outputs"
                     : "AUDIO NOT READY · GO BLOCKED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Text("LIVE SAFETY: Reassign stem outputs and operate the mixer without stopping playback. A hardware device change during playback is refused and the current show continues. Device preference is remembered by Core Audio UID, not transient numeric ID. Routing must be ready before an audio cue can GO. Maximum 16 concurrent mono/stereo stems; MTC controller settings are separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            playback.refreshRoutingDevices()
            pickedDevice = playback.routingDeviceID ?? 0
        }
    }
}
