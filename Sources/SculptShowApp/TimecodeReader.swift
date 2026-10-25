import SwiftUI
import Foundation
import AVFAudio
import AudioToolbox
import CoreAudio
import SculptLTCCore
import SculptShowCore

/// External SMPTE LTC AUDIO receiver. Reads a mono channel of a selected
/// Core Audio INPUT device. The DSP encoder and decoder share their SMPTE
/// implementation but run in separate audio engines and never loop back in-app.
@MainActor
final class LTCInputReader: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let channels: Int
    }

    @Published private(set) var devices: [Device] = []
    @Published var pickedID: AudioDeviceID = 0
    @Published var channel = 1
    @Published var rate: LTCFrameRate = .fps25
    @Published private(set) var running = false
    let signal = LTCSignalDisplay()
    private(set) var locked = false { didSet { if locked != oldValue { signal.locked = locked } } }
    private(set) var received = "--:--:--:--" { didSet { if received != oldValue { signal.received = received } } }
    @Published var errorMessage: String?

    @Published var triggersArmed = false { didSet { scheduler.reset() } }
    @Published private(set) var lastTrigger = "No timecode cue fired"
    var showProvider: (() -> Show?)?
    var onCue: ((UUID) -> Void)?
    private var scheduler = TimecodeCueScheduler()

    func accept(_ address: LTCTimecode, at stamp: Double = ProcessInfo.processInfo.systemUptime) {
        received = address.display; locked = true; lastValid = Date()
        guard triggersArmed, let show = showProvider?() else { return }
        for id in scheduler.consume(address, at: stamp, in: show) {
            lastTrigger = "\(show.cue(id)?.name ?? "Cue") · \(address.display)"
            onCue?(id)
        }
    }

    private var engine: AVAudioEngine?
    private var decoder: OpaquePointer?
    private var watchdog: Timer?
    private var lastValid: Date?

    init() {
        refreshDevices()
        if let uid = UserDefaults.standard.string(forKey: "SculptShow.LTCIn.UID"),
           let saved = devices.first(where: { $0.uid == uid }) { pickedID = saved.id }
        let preferred = UserDefaults.standard.integer(forKey: "SculptShow.LTCIn.Channel")
        if preferred > 0 { channel = preferred }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let last = self.lastValid, Date().timeIntervalSince(last) > 0.7 {
                    self.locked = false; self.scheduler.reset()
                }
            }
        }
    }

    deinit {
        watchdog?.invalidate()
        engine?.stop()
        if let decoder { sculpt_ltc_decoder_destroy(decoder) }
    }

    static func availableInputs() -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr,
                  bytes >= UInt32(MemoryLayout<AudioBufferList>.size) else { return nil }
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes),
                                                        alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { ptr.deallocate() }
            guard AudioObjectGetPropertyData(id, &streams, 0, nil, &bytes, ptr) == noErr else { return nil }
            let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
            let count = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard count > 0 else { return nil }
            func property(_ name: AudioObjectPropertySelector) -> String {
                var prop = AudioObjectPropertyAddress(mSelector: name,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var len = UInt32(MemoryLayout<CFString>.size)
                if AudioObjectGetPropertyData(id, &prop, 0, nil, &len, &value) == noErr,
                   let value { return value.takeRetainedValue() as String }
                return ""
            }
            return Device(id: id, name: property(kAudioObjectPropertyName),
                          uid: property(kAudioDevicePropertyDeviceUID), channels: count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshDevices() { devices = Self.availableInputs() }

    func start() {
        guard !running else { return }
        errorMessage = nil
        scheduler.reset()
        guard let device = devices.first(where: { $0.id == pickedID }),
              (1...device.channels).contains(channel) else {
            errorMessage = "Choose a connected Core Audio INPUT and channel first."
            return
        }
        let graph = AVAudioEngine()
        let input = graph.inputNode
        guard let unit = input.audioUnit else {
            errorMessage = "Core Audio input unavailable."
            return
        }
        var id = device.id
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                      kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard err == noErr else {
            errorMessage = "Cannot select LTC input \(device.name), Core Audio OSStatus \(err)."
            return
        }
        let format = input.outputFormat(forBus: 0)
        guard Int(format.channelCount) >= channel, format.sampleRate >= 8_000,
              !format.isInterleaved,
              format.commonFormat == .pcmFormatFloat32,
              let decoder = sculpt_ltc_decoder_create(Float(format.sampleRate),
                                                      Int32(rate.rawValue)) else {
            errorMessage = "Input must expose Float32 PCM with the chosen channel."
            return
        }
        self.decoder = decoder
        let idx = channel - 1
        // Copy PCM to the main actor; never perform BMC decoding or publish
        // SwiftUI state in the real-time hardware input callback.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let pcm = buffer.floatChannelData,
                  idx < Int(buffer.format.channelCount) else { return }
            let copy = Array(UnsafeBufferPointer(start: pcm[idx], count: Int(buffer.frameLength)))
            DispatchQueue.main.async { [weak self] in self?.ingest(copy) }
        }
        do {
            try graph.start()
            engine = graph
            running = true
            locked = false
            received = "--:--:--:--"
            lastValid = nil
            UserDefaults.standard.set(device.uid, forKey: "SculptShow.LTCIn.UID")
            UserDefaults.standard.set(channel, forKey: "SculptShow.LTCIn.Channel")
        } catch {
            input.removeTap(onBus: 0)
            graph.stop()
            sculpt_ltc_decoder_destroy(decoder)
            self.decoder = nil
            errorMessage = "LTC input start failed: \(error.localizedDescription)"
        }
    }

    private func ingest(_ samples: [Float]) {
        guard running, let decoder else { return }
        var address = SculptLTCAddress()
        let decoded = samples.withUnsafeBufferPointer { ptr in
            sculpt_ltc_decoder_consume(decoder, ptr.baseAddress,
                                       UInt32(ptr.count), &address)
        }
        if decoded != 0 {
            let text = String(format: "%02d:%02d:%02d%@%02d", address.hours,
                address.minutes, address.seconds, address.drop_frame != 0 ? ";" : ":", address.frames)
            if let timecode = LTCTimecode(text: text, rate: rate) { accept(timecode) }
        }
    }

    func stop() {
        if let graph = engine {
            graph.inputNode.removeTap(onBus: 0)
            graph.stop()
        }
        engine = nil
        if let decoder { sculpt_ltc_decoder_destroy(decoder) }
        decoder = nil
        running = false
        triggersArmed = false
        scheduler.reset()
        locked = false
        lastValid = nil
    }
}

