import SwiftUI
import SculptShowCore

struct CueMessageEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var midi: MIDIControl
    let cueID: UUID
    let listID: UUID
    @State private var expanded = false
    private var settings: CueTriggers { store.show.cue(cueID)?.triggers ?? CueTriggers() }
    private func update(_ body: (inout CueTriggers) -> Void) { var value = settings; body(&value); store.setCueTriggers(value, cueID: cueID, using: midi) }
    var body: some View {
        DisclosureGroup("SENDS · MIDI / OSC / TIMECODE", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let cue = store.show.cue(cueID) { CueTimecodeSendEditor(cue: cue, listID: listID).id(cueID) }
                Divider()
                Text("MIDI / OSC · Sent once at each new GO, including timecode/rule GO. Resume, seek and native loops do not resend. Messages run on the control queue, not sample-locked to audio.").font(.caption2).foregroundStyle(.secondary)
                ForEach(settings.midiMessages ?? []) { message in
                    MIDIMessageRow(message: message) { next in update { value in
                        guard let index = value.midiMessages?.firstIndex(where: { $0.id == message.id }) else { return }; value.midiMessages?[index] = next
                    } } remove: { update { $0.midiMessages?.removeAll { $0.id == message.id } } }
                }
                HStack {
                    Button("Add MIDI") { if let target = midi.destinations.first { update { if $0.midiMessages == nil { $0.midiMessages = [] }; $0.midiMessages?.append(CueMIDIMessage(destination: target.id)) } } }
                        .disabled(midi.destinations.isEmpty || (settings.midiMessages?.count ?? 0) >= 16)
                    Button("Refresh outputs") { midi.refresh() }
                }.controlSize(.small)
                if midi.destinations.isEmpty { Text("Connect a MIDI destination or enable an IAC bus.").font(.caption2) }
                Divider()
                ForEach(settings.oscMessages ?? []) { message in
                    OSCMessageRow(message: message) { next in update { value in
                        guard let index = value.oscMessages?.firstIndex(where: { $0.id == message.id }) else { return }; value.oscMessages?[index] = next
                    } } remove: { update { $0.oscMessages?.removeAll { $0.id == message.id } } }
                }
                Button("Add OSC") { update { if $0.oscMessages == nil { $0.oscMessages = [] }; $0.oscMessages?.append(CueOSCMessage()) } }.controlSize(.small).disabled((settings.oscMessages?.count ?? 0) >= 16)
                Text("OSC UDP to an IPv4 address; no argument or one int/float/string. Outputs work independently of the OSC receiver. Avoid routing messages back to this cue's own trigger.").font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }
    }
}

private struct MIDIMessageRow: View {
    @EnvironmentObject private var midi: MIDIControl
    let message: CueMIDIMessage
    let save: (CueMIDIMessage) -> Void
    let remove: () -> Void
    private func binding<T>(_ path: WritableKeyPath<CueMIDIMessage,T>) -> Binding<T> { Binding(get: { message[keyPath: path] }, set: { var next = message; next[keyPath: path] = $0; save(next) }) }
    var body: some View {
        VStack(alignment: .leading) {
            Picker("MIDI OUT", selection: binding(\.destination)) {
                if !midi.destinations.contains(where: { $0.id == message.destination }) { Text("Unavailable · \(message.destination)").tag(message.destination) }
                ForEach(midi.destinations) { Text($0.name).tag($0.id) }
            }
            Picker("Message", selection: binding(\.status)) {
                Text("Note On").tag(0x90); Text("Note Off").tag(0x80); Text("CC").tag(0xB0); Text("Program Change").tag(0xC0)
            }
            Stepper("Channel \(message.channel + 1)", value: binding(\.channel), in: 0...15)
            Stepper("\(message.status == 0xC0 ? "Program (0–127)" : "Number") \(message.number)", value: binding(\.number), in: 0...127)
            if message.status != 0xC0 { Stepper("Value \(message.value)", value: binding(\.value), in: 0...127) }
            Button("Remove MIDI", action: remove).controlSize(.small)
        }.font(.caption)
    }
}

private struct OSCMessageRow: View {
    let message: CueOSCMessage
    let save: (CueOSCMessage) -> Void
    let remove: () -> Void
    @State private var draft = CueOSCMessage()
    var body: some View {
        VStack(alignment: .leading) {
            HStack { TextField("IPv4", text: $draft.host); TextField("Port", value: $draft.port, format: .number.grouping(.never)).frame(width: 65) }
            TextField("OSC address", text: $draft.address)
            Picker("Argument", selection: $draft.argument) { ForEach(CueOSCArgument.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if draft.argument != .none { TextField("Value", text: $draft.value) }
            HStack { Button("Apply OSC") { save(draft) }.disabled(!draft.isValid); Button("Remove OSC", action: remove) }.controlSize(.small)
            if !draft.isValid { Text("Enter a valid IPv4, port, literal path and argument.").foregroundStyle(.orange).font(.caption2) }
        }.textFieldStyle(.roundedBorder).onAppear { draft = message }.onChange(of: message) { draft = $0 }
    }
}
