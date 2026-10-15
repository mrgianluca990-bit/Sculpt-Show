import CoreMIDI
import Foundation
import SwiftUI

// Mappings are local operator preferences, not show-file content.
enum LiveCommand: String, CaseIterable, Identifiable, Codable {
    case go = "GO"
    case pauseAll = "Pause All / Resume All"
    case stopAll = "Stop All"
    case fadeAll = "Fade All"
    case previous = "Previous Cue"
    case next = "Next Cue"
    case nextList = "Next Cue List"
    var id: String { rawValue }
}

struct MIDITrigger: Codable, Hashable {
    var channel: Int    // 0 to 15
    var status: Int     // 0x90 note-on, 0xB0 CC
    var number: Int     // 0 to 127
    var description: String {
        "\(status == 0x90 ? "Note" : "CC") \(number) · Ch \(channel + 1)"
    }
}

@MainActor
final class MIDIControl: ObservableObject {
    struct Source: Identifiable, Hashable {
        var id: MIDIUniqueID
        var endpoint: MIDIEndpointRef
        var name: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var selectedID: MIDIUniqueID?
    @Published private(set) var mappings: [LiveCommand: MIDITrigger] = [:]
    @Published var learning: LiveCommand?
    @Published private(set) var lastMessage = "No MIDI input"
    @Published private(set) var errorMessage: String?
    var onCommand: ((LiveCommand) -> Void)?

    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var endpoint: MIDIEndpointRef = 0
    private var lastHit: [LiveCommand: Date] = [:]
    private var ccHigh: Set<MIDITrigger> = []
    // Running-status decoder handles MIDI messages split across packets.
    private var runningStatus: UInt8 = 0
    private var dataBytes: [UInt8] = []
    private let mappingKey = "sculpt.show.midiMappings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: mappingKey),
           let saved = try? JSONDecoder().decode([LiveCommand: MIDITrigger].self, from: data) {
            mappings = saved
        }
        configure()
        refresh()
    }

    private func configure() {
        let status = MIDIClientCreate("Sculpt Show MIDI Control" as CFString, nil, nil, &client)
        guard status == noErr else { errorMessage = "CoreMIDI client failed (\(status))"; return }
        let portStatus = MIDIInputPortCreateWithBlock(client, "Sculpt Show Control In" as CFString, &port) { [weak self] list, _ in
            let packets = list.unsafeSequence().map { Array($0.sequence()) }
            Task { @MainActor [weak self] in
                for bytes in packets { self?.receive(bytes) }
            }
        }
        if portStatus != noErr { errorMessage = "CoreMIDI input failed (\(portStatus))" }
    }

    func refresh() {
        sources = (0..<MIDIGetNumberOfSources()).compactMap { index -> Source? in
            let candidate = MIDIGetSource(index)
            guard candidate != 0 else { return nil }
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(candidate, kMIDIPropertyUniqueID, &id)
            var nameProperty: Unmanaged<CFString>?
            let result = MIDIObjectGetStringProperty(candidate, kMIDIPropertyDisplayName, &nameProperty)
            let name: String = result == noErr && nameProperty != nil
                ? nameProperty!.takeRetainedValue() as String : "MIDI Source \(index + 1)"
            return Source(id: id, endpoint: candidate, name: name)
        }
        if let selectedID, !sources.contains(where: { $0.id == selectedID }) { disconnect() }
    }

    func connect(_ id: MIDIUniqueID) {
        disconnect()
        guard port != 0, let source = sources.first(where: { $0.id == id }) else { return }
        let result = MIDIPortConnectSource(port, source.endpoint, nil)
        guard result == noErr else { errorMessage = "Cannot connect MIDI input (\(result))"; return }
        endpoint = source.endpoint
        selectedID = id
        errorMessage = nil
        lastMessage = "Waiting for MIDI…"
    }

    func disconnect() {
        if endpoint != 0 && port != 0 { MIDIPortDisconnectSource(port, endpoint) }
        endpoint = 0
        selectedID = nil
        ccHigh.removeAll()
        runningStatus = 0
        dataBytes.removeAll()
    }

    func clear(_ command: LiveCommand) {
        mappings.removeValue(forKey: command)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(mappings) { UserDefaults.standard.set(data, forKey: mappingKey) }
    }

    private func receive(_ packet: [UInt8]) {
        for byte in packet {
            if byte >= 0xF8 { continue } // MIDI realtime
            if byte & 0x80 != 0 {
                if byte < 0xF0 { runningStatus = byte }
                else { runningStatus = 0 }
                dataBytes.removeAll()
                continue
            }
            let kind = Int(runningStatus & 0xF0)
            guard kind == 0x90 || kind == 0x80 || kind == 0xB0 else { continue }
            dataBytes.append(byte)
            guard dataBytes.count == 2 else { continue }
            let number = Int(dataBytes[0]), value = Int(dataBytes[1])
            dataBytes.removeAll()
            let trigger = MIDITrigger(channel: Int(runningStatus & 0x0F), status: kind == 0xB0 ? 0xB0 : 0x90, number: number)
            lastMessage = "\(trigger.description) · value \(value)"
            // Only a positive note-on triggers; CC is edge-triggered at 64.
            if kind == 0x80 || (kind == 0x90 && value == 0) { continue }
            if kind == 0xB0 {
                if value < 64 { ccHigh.remove(trigger); continue }
                guard ccHigh.insert(trigger).inserted else { continue }
            }
            if let learning {
                // One MIDI control can only command one action.
                for command in LiveCommand.allCases where mappings[command] == trigger { mappings.removeValue(forKey: command) }
                mappings[learning] = trigger
                self.learning = nil
                persist()
                continue
            }
            guard let command = LiveCommand.allCases.first(where: { mappings[$0] == trigger }) else { continue }
            let now = Date()
            if let last = lastHit[command], now.timeIntervalSince(last) < 0.16 { continue }
            lastHit[command] = now
            onCommand?(command)
        }
    }
}

struct MIDIControlSettings: View {
    @EnvironmentObject private var midi: MIDIControl
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MIDI CONTROLLER").font(.title3.weight(.bold))
                Spacer()
                Button("Close") { dismiss() }
            }
            HStack {
                Picker("USB MIDI INPUT", selection: Binding(
                    get: { midi.selectedID ?? 0 },
                    set: { $0 == 0 ? midi.disconnect() : midi.connect($0) }
                )) {
                    Text("None").tag(MIDIUniqueID(0))
                    ForEach(midi.sources) { source in Text(source.name).tag(source.id) }
                }
                Button("Refresh") { midi.refresh() }
            }
            Text(midi.lastMessage).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if let error = midi.errorMessage { Text(error).foregroundColor(.orange) }
            Divider()
            ForEach(LiveCommand.allCases) { command in
                HStack(spacing: 12) {
                    Text(command.rawValue).frame(width: 195, alignment: .leading)
                    Text(midi.mappings[command]?.description ?? "Not assigned")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(midi.learning == command ? "Waiting…" : "Learn") {
                        midi.learning = command
                    }
                    Button("Clear") { midi.clear(command) }
                        .disabled(midi.mappings[command] == nil)
                }
            }
            Text("Select a CoreMIDI source, click Learn, and press the desired USB MIDI button. " +
                 "Supports Note On and CC (rising edge ≥64). Mappings are saved on this Mac; " +
                 "only the selected source controls the show.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 650)
    }
}
