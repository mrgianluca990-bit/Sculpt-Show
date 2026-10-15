import SwiftUI
import SculptShowCore

/// First Cue Native -> Show convergence slice.
/// Output gain switches are applied by Show's own single routed engine.
struct ShowOutputMixerView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var bank = 1
    @State private var labels = ShowOutputLabels.load()
    @State private var editingChannel: Int?
    @State private var labelDraft = ""
    @FocusState private var labelEditorFocused: Bool

    private var deviceName: String {
        guard let id = playback.routingDeviceID else { return "CoreAudio" }
        return playback.routingDevices.first(where: { $0.id == id })?.name ?? "CoreAudio"
    }
    private var channelCount: Int { playback.routingOutputCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SCULPT OUTPUT MIXER", systemImage: "slider.vertical.3")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button("RESET M/S") { playback.resetOutputMuteSolo() }
                    .disabled(!playback.routingEnabled ||
                              playback.outputControls.mutedCount + playback.outputControls.soloCount == 0)
                Button("Close") { dismiss() }
            }
            if playback.routingEnabled && channelCount > 0 {
                HStack {
                    Text("\(deviceName) · \(channelCount) OUT")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if playback.outputControls.anySolo {
                        Text("SOLO ACTIVE: \(playback.outputControls.soloDescription)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                }
                Picker("Bank", selection: $bank) {
                    ForEach(OutputMixerBanks.banks(channelCount: channelCount), id: \.self) { number in
                        Text(OutputMixerBanks.title(channelCount: channelCount, bank: number))
                            .tag(number)
                    }
                }
                .pickerStyle(.segmented)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(OutputMixerBanks.channels(channelCount: channelCount, bank: bank), id: \.self) { channel in
                            channelStrip(channel)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                Text("M = mute individual output · S = multi-solo · mute overrides solo. Controls affect the actual MatrixMixer output gain while audio is playing. Levels reset when routing is disabled or the device changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enable OUTPUT ROUTING and select a Core Audio interface to control individual outputs. System stereo playback is unchanged.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 340)
        .onChange(of: channelCount) { _ in
            bank = 1
            editingChannel = nil
        }
    }

    private func channelStrip(_ channel: Int) -> some View {
        let muted = playback.outputControls.isMuted(channel)
        let soloed = playback.outputControls.isSoloed(channel)
        let audible = playback.outputControls.isAudible(channel)
        return VStack(spacing: 7) {
            Text(String(format: "%02d", channel))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            RoundedRectangle(cornerRadius: 3)
                .fill(audible ? Color.green.opacity(0.65) : Color.gray.opacity(0.30))
                .frame(width: 14, height: 66)
                .help("Output enabled status (not an audio meter)")
            Button("M") { playback.toggleOutputMute(channel) }
                .buttonStyle(.bordered)
                .tint(muted ? .red : .gray)
                .help("Mute output \(channel)")
            Button("S") { playback.toggleOutputSolo(channel) }
                .buttonStyle(.bordered)
                .tint(soloed ? .yellow : .gray)
                .help("Solo output \(channel)")
            if editingChannel == channel {
                TextField("Name", text: $labelDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.center)
                    .focused($labelEditorFocused)
                    .onSubmit { commitLabel(for: channel) }
            } else {
                Button {
                    labelDraft = labels.label(device: deviceName, channels: channelCount, channel: channel)
                    editingChannel = channel
                    labelEditorFocused = true
                } label: {
                    Text(labels.label(device: deviceName, channels: channelCount, channel: channel).isEmpty
                         ? "OUT" : labels.label(device: deviceName, channels: channelCount, channel: channel))
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 42)
                }
                .buttonStyle(.plain)
                .help("Click to rename; Return saves")
            }
        }
        .frame(width: 46)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private func commitLabel(for channel: Int) {
        labels.rename(labelDraft, device: deviceName, channels: channelCount, channel: channel)
        labels.save()
        editingChannel = nil
        labelEditorFocused = false
    }
}

private struct ShowOutputLabels: Codable {
    var values: [String: [String: String]] = [:]
    static let storageKey = "SculptShow.outputLabels.cueConvergence.v1"
    private static func key(device: String, channels: Int) -> String { "\(device)|\(channels)" }

    func label(device: String, channels: Int, channel: Int) -> String {
        values[Self.key(device: device, channels: channels)]?[String(channel)] ?? ""
    }
    mutating func rename(_ name: String, device: String, channels: Int, channel: Int) {
        guard channel > 0 && channel <= channels else { return }
        let deviceKey = Self.key(device: device, channels: channels)
        let safe = String(name.replacingOccurrences(of: "\n", with: " ")
                              .replacingOccurrences(of: "\r", with: " ")
                              .trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if safe.isEmpty {
            values[deviceKey]?.removeValue(forKey: String(channel))
        } else {
            values[deviceKey, default: [:]][String(channel)] = safe
        }
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let obj = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return obj
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}
