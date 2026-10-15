import CoreMIDI
import Foundation
import SculptShowCore
import SwiftUI

/// A *real* MTC input reader, independent of the cue's editable timecode elements.
/// Incoming MIDI packets are copied on the CoreMIDI thread and decoded on MainActor.
/// This version reads MIDI Time Code quarter-frame; LTC audio decoding is not present.
@MainActor
final class TimecodeReader: ObservableObject {
    struct Source: Identifiable, Hashable {
        let id: MIDIUniqueID
        let endpoint: MIDIEndpointRef
        let name: String
        static func == (l: Source, r: Source) -> Bool { l.id == r.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var selectedID: MIDIUniqueID?
    @Published private(set) var frame: MTCFrame?
    @Published private(set) var locked = false
    @Published private(set) var error: String?

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedEndpoint: MIDIEndpointRef = 0
    private var decoder = MTCDecoder()
    private var awaitingQuarterFrameData = false
    private var lastMessageTime: Date?
    private var watchdog: Timer?

    init() {
        setupMIDI()
        refreshSources()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignal() }
        }
    }

    deinit {
        watchdog?.invalidate()
        if inputPort != 0 {
            if connectedEndpoint != 0 {
                MIDIPortDisconnectSource(inputPort, connectedEndpoint)
            }
            MIDIPortDispose(inputPort)
        }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func setupMIDI() {
        let created = MIDIClientCreate("Sculpt Show Timecode" as CFString, nil, nil, &client)
        guard created == noErr else { error = "Unable to initialize CoreMIDI (\(created))."; return }
        let status = MIDIInputPortCreateWithBlock(client, "MTC Reader" as CFString, &inputPort) { [weak self] packetList, _ in
            // These unsafe sequences traverse the original variable-length CoreMIDI
            // buffers without copying MIDIPacket headers or assuming a fixed stride.
            let packets = packetList.unsafeSequence().map { Array($0.sequence()) }
            guard !packets.isEmpty else { return }
            Task { @MainActor [weak self] in
                for data in packets { self?.consume(data) }
            }
        }
        if status != noErr { error = "Unable to create MIDI input port (\(status))." }
    }

    func refreshSources() {
        let count = MIDIGetNumberOfSources()
        sources = (0..<count).compactMap { index -> Source? in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var identifier: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &identifier)
            var displayName: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &displayName)
            let title: String
            if status == noErr, let displayName { title = displayName.takeRetainedValue() as String }
            else { title = "MIDI Source \(index + 1)" }
            return Source(id: identifier, endpoint: endpoint, name: title)
        }
        if let selectedID, !sources.contains(where: { $0.id == selectedID }) {
            disconnect()
        }
    }

    func connect(to id: MIDIUniqueID) {
        guard inputPort != 0, let source = sources.first(where: { $0.id == id }) else { return }
        disconnect()
        let status = MIDIPortConnectSource(inputPort, source.endpoint, nil)
        guard status == noErr else { error = "Cannot connect MIDI source (\(status))."; return }
        connectedEndpoint = source.endpoint
        selectedID = id
        error = nil
    }

    func disconnect() {
        if connectedEndpoint != 0 && inputPort != 0 { MIDIPortDisconnectSource(inputPort, connectedEndpoint) }
        connectedEndpoint = 0
        selectedID = nil
        decoder.reset()
        frame = nil
        locked = false
        lastMessageTime = nil
        awaitingQuarterFrameData = false
    }

    private func consume(_ packet: [UInt8]) {
        for byte in packet {
            if byte >= 0xF8 { continue } // realtime clocks may interleave within F1 packets
            if byte == 0xF1 { awaitingQuarterFrameData = true; continue }
            if byte & 0x80 != 0 { awaitingQuarterFrameData = false; continue }
            guard awaitingQuarterFrameData else { continue }
            awaitingQuarterFrameData = false
            lastMessageTime = Date()
            if let latest = decoder.ingestQuarterFrame(byte) {
                frame = latest
                locked = true
            }
        }
    }

    private func checkSignal() {
        if let lastMessageTime, Date().timeIntervalSince(lastMessageTime) > 0.75 {
            locked = false
            decoder.reset()
        }
    }
}

struct TimecodeReaderView: View {
    @EnvironmentObject private var reader: TimecodeReader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("TIMECODE READER").font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
            }
            Text(reader.frame?.display ?? "--:--:--:--")
                .font(.system(size: 43, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(reader.locked ? .green : .secondary)
            HStack {
                Circle().fill(reader.locked ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(reader.locked ? "MTC SIGNAL RECEIVED" : "WAITING FOR MTC")
                Spacer()
                if let f = reader.frame { Text("\(f.nominalFPS) fps\(f.dropFrame ? " DF" : "")") }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            HStack {
                Picker("MIDI INPUT", selection: Binding(
                    get: { reader.selectedID ?? 0 },
                    set: { if $0 == 0 { reader.disconnect() } else { reader.connect(to: $0) } }
                )) {
                    Text("None").tag(MIDIUniqueID(0))
                    ForEach(reader.sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                Button("Refresh") { reader.refreshSources() }
            }
            if let error = reader.error { Text(error).foregroundColor(.orange).font(.caption) }
            Text("Reads incoming MIDI Time Code quarter-frame messages from a CoreMIDI source. " +
                 "The final field shows FRAMES, not milliseconds. This reader does not decode LTC audio yet, " +
                 "and does not chase playback or trigger cue rules in this version.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
    }
}
