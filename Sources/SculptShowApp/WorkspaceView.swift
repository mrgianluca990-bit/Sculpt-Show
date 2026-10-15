import SwiftUI
import AppKit
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
    @State private var rulesScope: RuleScope?
    @StateObject private var timecodeReader = TimecodeReader()
    @State private var showingTimecodeReader = false
    @EnvironmentObject private var midi: MIDIControl
    @State private var showingOutputMixer = true
    @State private var showingWaveforms = false
    @State private var showingPreflight = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Skin.stroke)
            transport
            Divider().overlay(Skin.stroke)
            if showingOutputMixer || showingWaveforms || showingTimecodeReader {
                // A native, draggable split between the show editor and Cue-style
                // docked consoles. Changing layout never changes the audio graph.
                VSplitView {
                    mainEditor
                        .frame(minHeight: 235)
                    bottomConsoles
                        .frame(minHeight: 310, idealHeight: 370)
                }
            } else {
                mainEditor
            }
            statusBar
        }
        .background(Skin.base)
        .onAppear {
            Task { @MainActor in await playback.startRoutingAutomatically() }
            midi.onCommand = { [weak store, weak playback] command in
                guard let store, let playback else { return }
                switch command {
                case .go: store.fireSelected(using: playback)
                case .pauseAll: store.togglePauseAll(using: playback)
                case .stopAll: store.stopAll(using: playback)
                case .fadeAll: store.fadeAll(using: playback)
                case .previous:
                    if let list = store.selectedListID { store.selectPrevious(in: list) }
                case .next:
                    if let list = store.selectedListID { store.selectNext(in: list) }
                case .nextList: store.selectNextList()
                }
            }
            playback.onNaturalFinish = { [weak store, weak playback] id in
                guard let store, let playback else { return }
                store.didFinishNaturally(id, using: playback)
            }
            playback.onStarted = { [weak store, weak playback] id in
                guard let store, let playback else { return }
                store.handleRuleEvent(.starting, source: id, using: playback)
            }
            playback.onMarkersReached = { [weak store, weak playback] cueID, markerIDs in
                guard let store, let playback else { return }
                store.handleMarkersReached(markerIDs, in: cueID, using: playback)
            }
            playback.onStopped = { [weak store, weak playback] id in
                guard let store, let playback else { return }
                store.didStopCue(id)
                store.handleRuleEvent(.stopping, source: id, using: playback)
            }
        }
        .sheet(isPresented: $showingPreflight) {
            ShowPreflightPanel()
                .environmentObject(store)
                .environmentObject(playback)
        }
        .sheet(item: $rulesScope) { scope in
            RulesEditor(scope: scope).environmentObject(store)
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

    private var mainEditor: some View {
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
                .frame(width: 346)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mixer and MTC can run simultaneously or independently. The operator can
    /// resize this dock with the VSplitView divider, without touching playback.
    private var bottomConsoles: some View {
        HStack(spacing: 0) {
            if showingOutputMixer || showingWaveforms {
                waveformAndMixer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if (showingOutputMixer || showingWaveforms) && showingTimecodeReader {
                Divider().overlay(Skin.stroke)
            }
            if showingTimecodeReader {
                TimecodeReaderView()
                    .environmentObject(timecodeReader)
                    .frame(width: (showingOutputMixer || showingWaveforms) ? 375 : nil)
                    .frame(maxWidth: (showingOutputMixer || showingWaveforms) ? nil : .infinity,
                           maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Skin.panel)
    }

    @ViewBuilder
    private var waveformAndMixer: some View {
        if showingOutputMixer && showingWaveforms {
            VSplitView {
                ShowOutputMixerView()
                    .environmentObject(playback)
                    .frame(minHeight: 235, idealHeight: 340)
                ShowWaveformOverview()
                    .environmentObject(store)
                    .environmentObject(playback)
                    .frame(minHeight: 145, idealHeight: 250)
            }
        } else if showingOutputMixer {
            ShowOutputMixerView().environmentObject(playback)
        } else if showingWaveforms {
            ShowWaveformOverview()
                .environmentObject(store)
                .environmentObject(playback)
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
            headerButton("arrow.triangle.branch", "Show Rules") { rulesScope = .show }
            headerButton("checkmark.shield", "Preflight") { showingPreflight = true }
            headerButton("plus.rectangle.on.folder", "New List") { store.addList() }
        }
        .padding(.horizontal, 22)
        .frame(height: 77)
        .background(Skin.panel)
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { store.fireSelected(using: playback) } label: {
                    Label("GO", systemImage: "play.fill")
                        .font(.system(size: 21, weight: .black, design: .rounded))
                        .foregroundColor(.black)
                        .frame(width: 145, height: 53)
                        .background(Skin.green, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(store.selectedCue == nil)
                .help("GO · Space")

                globalTransportButton("PAUSE ALL", "pause.fill") { store.togglePauseAll(using: playback) }
                globalTransportButton("STOP ALL", "stop.fill", red: true) { store.stopAll(using: playback) }
                globalTransportButton("FADE ALL", "arrow.down.right") { store.fadeAll(using: playback) }
                Spacer(minLength: 2)
                Text("ACTIVE  \(playback.snapshots.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Skin.gold)
            }
            HStack(spacing: 10) {
                globalTransportButton("PREVIOUS", "chevron.up") {
                    if let id = store.selectedListID { store.selectPrevious(in: id) }
                }
                globalTransportButton("NEXT", "chevron.down") {
                    if let id = store.selectedListID { store.selectNext(in: id) }
                }
                globalTransportButton("NEXT LIST", "rectangle.stack") { store.selectNextList() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SELECTED: \(store.show.cueLists.first(where: { $0.id == store.selectedListID })?.name ?? "—")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Skin.soft)
                        .lineLimit(1)
                    Text(store.selectedCue?.name ?? "No cue selected")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Skin.gold)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("AUTO NEXT", isOn: $store.advanceAfterGO)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button { withAnimation(.easeInOut(duration: 0.18)) {
                    showingOutputMixer.toggle()
                } } label: {
                    Label("MIXER", systemImage: "slider.vertical.3")
                }
                .buttonStyle(.borderedProminent)
                .tint(showingOutputMixer ? Skin.gold : Skin.raised)
                .help(showingOutputMixer ? "Hide the docked output mixer" : "Show the docked output mixer")
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingWaveforms.toggle()
                    }
                } label: {
                    Label("WAVEFORMS", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .tint(showingWaveforms ? Skin.gold : Skin.raised)
                .help("Show aligned cue waveforms, marker positions and live playhead")
                HStack(spacing: 4) {
                    Circle().fill(playback.routingEnabled ? Skin.green : .red)
                        .frame(width: 7, height: 7)
                    Text(playback.routingEnabled ? "AUDIO \(playback.routingOutputCount)CH" : "AUDIO OFF")
                        .font(.system(size: 10, design: .monospaced))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showingTimecodeReader.toggle() }
                } label: {
                    Label(timecodeReader.frame?.display ?? "MTC READER", systemImage: "clock")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.borderedProminent)
                .tint(showingTimecodeReader ? Skin.gold : Skin.raised)
                .help(showingTimecodeReader ? "Hide the docked timecode reader" : "Show timecode reader, alongside or without the mixer")
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Skin.panel)
    }

    private func globalTransportButton(_ name: String, _ symbol: String,
                                       red: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(minHeight: 33)
        }
        .tint(red ? .red : Skin.soft)
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
                EditableTitle(
                    title: cue.name,
                    context: "Cue",
                    fontSize: 17,
                    fontWeight: .medium
                ) { newName in
                    store.renameCue(cue.id, in: listID, to: newName)
                }
                .help("Click to rename the cue")

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

                Divider()
                HStack {
                    Text("PRE-WAIT")
                    Spacer()
                    Text("\(cue.preWaitSeconds, specifier: "%.1f") s")
                        .monospacedDigit()
                        .foregroundColor(Skin.gold)
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                Slider(value: Binding(
                    get: { store.show.cue(cue.id)?.preWaitSeconds ?? cue.preWaitSeconds },
                    set: { store.setPreWait(cue.id, in: listID, to: $0) }
                ), in: 0...120, step: 0.5)
                .tint(Skin.gold)
                .help("Delay before a cue starts after GO. STOP cancels a waiting cue.")

                CueTimingEditor(cue: cue, listID: listID)

                Divider()
                CueMarkersEditor(cue: cue, listID: listID)

                Divider()
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
                    set: { isEnabled in
                        store.setEnabled(cue.id, in: listID, to: isEnabled)
                        if !isEnabled { playback.stop(cue.id) }
                    }
                ))
                .toggleStyle(.switch)

                Divider()
                CueContentsEditor(cue: cue, listID: listID)

                if let active = playback.snapshots[cue.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.phase == .waiting ? "START IN" : "REMAINING")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Skin.soft)
                        Text("−" + clock(active.remaining))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(Skin.green)
                    }
                }
                Button {
                    rulesScope = .cue(cue.id, in: listID)
                } label: {
                    Label("Edit Interaction Rules (\(cue.rules.count))", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)

                HStack {
                    Button { store.duplicateCue(cue.id, in: listID) } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
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
            Text("SCULPT SHOW 0.10.0")
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
    @State private var editingRules = false
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
                if !list.rules.isEmpty {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.orange)
                        .help("\(list.rules.count) list rules")
                }
                Text("\(list.cues.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Skin.soft)
                Menu {
                    Button("Edit List Rules…") { editingRules = true }
                    Divider()
                    Button("Remove Cue List", role: .destructive) {
                        for cue in list.cues { playback.stop(cue.id, notifyRules: false) }
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

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        store.playList(list.id, using: playback)
                    } label: {
                        Label("PLAY LIST", systemImage: "play.rectangle.fill")
                            .foregroundColor(Skin.green)
                    }
                    .help("Play cues sequentially from the current selection")
                    .disabled(store.playingLists[list.id] != nil)
                    Button {
                        store.fireSelected(in: list.id, using: playback)
                    } label: {
                        Label("FIRE", systemImage: "play.fill")
                    }
                    .help("Fire only the selected cue")
                    Spacer(minLength: 2)
                    Button {
                        store.fadeList(list.id, using: playback)
                    } label: {
                        Label("FADE", systemImage: "arrow.down.right")
                    }
                    Button {
                        store.stopList(list.id, using: playback)
                    } label: {
                        Label("STOP", systemImage: "stop.fill")
                            .foregroundColor(.red)
                    }
                    .help("Stop this list and cancel its pending starts")
                }
                HStack(spacing: 10) {
                    Button {
                        store.importAudio(to: list.id)
                    } label: {
                        Label("AUDIO", systemImage: "waveform.badge.plus")
                    }
                    Button {
                        store.addEmptyCue(to: list.id)
                    } label: {
                        Label("NEW CUE", systemImage: "plus.square.dashed")
                    }
                    .help("Create an empty cue container after the selected cue")
                    Spacer(minLength: 2)
                    Button {
                        editingRules = true
                    } label: {
                        Label("RULES (\(list.rules.count))", systemImage: "arrow.triangle.branch")
                            .foregroundColor(Skin.gold)
                    }
                    .help("Open the rules for this cue list")
                }
            }
            .buttonStyle(.plain)
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
                            Text("Create a cue or drag a cue from another list")
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
            .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                dropCueProviders(providers, to: list.id, before: nil)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                for provider in matching {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
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
        .sheet(isPresented: $editingRules) {
            RulesEditor(scope: .cueList(list.id)).environmentObject(store)
        }
    }

    private func dropCueProviders(_ providers: [NSItemProvider], to destinationID: UUID, before targetID: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let id = CueDragDrop.decode(text) else { return }
            DispatchQueue.main.async {
                _ = store.relocateCue(id, to: destinationID, before: targetID, using: playback)
            }
        }
        return true
    }
}

