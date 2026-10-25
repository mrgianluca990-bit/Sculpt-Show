import SwiftUI
import SculptShowCore

/// Separate editor prevents the main playback workspace from becoming a giant SwiftUI expression.
struct RulesEditor: View {
    @EnvironmentObject private var store: ShowStore
    @Environment(\.dismiss) private var dismiss

    let scope: RuleScope
    @State private var localRules: [InteractionRule] = []
    @State private var selectedID: UUID?
    @State private var draft = InteractionRule()
    @State private var ignoreParents = false

    private var allCues: [Cue] { store.show.cueLists.flatMap(\.cues) }
    private var isMarkerRule: Bool {
        if case .marker = scope { return true }
        return false
    }

    /// Destination marker choices follow the target (itself or a specific cue).
    private var destinationMarkers: [CueMarker] {
        switch draft.target {
        case .itself:
            switch scope {
            case .marker(_, let cueID), .cue(let cueID, _):
                return store.show.cue(cueID)?.sortedMarkers ?? []
            default: return []
            }
        case .specificCue:
            return draft.targetID.flatMap(store.show.cue)?.sortedMarkers ?? []
        default: return []
        }
    }
    private var scopeName: String {
        switch scope {
        case .show: return "Show: \(store.show.name)"
        case .cueList(let id): return "Cue List: \(store.show.cueLists.first(where: { $0.id == id })?.name ?? "Missing")"
        case .cue(let id, _): return "Cue: \(store.show.cue(id)?.name ?? "Missing")"
        case .marker(let markerID, let cueID):
            let cue = store.show.cue(cueID)
            let marker = cue?.markers.first(where: { $0.id == markerID })
            return "Marker: \(marker?.name ?? "Missing") · \(cue?.name ?? "Missing")"
        }
    }

    private var inheritanceStatus: String {
        switch scope {
        case .show:
            return "Enabled Show rules apply to every cue unless its list or the cue opts out."
        case .cueList:
            if !ignoreParents && store.show.rules.contains(where: \.enabled) {
                return "Show rules are added to this list's and each cue's rules. Check Ignore Show rules to omit the Show additions."
            }
            return "This list's enabled rules are added to the rules of every non-exempt cue."
        case .cue(_, let listID):
            if ignoreParents { return "Only this cue's rules will apply, even if its parent levels have rules." }
            if let list = store.show.cueLists.first(where: { $0.id == listID }) {
                if !list.ignoreParentRules && store.show.rules.contains(where: \.enabled) {
                    return "Show and Cue List rules are added to this cue's own rules."
                }
                if list.rules.contains(where: \.enabled) {
                    return "Cue List rules are added to this cue's own rules."
                }
            }
            return "No parent level has enabled rules; this cue uses its own rules."
        case .marker: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !isMarkerRule {
                Text("Rules add together: Show + Cue List + Cue. Each rule keeps its own event and condition; parent rules do not cancel cue rules.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                Text(inheritanceStatus)
                    .font(.caption).foregroundStyle(SculptTheme.gold)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ruleList
                    .frame(width: 290)
                Divider()
                settingsPane
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 760, idealWidth: 850, minHeight: 570, idealHeight: 650)
        .onAppear {
            localRules = store.rules(for: scope)
            ignoreParents = store.ignoreParentRules(for: scope)
            if let first = localRules.first { choose(first) }
            else { makeNew() }
        }
    }

    private var topBar: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(SculptTheme.gold)
            VStack(alignment: .leading, spacing: 3) {
                Text(isMarkerRule ? "MARKER INTERACTION RULES" : "INTERACTION RULES").font(.headline)
                Text(scopeName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(localRules.count) rules")
                .font(.system(.caption, design: .monospaced))
        }
        .padding(18)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RULES IN EXECUTION ORDER")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(localRules) { rule in
                        Button { choose(rule) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: rule.enabled ? "bolt.fill" : "bolt.slash.fill")
                                    .foregroundStyle(rule.enabled ? Color.orange : Color.gray)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(rule.action.rawValue) · \(rule.target.rawValue)")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("When \(isMarkerRule ? "Reaching Marker" : rule.event.rawValue)\(rule.delaySeconds > 0 ? String(format: " + %.1fs", rule.delaySeconds) : "")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedID == rule.id ? Color.orange.opacity(0.19) : SculptTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { makeNew() } label: { Label("New Rule", systemImage: "plus") }
                Button { removeSelected() } label: { Label("Remove", systemImage: "trash") }
                    .disabled(selectedID == nil)
            }
            HStack(spacing: 8) {
                Button { move(-1) } label: { Label("Up", systemImage: "arrow.up") }
                    .disabled(selectedID == nil)
                Button { move(1) } label: { Label("Down", systemImage: "arrow.down") }
                    .disabled(selectedID == nil)
            }
        }
        .padding(14)
    }

