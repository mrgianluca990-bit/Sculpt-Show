import SwiftUI
import SculptShowCore
import CoreAudio

/// Experimental physical-output mode is an explicit operator action.
/// The proven stereo AVAudioPlayer backend stays selected by default.
struct OutputRoutingView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pickedDevice: AudioDeviceID = 0
    @State private var applying = false
    @State private var showingOutputMixer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("OUTPUT ROUTING", systemImage: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Select a Core Audio output device and enable physical channel assignment. Each mono stem routes to one output; stereo stems use two consecutive outputs. This mode has its own multichannel mixer, separate from the current stereo playback engine.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("AUDIO DEVICE", selection: $pickedDevice) {
                Text("System Output · Original stereo engine").tag(AudioDeviceID(0))
                ForEach(playback.routingDevices) { device in
                    Text("\(device.name) · \(device.channels) channels").tag(device.id)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Button("Refresh devices") { playback.refreshRoutingDevices() }
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button(pickedDevice == 0 ? "Use original engine" : "Enable routing") {
                    applying = true
                    Task { @MainActor in
                        await playback.configureRouting(deviceID: pickedDevice == 0 ? nil : pickedDevice)
                        applying = false
                    }
                }
                .disabled(applying)
                .buttonStyle(.borderedProminent)
            }
            Divider()
            HStack(spacing: 8) {
                Button("OUTPUT MIXER") { showingOutputMixer = true }
                    .disabled(!playback.routingEnabled)
                    .help("Open the physical-output Mute/Solo mixer")
                Spacer()
            }
            HStack(spacing: 8) {
                Circle().fill(playback.routingEnabled ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(playback.routingEnabled
                     ? "ROUTED · \(playback.routingOutputCount) physical outputs"
                     : "ORIGINAL STEREO ENGINE ACTIVE")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Text("SAFETY: Switching engines stops all currently playing cues. Output assignments persist in .scshow. Changing devices or starting a show with routing disabled never silently plays mapped outputs through another physical output. The original mode is unchanged. Route mode supports 16 concurrent mono/stereo stems; LTC/MTC and audio input are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
        .sheet(isPresented: $showingOutputMixer) {
            ShowOutputMixerView().environmentObject(playback)
        }
        .onAppear {
            playback.refreshRoutingDevices()
            pickedDevice = playback.routingDeviceID ?? 0
        }
    }
}
