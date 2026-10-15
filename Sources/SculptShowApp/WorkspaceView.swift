import SwiftUI
import SculptShowCore
import UniformTypeIdentifiers

private enum Skin {
    static let base = Color(red: 0.075, green: 0.082, blue: 0.085)
    static let panel = Color(red: 0.12, green: 0.13, blue: 0.14)
    static let raised = Color(red: 0.17, green: 0.18, blue: 0.19)
    static let stroke = Color(red: 0.26, green: 0.27, blue: 0.28)
    static let gold = Color(red: 0.93, green: 0.70, blue: 0.38)
    static let green = Color(red: 0.44, green: 0.82, blue: 0.60)
    static let soft = Color(red: 0.62, green: 0.65, blue: 0.67)
}


/// Local editing state keeps text input independent from show-model redraws.
/// Renames commit only on Save or Return; Cancel leaves the original untouched.
private struct EditableTitle: View {
    let title: String
    let context: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let onRename: (String) -> Void

    @State private var showingEditor = false
    @State private var draft = ""
    @FocusState private var isTextFocused: Bool

    var body: some View {
        Button(action: beginEditing) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: fontSize, weight: fontWeight))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Skin.gold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename \(context)")
        .accessibilityLabel("Rename \(context)")
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rename \(context)")
                    .font(.title3.weight(.semibold))

                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFocused)
                    .onSubmit(saveName)

                HStack {
                    Spacer()
                    Button("Cancel") { showingEditor = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { saveName() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 410)
            .onAppear { isTextFocused = true }
        }
    }

    private func beginEditing() {
        draft = title
        showingEditor = true
    }

    private func saveName() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name != title { onRename(name) }
        showingEditor = false
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Skin.stroke)
            transport
            Divider().overlay(Skin.stroke)
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.show.cueLists) { list in
                            CueListPanel(list: list)
                                .frame(width: 418)
                        }
                    }
                    .padding(16)
                }
                .background(Skin.base)

                Divider().overlay(Skin.stroke)
                inspector
                    .frame(width: 292)
            }
            statusBar
        }
        .background(Skin.base)
        .onAppear {
            playback.onNaturalFinish = { [weak store, weak playback] id in
                guard let store, let playback else { return }
                store.didFinishNaturally(id, using: playback)
            }
        }
        .alert("Sculpt Show", isPresented: Binding(
            get: { store.errorMessage != nil || playback.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil; playback.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
                playback.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? playback.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(Skin.gold)
            VStack(alignment: .leading, spacing: 0) {
                Text("SCULPT")
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .tracking(3)
                Text("S H O W")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Skin.gold)
            }
            Rectangle().fill(Skin.stroke).frame(width: 1, height: 31).padding(.horizontal, 12)
            EditableTitle(
                title: store.show.name,
                context: "Show",
                fontSize: 16,
                fontWeight: .medium
            ) { newName in
                store.renameShow(newName)
            }
            .frame(maxWidth: 350, alignment: .leading)
            if store.dirty {
                Circle().fill(Skin.gold).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer()
            headerButton("folder", "Open") {
                if store.openShow() { playback.stopAll() }
            }
            headerButton("square.and.arrow.down", "Save") { store.save() }
            headerButton("plus.rectangle.on.folder", "New List") { store.addList() }
        }
        .padding(.horizontal, 22)
        .frame(height: 77)
        .background(Skin.panel)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button {
                store.fireSelected(using: playback)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text("GO")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                }
                .foregroundColor(.black)
                .frame(width: 142, height: 56)
                .background(Skin.green, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Fire the selected cue • Space")

            Button {
                if let id = store.selectedListID { store.selectNext(in: id) }
            } label: {
                Label("NEXT", systemImage: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .frame(height: 56)
                    .padding(.horizontal, 14)
                    .background(Skin.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button { playback.stopAll() } label: {
                Label("STOP ALL", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(height: 56)
                    .padding(.horizontal, 14)
                    .background(Color.red.opacity(0.21), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Spacer()
            Toggle("AUTO NEXT", isOn: $store.advanceAfterGO)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("After GO, select the next enabled cue in the current list")
            VStack(alignment: .trailing, spacing: 5) {
                Text("ACTIVE CUES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Skin.soft)
                Text("\(playback.snapshots.count)")
                    .font(.system(size: 29, weight: .semibold, design: .monospaced))
                    .foregroundColor(Skin.gold)
            }
            .padding(.trailing, 9)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Skin.panel)
    }

    private var inspector: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
            Text("CUE INSPECTOR")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundColor(Skin.gold)

            if let listID = store.selectedListID, let cue = store.selectedCue {
                Text("SELECTED CUE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Skin.soft)
                TextField("Cue name", text: Binding(
                    get: { store.show.cue(cue.id)?.name ?? cue.name },
                    set: { store.renameCue(cue.id, in: listID, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 17, weight: .medium))

                Divider()
                HStack {
                    Text("GAIN")
                    Spacer()
                    Text("\(Int(cue.gain * 100)) %")
                        .monospacedDigit()
                        .foregroundColor(Skin.gold)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                Slider(value: Binding(
                    get: { store.show.cue(cue.id)?.gain ?? cue.gain },
                    set: { store.setGain(cue.id, in: listID, to: $0); playback.setGain($0, for: cue.id) }
                ), in: 0...1)
                .tint(Skin.gold)

                HStack {
                    Text("FADE OUT")
                    Spacer()
                    Text("\(cue.fadeOutSeconds, specifier: "%.1f") s")
                        .monospacedDigit()
                        .foregroundColor(Skin.gold)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                Slider(value: Binding(
                    get: { store.show.cue(cue.id)?.fadeOutSeconds ?? cue.fadeOutSeconds },
                    set: { store.setFade(cue.id, in: listID, to: $0) }
                ), in: 0...30, step: 0.5)
                .tint(Skin.gold)

                HStack {
                    Text("FADE IN")
                    Spacer()
                    Text("\(cue.fadeInSeconds, specifier: "%.1f") s")
                        .monospacedDigit()
                        .foregroundColor(Skin.gold)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                Slider(value: Binding(
                    get: { store.show.cue(cue.id)?.fadeInSeconds ?? cue.fadeInSeconds },
                    set: { store.setFadeIn(cue.id, in: listID, to: $0) }
                ), in: 0...30, step: 0.5)
                .tint(Skin.gold)

                Toggle("Loop until STOP", isOn: Binding(
                    get: { store.show.cue(cue.id)?.loop ?? cue.loop },
                    set: { store.setLoop(cue.id, in: listID, to: $0); playback.setLoop($0, for: cue.id) }
                ))
                .toggleStyle(.switch)
                .help("Repeatedly play this audio file until stopped manually")

                Toggle("Auto-follow next cue", isOn: Binding(
                    get: { store.show.cue(cue.id)?.followOnFinish ?? cue.followOnFinish },
                    set: { store.setFollow(cue.id, in: listID, to: $0) }
                ))
                .toggleStyle(.switch)
                .disabled(cue.loop)
                .help("At natural end, start the next enabled cue in this list; loop overrides follow")

                Toggle("Cue enabled", isOn: Binding(
                    get: { store.show.cue(cue.id)?.enabled ?? cue.enabled },
                    set: { store.setEnabled(cue.id, in: listID, to: $0) }
                ))
                .toggleStyle(.switch)

                Divider()
                Text("MEDIA FILE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Skin.soft)
                Text(cue.mediaPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Skin.soft)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !FileManager.default.fileExists(atPath: cue.mediaPath) {
                    Label("Media file is missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                if let active = playback.snapshots[cue.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REMAINING")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Skin.soft)
                        Text("−" + clock(active.remaining))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(Skin.green)
                    }
                }
                HStack {
                    Button { store.moveCue(cue.id, in: listID, by: -1) } label: {
                        Label("Up", systemImage: "arrow.up")
                    }
                    Button { store.moveCue(cue.id, in: listID, by: 1) } label: {
                        Label("Down", systemImage: "arrow.down")
                    }
                }
                Button(role: .destructive) {
                    playback.stop(cue.id)
                    store.removeCue(cue.id, from: listID)
                } label: {
                    Label("Remove Cue", systemImage: "trash")
                }
            } else {
                Text("Select a cue to edit its properties.")
                    .foregroundColor(Skin.soft)
                    .multilineTextAlignment(.center)
            }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Skin.panel)
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(Skin.green).frame(width: 7, height: 7)
            Text("CORE AUDIO  •  SYSTEM DEFAULT OUTPUT")
            Spacer()
            Text("\(store.show.cueLists.count) CUE LISTS")
            Text("•")
            Text("\(store.show.cueLists.reduce(0) { $0 + $1.cues.count }) CUES")
            Spacer()
            Text("SCULPT SHOW 0.2.0")
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(Skin.soft)
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(Skin.raised)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func headerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Skin.raised, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct CueListPanel: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let list: CueList

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Skin.gold).frame(width: 7, height: 7)
                EditableTitle(
                    title: list.name,
                    context: "Cue List",
                    fontSize: 15,
                    fontWeight: .bold
                ) { newName in
                    store.renameList(list.id, to: newName)
                }
                Spacer()
                Text("\(list.cues.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Skin.soft)
                Menu {
                    Button("Remove Cue List", role: .destructive) {
                        for cue in list.cues { playback.stop(cue.id) }
                        store.removeList(list.id)
                    }
                    .disabled(store.show.cueLists.count < 2)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(Skin.soft)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(14)
            .background(Skin.raised)

            HStack(spacing: 8) {
                Button {
                    store.fireSelected(in: list.id, using: playback)
                } label: {
                    Label("FIRE", systemImage: "play.fill")
                        .foregroundColor(Skin.green)
                }
                .buttonStyle(.plain)
                Button {
                    store.importAudio(to: list.id)
                } label: {
                    Label("ADD AUDIO", systemImage: "plus")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("CUE LIST")
                    .foregroundColor(Skin.soft)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(Skin.stroke)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if list.cues.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 30))
                                .foregroundColor(Skin.soft)
                            Text("NO CUES YET")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Skin.soft)
                            Text("Import audio or drop audio files here")
                                .font(.caption)
                                .foregroundColor(Skin.soft)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                    }
                    ForEach(Array(list.cues.enumerated()), id: \.element.id) { item in
                        CueRow(cue: item.element, listID: list.id, cueNumber: item.offset + 1)
                    }
                }
                .padding(10)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                for provider in matching {
                    _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let file = item as? URL { url = file }
                        else if let file = item as? NSURL { url = file as URL }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = nil }
                        if let url, url.isFileURL {
                            DispatchQueue.main.async { store.addAudio([url], to: list.id) }
                        }
                    }
                }
                return !matching.isEmpty
            }
        }
        .background(Skin.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Skin.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .frame(maxHeight: .infinity)
    }
}

private struct CueRow: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    let cueNumber: Int

    private var selected: Bool { store.cueSelection[listID] == cue.id }
    private var state: PlaybackEngine.Snapshot? { playback.snapshots[cue.id] }
    @State private var pendingSeek: Double?

    var body: some View {
        VStack(spacing: 0) {
            controlsRow
            progressBar
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(rowOutline, lineWidth: 1))
        .opacity(cue.enabled ? 1 : 0.53)
    }

    private var rowBackground: Color {
        selected ? Skin.gold.opacity(0.15) : Skin.raised
    }

    private var rowOutline: Color {
        selected ? Skin.gold.opacity(0.55) : .clear
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            selectionButton
            statusIndicator
            cueActions
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .tint(Skin.soft)
        .padding(.horizontal, 11)
        .frame(minHeight: 62)
    }

    private var selectionButton: some View {
        Button {
            store.select(cue.id, in: listID)
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Text(String(format: "%03d", cueNumber))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(selected ? Skin.gold : Skin.soft)
                cueDetails
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cueDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(cue.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(cue.enabled ? .white : Skin.soft)
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(playbackLabel)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(state == nil ? Skin.soft : Skin.green)
        }
    }

    private var playbackLabel: String {
        guard let state else { return "AUDIO" }
        return "\(clock(state.elapsed))  •  −\(clock(state.remaining))"
    }

    private var statusIndicator: some View {
        Image(systemName: statusSymbol)
            .foregroundColor(state == nil ? Skin.soft : Skin.green)
            .font(.system(size: 11))
    }

    private var statusSymbol: String {
        guard let state else { return "circle" }
        return state.phase == .paused ? "pause.circle.fill" : "circle.fill"
    }

    private var cueActions: some View {
        Group {
            Button { playback.play(cue) } label: { Image(systemName: "play.fill") }
                .disabled(!cue.enabled)
                .help("Fire cue")
            Button { playback.togglePause(cue.id) } label: { Image(systemName: "pause.fill") }
                .disabled(state == nil)
                .help("Pause / resume cue")
            Button { playback.fadeOut(cue) } label: { Image(systemName: "arrow.down.right") }
                .disabled(state == nil)
                .help("Fade out cue")
            Button { playback.stop(cue.id) } label: { Image(systemName: "stop.fill") }
                .disabled(state == nil)
                .help("Stop cue")
        }
    }

    private var progressBar: some View {
        Slider(value: Binding(
            get: { pendingSeek ?? state?.fraction ?? 0 },
            set: { pendingSeek = $0 }
        ), in: 0...1, onEditingChanged: { isEditing in
            if !isEditing, let value = pendingSeek {
                playback.seek(cue.id, to: value)
                pendingSeek = nil
            }
        })
        .controlSize(.mini)
        .tint(Skin.green)
        .disabled(state == nil || state?.phase == .fading)
        .padding(.horizontal, 10)
        .frame(height: 17)
        .help("Click or drag to seek within a playing or paused cue")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
