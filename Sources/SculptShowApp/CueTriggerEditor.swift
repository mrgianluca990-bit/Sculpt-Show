import SwiftUI
import AppKit
import SculptShowCore

extension ShowStore {
    func fireTriggeredCue(_ id: UUID, using playback: PlaybackEngine) {
        guard !isLoadingProject, let cue = show.cue(id), cue.enabled else { return }
        _ = playback.play(cue, restartPaused: true)
    }
}

struct CueTriggerEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var midi: MIDIControl
    let cue: Cue
    let listID: UUID
    @State private var alias = ""
    @State private var expanded = false
    private var settings: CueTriggers { store.show.cue(cue.id)?.triggers ?? cue.triggers }
    private func update(_ change: (inout CueTriggers) -> Void) {
        var next = settings; change(&next); store.setCueTriggers(next, cueID: cue.id, using: midi)
    }
    var body: some View {
        DisclosureGroup("CUE TRIGGERS · FIRE", isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start this cue directly, independently of the selected cue. Saved with the show.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("KEY")
                CueKeyRecorder(label: settings.key?.label ?? "Click and press a shortcut") { key in update { $0.key = key } }
                    .frame(height: 25)
                Button("Clear") { update { $0.key = nil } }.disabled(settings.key == nil)
            }
            Text("Space, Esc, arrows and existing transport keys stay reserved. Option/Control combinations are available. Text editing never fires a cue.").font(.caption2).foregroundStyle(.secondary)
            HStack {
            Picker("MIDI Input", selection: Binding(get: { midi.selectedID ?? 0 }, set: { if $0 == 0 { midi.disconnect() } else { midi.connect($0) } })) {
                Text("None").tag(Int32(0))
                ForEach(midi.sources) { source in Text(source.name).tag(source.id) }
            }.controlSize(.small)
            Button("Refresh") { midi.refresh() }.controlSize(.small)
            }
            HStack {
                Text(settings.midi?.description ?? "No MIDI trigger").font(.caption)
                Spacer()
                Button(midi.learningCueID == cue.id ? "Cancel Learn" : "Learn MIDI") {
                    midi.learning = nil
                    midi.learningCueID = midi.learningCueID == cue.id ? nil : cue.id
                }.disabled(midi.selectedID == nil)
                Button("Clear") { update { $0.midi = nil } }.disabled(settings.midi == nil)
            }
            Text("MIDI input is shared with global controls; choose it here or in MIDI Setup. Note On or CC rising edge.").font(.caption2).foregroundStyle(.secondary)
            Toggle("Enable OSC Fire trigger", isOn: Binding(get: { settings.oscEnabled }, set: { value in update { $0.oscEnabled = value } }))
            Text("/sculpt/cue/\(cue.id.uuidString)/fire").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            HStack {
                TextField("Optional /sculpt/trigger/name", text: $alias).textFieldStyle(.roundedBorder)
                    .onSubmit { update { $0.oscAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines) } }
                Button("Set alias") { update { $0.oscAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines) } }
            }.disabled(!settings.oscEnabled)
            Text("OSC receiver must be enabled in Audio/MIDI Setup → OSC Control. Duplicate key/MIDI/OSC assignments are rejected.").font(.caption2).foregroundStyle(.secondary)
        }
        }
        .onAppear { alias = settings.oscAlias; midi.refresh() }
        .onDisappear { if midi.learningCueID == cue.id { midi.learningCueID = nil } }
        .onChange(of: expanded) { if !$0 && midi.learningCueID == cue.id { midi.learningCueID = nil } }
    }
}

private struct CueKeyRecorder: NSViewRepresentable {
    let label: String
    let captured: (CueKeyTrigger) -> Void
    final class Field: NSTextField {
        var capture: ((CueKeyTrigger) -> Void)?
        var displayLabel = ""
        override func resignFirstResponder() -> Bool { stringValue = displayLabel; return super.resignFirstResponder() }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self); stringValue = "Press a shortcut… (Esc cancels)"
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
            guard !event.modifierFlags.contains(.command), !event.isARepeat else { return }
            let flags = event.modifierFlags
            let modifiers: UInt8 = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0) | (flags.contains(.control) ? 4 : 0)
            let text = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            capture?(CueKeyTrigger(keyCode: event.keyCode, modifiers: modifiers, label: text))
            window?.makeFirstResponder(nil)
        }
    }
    func makeNSView(context: Context) -> Field {
        let field = Field(); field.isEditable = false; field.isSelectable = false; field.isBezeled = true
        field.setAccessibilityElement(true); field.setAccessibilityRole(.textField)
        field.setAccessibilityLabel("Record cue keyboard trigger"); return field
    }
    func updateNSView(_ field: Field, context: Context) { field.capture = captured; field.displayLabel = label; if field.window?.firstResponder !== field { field.stringValue = label } }
}