/// Side-by-side LTC generated/received display; reader is genuinely audio LTC,
/// not MTC quarter-frame from a different source.
struct TimecodeReaderView: View {
    @EnvironmentObject private var reader: LTCInputReader
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("SMPTE LTC MONITOR", systemImage: "clock")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(SculptTheme.gold)
                Divider()
                GeneratedLTCDisplay(clock:playback.displayClock)
                Divider()
                ReceivedLTCDisplay(signal:reader.signal)
                Toggle("ARM CUE TIMECODE TRIGGERS", isOn: $reader.triggersArmed)
                Text("LTC input → cue GO at the address set in General. Forward crossings only; no continuous chase. Stop input disarms triggers.").font(.caption2).foregroundStyle(.secondary)
                Text(reader.lastTrigger).font(.caption2)
                HStack(spacing: 5) {
                    Picker("INPUT", selection: $reader.pickedID) {
                        Text("Select device").tag(AudioDeviceID(0))
                        ForEach(reader.devices) { device in
                            Text("\(device.name) · \(device.channels) IN").tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(reader.running)
                    Picker("IN", selection: $reader.channel) {
                        ForEach(1...max(1,reader.devices.first(where: { $0.id == reader.pickedID })?.channels ?? 1), id: \.self) { n in
                            Text("IN \(n)").tag(n)
                        }
                    }
                    .frame(width: 95)
                    .disabled(reader.running)
                }
                Picker("FPS", selection: $reader.rate) {
                    ForEach(LTCFrameRate.allCases, id: \.rawValue) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(reader.running)
                HStack {
                    Button(reader.running ? "STOP INPUT" : "START INPUT") {
                        if reader.running { reader.stop() } else { reader.start() }
                    }
                    .controlSize(.small)
                    .disabled(!reader.running && !playback.snapshots.isEmpty)
                    .help("Configure LTC INPUT before playing cues; changing capture devices during a show is locked for safety")
                    Button { reader.refreshDevices() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Refresh Core Audio input devices")
                    .disabled(reader.running)
                    Spacer()
                }
                if let error = reader.errorMessage {
                    Text(error).font(.caption2).foregroundColor(SculptTheme.gold)
                }
                Text("To verify LTC, patch the dedicated LTC OUT to a Core Audio input or loopback. " +
                     "The receiver decodes actual biphase-mark PCM. Use matching frame rates. " +
                     "Speaker outputs must never carry unintended LTC.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeneratedLTCDisplay: View {
    @ObservedObject var clock: PlaybackDisplayClock
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("GENERATED · LTC AUDIO OUT")
                    Spacer()
                    Text(clock.generatedLTC?.holding == true ? "HOLD" :
                         clock.generatedLTC?.active == true ? "RUN" : "STOP")
                        .foregroundColor(clock.generatedLTC?.holding == true ? .orange : .secondary)
                    Circle().fill(clock.generatedLTC?.active == true ? Color.green :
                                  clock.generatedLTC?.holding == true ? .orange : .gray)
                        .frame(width: 8, height: 8)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(clock.generatedLTC?.timecode ?? "--:--:--:--")
                    .font(.system(size: 31, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundColor(clock.generatedLTC?.active == true ? .green :
                                     clock.generatedLTC?.holding == true ? .orange : .secondary)
                if let state = clock.generatedLTC {
                    Text("\(state.cueName) · OUT \(state.output) · \(state.rate)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

        }
    }
}

@MainActor final class LTCSignalDisplay: ObservableObject {
    @Published var locked = false
    @Published var received = "--:--:--:--"
}
private struct ReceivedLTCDisplay: View {
    @ObservedObject var signal: LTCSignalDisplay
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("RECEIVED · LTC AUDIO IN")
                    Spacer()
                    Circle().fill(signal.locked ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(signal.received)
                    .font(.system(size: 31, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundColor(signal.locked ? .green : .secondary)
                Text(signal.locked ? "LTC LOCKED" : "WAITING FOR LTC")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(signal.locked ? .green : .orange)

        }
    }
}