private struct CueRow: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    let cueNumber: Int

    private var selected: Bool { store.selectedListID == listID && store.selectedCueID == cue.id }
    private var state: PlaybackEngine.Snapshot? { playback.snapshots[cue.id] }
    @State private var pendingSeek: Double?
    @State private var editingName = false
    @State private var editingCueRules = false
    @State private var nameDraft = ""
    @State private var dropHighlighted = false

    var body: some View {
        VStack(spacing: 0) {
            controlsRow
            progressBar
        }
        .background(dropHighlighted ? Skin.gold.opacity(0.30) : rowBackground,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(rowOutline, lineWidth: 1))
        .opacity(cue.enabled ? 1 : 0.53)
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $dropHighlighted) { providers, location in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
            let rows = store.show.cueLists.first(where: { $0.id == listID })?.cues ?? []
            let target: UUID?
            if location.y < 38 { target = cue.id }
            else if let index = rows.firstIndex(where: { $0.id == cue.id }), index + 1 < rows.count { target = rows[index + 1].id }
            else { target = nil }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String,
                      let id = CueDragDrop.decode(text) else { return }
                DispatchQueue.main.async {
                    _ = store.relocateCue(id, to: listID, before: target, using: playback)
                }
            }
            return true
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            // Dropping audio onto a cue adds it as content instead of creating another cue.
            let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            for provider in files {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let file = item as? URL { url = file }
                    else if let file = item as? NSURL { url = file as URL }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    if let url, url.isFileURL {
                        DispatchQueue.main.async {
                            store.attachAudioURLs([url], to: cue.id, in: listID, using: playback)
                        }
                    }
                }
            }
            return !files.isEmpty
        }
        .contextMenu {
            Button("Rename Cue…") {
                nameDraft = cue.name
                editingName = true
            }
            Button("Edit Cue Rules…") { editingCueRules = true }
            Menu("Move to Cue List") {
                ForEach(store.show.cueLists.filter { $0.id != listID }) { destination in
                    Button(destination.name) {
                        _ = store.relocateCue(cue.id, to: destination.id,
                                              before: nil, using: playback)
                    }
                }
            }
        }
        .sheet(isPresented: $editingCueRules) {
            RulesEditor(scope: .cue(cue.id, in: listID)).environmentObject(store)
        }
        .sheet(isPresented: $editingName) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Cue").font(.headline)
                TextField("Cue name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveName)
                HStack {
                    Spacer()
                    Button("Cancel") { editingName = false }
                    Button("Save") { saveName() }
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
    }

    private func saveName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.renameCue(cue.id, in: listID, to: name)
        editingName = false
    }

    private var rowBackground: Color {
        selected ? Skin.gold.opacity(0.15) : Skin.raised
    }

    private var rowOutline: Color {
        selected ? Skin.gold.opacity(0.55) : .clear
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(Skin.gold)
                .frame(width: 23, height: 39)
                .contentShape(Rectangle())
                .onDrag { CueDragDrop.provider(for: cue.id) }
                .help("Drag this handle to reorder or move to another list")
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
                Image(systemName: cue.hasAudio ? "waveform" : cue.hasTimecode ? "clock" : "square.dashed")
                Text(playbackLabel)
                if !cue.markers.isEmpty {
                    Image(systemName: "mappin")
                    Text("M\(cue.markers.count)")
                    if cue.markers.contains(where: { !$0.rules.isEmpty }) {
                        Image(systemName: "bolt.fill").foregroundColor(Skin.gold)
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(state == nil ? Skin.soft : Skin.green)
        }
    }

    private var playbackLabel: String {
        guard let state else {
            let type = cue.isEmpty ? "RULES / EMPTY" : cue.hasAudio ? "AUDIO ×\(cue.audioElements.count)" : "TIMECODE"
            let length = cue.durationMode == .fixed ? String(format: "%.1fs", cue.durationSeconds) : "SOURCE"
            return "\(type)  ·  \(length)"
        }
        if state.phase == .waiting { return "WAIT  −\(clock(state.remaining))" }
        return "\(clock(state.elapsed))  •  −\(clock(state.remaining))"
    }

    private var statusIndicator: some View {
        Image(systemName: statusSymbol)
            .foregroundColor(state == nil ? Skin.soft : state?.phase == .waiting ? Skin.gold : Skin.green)
            .font(.system(size: 11))
    }

    private var statusSymbol: String {
        guard let state else { return "circle" }
        if state.phase == .waiting { return "clock.fill" }
        return state.phase == .paused ? "pause.circle.fill" : "circle.fill"
    }

    private var cueActions: some View {
        Group {
            Button { playback.play(cue) } label: { Image(systemName: "play.fill") }
                .disabled(!cue.enabled)
                .help("Fire cue")
            Button { playback.togglePause(cue.id) } label: { Image(systemName: "pause.fill") }
                .disabled(state == nil || state?.phase == .waiting)
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
        .disabled(state == nil || state?.phase == .fading || state?.phase == .waiting)
        .padding(.horizontal, 10)
        .frame(height: 17)
        .help("Click to seek in the cue container timeline")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