    private var settingsPane: some View {
        Form {
            Section("TRIGGER") {
                Toggle("Enabled", isOn: $draft.enabled)
                if isMarkerRule {
                    LabeledContent("When", value: "Reaching Marker")
                    Text("Marker rules run at their position on the cue timeline, not on Starting/Ending/Stopping.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("When cue is", selection: $draft.event) {
                        ForEach(RuleEvent.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                    }
                }
                delayPicker
            }
            Section("ACTION") {
                Picker("Action", selection: $draft.action) {
                    ForEach(RuleAction.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                }
                Picker("Target", selection: $draft.target) {
                    ForEach(RuleTarget.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                }
                targetPicker
                Toggle("Exclude this cue", isOn: Binding(
                    get: { draft.excludeSource ?? false },
                    set: { draft.excludeSource = $0 }))
                Text("For a playlist crossfade: Starting → Fade Out → Cue List, with Exclude this cue enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.action == .dim { dimPicker }
                if draft.action == .fade { fadePicker }
                if draft.action == .fire {
                    fireFadePicker
                    if !destinationMarkers.isEmpty {
                        Picker("Fire at Marker", selection: $draft.fireAtMarkerID) {
                            Text(isMarkerRule && draft.target == .itself ? "Previous marker (loop)" : "Cue beginning")
                                .tag(UUID?.none)
                            ForEach(Array(destinationMarkers.enumerated()), id: \.element.id) { item in
                                Text("M\(item.offset + 1) · \(item.element.name)")
                                    .tag(Optional(item.element.id))
                            }
                        }
                        Text("Target marker references stay linked when markers are moved or renumbered.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("CONDITION (OPTIONAL)") {
                conditionControls
            }
            if case .cue = scope {
                Section("INHERITANCE") {
                    Toggle("Use only this cue's rules (ignore Show and Cue List)", isOn: $ignoreParents)
                    Text("When checked, only this cue's rules run. Otherwise inherited Show and Cue List rules run in addition to this cue's rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .cueList = scope {
                Section("INHERITANCE") {
                    Toggle("Ignore Show rules for this Cue List", isOn: $ignoreParents)
                    Text("When checked, Show rules are excluded; Cue List and cue rules still add together. Individual cues can opt out separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(selectedID == nil ? "Add Rule" : "Update Rule") { applyDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!validDraft)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var delayPicker: some View {
        HStack {
            Text("After")
            Slider(value: $draft.delaySeconds, in: 0...30, step: 0.1)
            Text("\(draft.delaySeconds, specifier: "%.1f") s")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder private var targetPicker: some View {
        if draft.target == .specificCue {
            Picker("Specific Cue", selection: $draft.targetID) {
                Text("Select a cue").tag(UUID?.none)
                ForEach(store.show.cueLists) { list in
                    ForEach(list.cues) { cue in
                        Text("\(list.name) › \(cue.name)").tag(Optional(cue.id))
                    }
                }
            }
        } else if draft.target == .cueList {
            Picker("Cue List", selection: $draft.targetID) {
                Text("Select a list").tag(UUID?.none)
                ForEach(store.show.cueLists) { list in
                    Text(list.name).tag(Optional(list.id))
                }
            }
        }
    }

    private var dimPicker: some View {
        HStack {
            Text("Dim level")
            Slider(value: $draft.dimDecibels, in: -60...0, step: 1)
            Text("\(draft.dimDecibels, specifier: "%.0f") dB")
                .monospacedDigit().frame(width: 65, alignment: .trailing)
        }
    }

    private var fadePicker: some View {
        HStack {
            Toggle("Override cue fade", isOn: Binding(
                get: { draft.fadeSeconds != nil },
                set: { draft.fadeSeconds = $0 ? 2 : nil }
            ))
            if draft.fadeSeconds != nil {
                Slider(value: Binding(
                    get: { draft.fadeSeconds ?? 2 },
                    set: { draft.fadeSeconds = $0 }
                ), in: 0...30, step: 0.5)
                Text("\(draft.fadeSeconds ?? 0, specifier: "%.1f")s")
                    .frame(width: 50)
            }
        }
    }

    private var fireFadePicker: some View {
        HStack {
            Toggle("Override fade-in", isOn: Binding(
                get: { draft.fireFadeInSeconds != nil },
                set: { draft.fireFadeInSeconds = $0 ? 2 : nil }
            ))
            if draft.fireFadeInSeconds != nil {
                Slider(value: Binding(
                    get: { draft.fireFadeInSeconds ?? 2 },
                    set: { draft.fireFadeInSeconds = $0 }
                ), in: 0...30, step: 0.5)
                Text("\(draft.fireFadeInSeconds ?? 0, specifier: "%.1f")s")
                    .frame(width: 50)
            }
        }
    }

    private var conditionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Only if another cue is in a specified state", isOn: Binding(
                get: { draft.conditionCueID != nil },
                set: { draft.conditionCueID = $0 ? allCues.first?.id : nil }
            ))
            if draft.conditionCueID != nil {
                Picker("Check Cue", selection: $draft.conditionCueID) {
                    ForEach(store.show.cueLists) { list in
                        ForEach(list.cues) { cue in
                            Text("\(list.name) › \(cue.name)").tag(Optional(cue.id))
                        }
                    }
                }
                Picker("Must be", selection: $draft.conditionState) {
                    ForEach(RuleCueState.allCases, id: \.self) { state in
                        Text(state.rawValue).tag(state)
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("Changes apply only after Save Rules")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Rules") {
                // Save currently open edit too, so no need to press Update first.
                if selectedID != nil { applyDraft() }
                store.updateRules(localRules, for: scope, ignoreParent: ignoreParents)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedID != nil && !validDraft)
        }
        .padding(18)
    }

    private var validDraft: Bool {
        if draft.action == .fire, let markerID = draft.fireAtMarkerID,
           !destinationMarkers.contains(where: { $0.id == markerID }) { return false }
        if draft.target == .specificCue { return draft.targetID.flatMap(store.show.cue) != nil }
        if draft.target == .cueList {
            guard let id = draft.targetID else { return false }
            return store.show.cueLists.contains(where: { $0.id == id })
        }
        return true
    }

    private func choose(_ rule: InteractionRule) {
        selectedID = rule.id
        draft = rule
    }

    private func makeNew() {
        selectedID = nil
        draft = InteractionRule(event: isMarkerRule ? .starting : .ending)
    }

    private func applyDraft() {
        // Reject an unconfigured reference instead of saving a silent no-op rule.
        if (draft.target == .specificCue || draft.target == .cueList) && draft.targetID == nil { return }
        if let idx = localRules.firstIndex(where: { $0.id == selectedID }) {
            localRules[idx] = draft
        } else {
            localRules.append(draft)
        }
        selectedID = draft.id
    }

    private func removeSelected() {
        localRules.removeAll { $0.id == selectedID }
        makeNew()
    }

    private func move(_ shift: Int) {
        guard let current = localRules.firstIndex(where: { $0.id == selectedID }) else { return }
        let destination = current + shift
        guard localRules.indices.contains(destination) else { return }
        localRules.swapAt(current, destination)
    }
}
