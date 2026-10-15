import SwiftUI
import SculptShowCore

/// First Cue Native → Show convergence: controls the REAL Core Audio MatrixMixer.
struct ShowOutputMixerView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var bank = 1
    @State private var labels = ShowOutputLabels.load()

    private var channelCount: Int { playback.routingOutputCount }
    private var deviceName: String {
        guard let id = playback.routingDeviceID else { return "CoreAudio" }
        return playback.routingDevices.first(where: { $0.id == id })?.name ?? "CoreAudio"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if playback.routingEnabled && channelCount > 0 {
                activeMixer
            } else {
                Text("Enable OUTPUT ROUTING and select a Core Audio interface to control individual outputs. System stereo playback is unchanged.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 340)
        .onChange(of: channelCount) { _ in bank = 1 }
    }

    private var header: some View {
        HStack {
            Label("SCULPT OUTPUT MIXER", systemImage: "slider.vertical.3")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Spacer()
            Button("RESET M/S") { playback.resetOutputMuteSolo() }
                .disabled(!playback.routingEnabled ||
                    (playback.outputControls.mutedCount == 0 && !playback.outputControls.anySolo))
            Button("Close") { dismiss() }
        }
    }

    private var activeMixer: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        OutputChannelStrip(channel: channel,
                                           deviceName: deviceName,
                                           channelCount: channelCount,
                                           labels: $labels)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            Text("M = mute individual output · S = multi-solo · mute overrides solo. Switches affect the MatrixMixer's physical outputs without restarting audio. Levels reset when routing is disabled or the device changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OutputChannelStrip: View {
    @EnvironmentObject private var playback: PlaybackEngine
    let channel: Int
    let deviceName: String
    let channelCount: Int
    @Binding var labels: ShowOutputLabels
    @State private var editing = false
    @State private var labelDraft = ""
    @FocusState private var focused: Bool

    private var muted: Bool { playback.outputControls.isMuted(channel) }
    private var soloed: Bool { playback.outputControls.isSoloed(channel) }
    private var audible: Bool { playback.outputControls.isAudible(channel) }
    private var currentLabel: String {
        labels.label(device: deviceName, channels: channelCount, channel: channel)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(String(format: "%02d", channel))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            RoundedRectangle(cornerRadius: 3)
                .fill(audible ? Color.green.opacity(0.65) : Color.gray.opacity(0.30))
                .frame(width: 14, height: 66)
                .help("Output enabled status, not a peak meter")
            Button("M") { playback.toggleOutputMute(channel) }
                .buttonStyle(.bordered)
                .tint(muted ? .red : .gray)
                .help("Mute output \(channel)")
            Button("S") { playback.toggleOutputSolo(channel) }
                .buttonStyle(.bordered)
                .tint(soloed ? .yellow : .gray)
                .help("Solo output \(channel)")
            labelView
        }
        .frame(width: 46)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var labelView: some View {
        if editing {
            TextField("Name", text: $labelDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit { commitLabel() }
        } else {
            Button {
                labelDraft = currentLabel
                editing = true
                focused = true
            } label: {
                Text(currentLabel.isEmpty ? "OUT" : currentLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 42)
            }
            .buttonStyle(.plain)
            .help("Click to rename; Return saves")
        }
    }

    private func commitLabel() {
        labels.rename(labelDraft, device: deviceName, channels: channelCount, channel: channel)
        labels.save()
        editing = false
        focused = false
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
