import SwiftUI
import SculptShowCore

/// Docked output console in the main show window. No floating sheet and no
/// audio-graph rebuild when the panel opens/closes or changes banks.
struct ShowOutputMixerView: View {
    @EnvironmentObject private var store: ShowStore
    @State private var section = 0
    @State private var showingMonitorSetup = false
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var bank = 0 // 0 = All, matching the Cue console
    @State private var labels = ShowOutputLabels.load()

    private var channelCount: Int { playback.routingOutputCount }
    private var deviceName: String {
        guard let id = playback.routingDeviceID else { return "CoreAudio" }
        return playback.routingDevices.first(where: { $0.id == id })?.name ?? "CoreAudio"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if playback.routingEnabled && channelCount > 0 {
                Picker("Mixer section", selection: $section) {
                    Text("INPUT · STEMS").tag(0)
                    Text("OUTPUT · PHYSICAL").tag(1)
                }.pickerStyle(.segmented).controlSize(.small)
                if section == 0 { MonitorInputsView() }
                else { activeMixer }
            } else {
                Text("Audio not ready. Open File → Audio/MIDI Setup to select an output device.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: channelCount) { _ in bank = 0 }
        .sheet(isPresented: $showingMonitorSetup) { MonitorSetupView().environmentObject(store).environmentObject(playback) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("MIXER", systemImage: "slider.vertical.3")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(SculptTheme.gold)
            Text("\(deviceName) · \(channelCount) OUT")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if playback.outputControls.anySolo {
                Text("SOLO: \(playback.outputControls.soloDescription)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SculptTheme.warning)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(store.show.monitor.enabled ? "MONITOR \(store.show.monitor.leftOutput)/\(store.show.monitor.rightOutput)" : "ACTIVATE MONITOR") { showingMonitorSetup = true }
                .controlSize(.small).tint(store.show.monitor.enabled ? .cyan : .accentColor)
                .disabled(!playback.routingEnabled || !playback.snapshots.isEmpty || (!store.show.monitor.enabled && channelCount < 2))
            if !playback.inputSoloIDs.isEmpty {
                Button("CLEAR INPUT SOLO") { playback.clearInputSolos() }.controlSize(.small).tint(SculptTheme.warning)
            }
            if section == 1 {
            Button("CLEAR PEAK") { playback.resetOutputPeakHolds() }
                .controlSize(.small)
                .help("Reset all Peak Hold and clip indicators")
                .disabled(!playback.routingEnabled)
            Button("RESET M/S") { playback.resetOutputMuteSolo() }
                .controlSize(.small)
                .disabled(!playback.routingEnabled ||
                    (playback.outputControls.mutedCount == 0 && !playback.outputControls.anySolo && !playback.outputControls.allMuted))
            }
        }
    }

    private var activeMixer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(playback.outputControls.allMuted ? "UNMUTE ALL" : "MUTE ALL") { playback.toggleMuteAllOutputs() }
                    .tint(playback.outputControls.allMuted ? .red : .accentColor).controlSize(.small)
                Toggle("Exclude Monitor", isOn: Binding(get: { store.show.monitor.excludeFromMuteAll }, set: {
                    store.setMonitorMix(excludeFromMuteAll: $0, using: playback)
                })).toggleStyle(.checkbox).font(.caption).disabled(!store.show.monitor.enabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("BANK")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Picker("Bank", selection: $bank) {
                    ForEach(OutputMixerBanks.banks(channelCount: channelCount), id: \.self) { number in
                        Text(OutputMixerBanks.title(channelCount: channelCount, bank: number))
                            .tag(number)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                Text("Peak / RMS · dBFS   |   M = Mute   S = Solo")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Give the strips the dock's ACTUAL current height. The VSplitView
            // divider can move without rebuilding the audio engine or meters.
            GeometryReader { available in
                // Number/title, held dB, mute/solo, label and strip padding
                // reserve ~105 points. Use the remainder for a long VU strip.
                let height = max(36, available.size.height - 110)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 3) {
                        ForEach(OutputMixerBanks.channels(channelCount: channelCount, bank: bank), id: \.self) { channel in
                            OutputChannelStrip(meter: playback.meterMonitor,
                                               channel: channel,
                                               deviceName: deviceName,
                                               channelCount: channelCount,
                                               meterHeight: height,
                                               labels: $labels)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(width: available.size.width, height: available.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OutputChannelStrip: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @ObservedObject var meter: OutputMeterMonitor
    let channel: Int
    let deviceName: String
    let channelCount: Int
    let meterHeight: CGFloat
    @Binding var labels: ShowOutputLabels
    @State private var editing = false
    @State private var labelDraft = ""
    @FocusState private var focused: Bool


    private var muted: Bool { playback.outputControls.isMuted(channel) }
    private var soloed: Bool { playback.outputControls.isSoloed(channel) }
    private var levels: (peak: Float, rms: Float) { meter.level(channel: channel) }
    private var hold: Float { meter.peakHold(channel: channel) }
    private var currentLabel: String {
        labels.label(device: deviceName, channels: channelCount, channel: channel)
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: "%02d", channel))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(playback.generatedLTC?.output == channel ? .orange : .primary)
            signalMeter
            Text(hold >= 1 ? "CLIP" :
                String(format: "%.0f", max(-90, OutputMeterLevels.dBFS(hold))))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(hold >= 1 ? .red : .secondary)
                .monospacedDigit()
                .help("Held peak dBFS. Press CLEAR PEAK to reset")
            HStack(spacing: 2) {
                switchButton(letter: "M", isActive: muted, activeColor: .red,
                             help: "Mute output \(channel)") {
                    playback.toggleOutputMute(channel)
                }
                switchButton(letter: "S", isActive: soloed, activeColor: .yellow,
                             help: "Solo output \(channel)") {
                    playback.toggleOutputSolo(channel)
                }
            }
            if playback.monitorOutputs.contains(channel) {
                Text("MON").font(.system(size: 9, weight: .bold)).foregroundStyle(SculptTheme.accent)
            } else if playback.generatedLTC?.output == channel {
                Text("LTC")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(SculptTheme.gold)
                    .help("This output is carrying SMPTE LTC, not program audio")
            } else {
                labelView
            }
        }
        .frame(width: 51)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.11), in: RoundedRectangle(cornerRadius: 4))
    }

    /// A real illuminated, latched indicator rather than a tint on a gray
    /// bordered system button (whose fill never changed on some macOS skins).
    private func switchButton(letter: String, isActive: Bool, activeColor: Color,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundColor(isActive ? SculptTheme.base : SculptTheme.soft)
                .frame(width: 19, height: 18)
                .background(isActive ? activeColor : SculptTheme.base,
                            in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isActive ? activeColor : SculptTheme.stroke, lineWidth: 1))

        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .accessibilityValue(isActive ? "On" : "Off")
        .help(help + (isActive ? " · ACTIVE" : " · inactive"))
    }

    /// Measured after the physical routing matrix. The cap is a held sampled
    /// peak; it is NOT an oversampled analogue true-peak measurement.
    private var signalMeter: some View {
        let rmsValue = CGFloat(OutputMeterLevels.normalized(levels.rms))
        let peakValue = CGFloat(OutputMeterLevels.normalized(levels.peak))
        let heldValue = CGFloat(OutputMeterLevels.normalized(hold))
        let currentColor: Color = peakValue > 0.98 ? SculptTheme.meterClip : peakValue > 0.83 ? SculptTheme.meterAmber : SculptTheme.meterGreen
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.48))
                .frame(width: 17, height: meterHeight)
            RoundedRectangle(cornerRadius: 2)
                .fill(SculptTheme.meterGreen.opacity(0.85))
                .frame(width: 17, height: meterHeight * rmsValue)
            if levels.peak > 0 {
                Rectangle()
                    .fill(currentColor)
                    .frame(width: 17, height: 2)
                    .offset(y: -max(0, meterHeight * peakValue - 2))
            }
            if hold > 0 {
                Rectangle()
                    .fill(hold >= 1 ? SculptTheme.meterClip : SculptTheme.meterAmber)
                    .frame(width: 17, height: 2)
                    .offset(y: -max(0, meterHeight * heldValue - 2))
            }
        }
        .frame(width: 17, height: meterHeight)
        .help("POST-ROUTE Peak \(Int(OutputMeterLevels.dBFS(levels.peak))) dBFS · RMS \(Int(OutputMeterLevels.dBFS(levels.rms))) dBFS · Hold \(Int(OutputMeterLevels.dBFS(hold))) dBFS")
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
                .frame(width: 48)
        } else {
            Button {
                labelDraft = currentLabel
                editing = true
                focused = true
            } label: {
                Text(currentLabel.isEmpty ? "OUT" : currentLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 48)
            }
            .buttonStyle(.plain)
            .help("Rename channel · Return saves")
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
