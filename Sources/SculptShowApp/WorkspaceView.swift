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


private extension CueTint {
    var swatch: Color {
        switch self {
        case .none: return Skin.raised
        case .red: return Color(red: 0.93, green: 0.32, blue: 0.34)
        case .orange: return Color(red: 0.96, green: 0.56, blue: 0.25)
        case .yellow: return Color(red: 0.93, green: 0.78, blue: 0.34)
        case .green: return Color(red: 0.32, green: 0.74, blue: 0.49)
        case .blue: return Color(red: 0.36, green: 0.64, blue: 0.93)
        case .purple: return Color(red: 0.72, green: 0.48, blue: 0.89)
        }
    }
    var label: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }
}

private struct CueColorPicker: View {
    @EnvironmentObject private var store: ShowStore
    let cue: Cue
    let listID: UUID

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CueTint.allCases, id: \.self) { tint in
                Button {
                    store.setCueTint(cue.id, in: listID, to: tint)
                } label: {
                    Circle()
                        .fill(tint == .none ? Skin.panel : tint.swatch)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if tint == .none {
                                Image(systemName: "slash.circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(Skin.soft)
                            }
                        }
                        .overlay(Circle().stroke(cue.tint == tint ? Skin.gold : Skin.stroke,
                                                 lineWidth: cue.tint == tint ? 3 : 1))
                }
                .buttonStyle(.plain)
                .help(tint == .none ? "Remove cue color" : "Set cue color to \(tint.label)")
                .accessibilityLabel("Cue color: \(tint.label)")
            }
        }
    }
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
    @StateObject private var timecodeReader = LTCInputReader()
    @State private var showingTimecodeReader = false
    @EnvironmentObject private var midi: MIDIControl
    @State private var showingOutputMixer = false
    @State private var showingWaveforms = false
    @State private var showingPreflight = false
    @State private var normalizeSelection: NormalizationCueSelection?
    @State private var selectedMarkerID: UUID?
    @AppStorage("SculptShow.InspectorWidth.v1") private var inspectorWidth: Double = 346
    @State private var inspectorResizeStart: Double?
    @State private var expandedInspectorSections: Set<String> = []
    @State private var inspectorTab = "GENERAL"
    @State private var keyboardMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Skin.stroke)
            transport
            Divider().overlay(Skin.stroke)
            // Side dock is OUTSIDE the vertical mixer split: mixer and waveform may
            // resize only the cue-list workspace and can never cover the right rail.
            mainEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
        .background(Skin.base)
        .overlay {
            if store.isLoadingProject {
                ZStack {
                    Skin.base.opacity(0.95)
                    VStack(spacing: 15) {
                        ProgressView().controlSize(.large)
                        Text("PREPARAZIONE PROGETTO")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                        Text("Analisi file audio, canali mono/stereo e forme d’onda…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Il progetto verrà visualizzato quando gli audio saranno pronti.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(Skin.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if store.pendingAudioImports > 0 || store.normalizingCueID != nil ||
               store.normalizingListID != nil || store.dawBridgeBusy {
                ZStack {
                    Skin.base.opacity(0.88)
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(store.pendingAudioImports > 0 ? "IMPORTAZIONE AUDIO" :
                            (store.normalizingCueID != nil || store.normalizingListID != nil) ?
                            "NORMALIZZAZIONE AUDIO" : "PREPARAZIONE SCULPT DAW")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                        if store.pendingAudioImports > 0 {
                            Text("Analisi file e forme d'onda: " + store.audioImportProgress)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Operazione in corso. Non chiudere il progetto.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(28)
                    .background(Skin.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDeleteCommand(perform: deleteSelectedCue)
        .onAppear {
            installKeyboardShortcuts()
            playback.applyCueListTrims(store.show)
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
        .onChange(of: store.show) { next in
            playback.applyCueListTrims(next)
        }
        .onDisappear {
            if let keyboardMonitor {
                NSEvent.removeMonitor(keyboardMonitor)
                self.keyboardMonitor = nil
            }
        }
        .sheet(item: $normalizeSelection) { selection in
            CueNormalizationView(cueID: selection.cueID, listID: selection.listID)
                .environmentObject(store)
                .environmentObject(playback)
        }
        .sheet(isPresented: $showingPreflight) {
            ShowPreflightPanel()
                .environmentObject(store)
                .environmentObject(playback)
        }
        .sheet(item: $rulesScope) { scope in
            RulesEditor(scope: scope).environmentObject(store)
        }
        .alert(store.listNormalizationSummary != nil ? "Cue List Normalization" : "Sculpt Show",
               isPresented: Binding(
            get: { store.errorMessage != nil || playback.errorMessage != nil ||
                   store.listNormalizationSummary != nil },
            set: { if !$0 {
                store.errorMessage = nil
                playback.errorMessage = nil
                store.listNormalizationSummary = nil
            } }
        )) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
                playback.errorMessage = nil
                store.listNormalizationSummary = nil
            }
        } message: {
            Text(store.listNormalizationSummary ?? store.errorMessage ?? playback.errorMessage ?? "")
        }
    }

    /// Show-control shortcuts work without modifier keys. Only handle keys
    /// belonging to the main Show window; native dialogs, sheets, alerts,
    /// text editing, Cmd/Option/Ctrl shortcuts remain untouched.
    private func installKeyboardShortcuts() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow,
                  !(window is NSPanel), !window.isSheet,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView),
                  !(window.firstResponder is NSTextField),
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !self.store.isLoadingProject else { return event }
            switch event.keyCode {
            case 49: // Space = GO. Never fire multiple GO on key repeat.
                if !event.isARepeat { self.store.fireSelected(using: self.playback) }
                return nil
            case 48: // Tab to transient when waveform editor is visible.
                guard self.showingWaveforms,
                      let cue = self.store.selectedCue, cue.hasAudio else { return event }
                if !event.isARepeat {
                    let from = self.playback.cuePlayCursor(cue.id)
                    Task { @MainActor in
                        if let seconds = await ShowWaveformCache.shared.nextTransient(in: cue, after: from),
                           self.store.selectedCueID == cue.id {
                            self.playback.setCuePlayCursor(cue.id, to: seconds)
                        }
                    }
                }
                return nil
            case 53: // Escape = STOP ALL
                self.store.stopAll(using: self.playback)
                return nil
            case 126: // Up arrow = previous cue
                if let listID = self.store.selectedListID {
                    self.store.selectPrevious(in: listID)
                }
                return nil
            case 125: // Down arrow = next cue
                if let listID = self.store.selectedListID {
                    self.store.selectNext(in: listID)
                }
                return nil
            default: break
            }
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "p": self.store.togglePauseAll(using: self.playback)
            case "f": self.store.fadeAll(using: self.playback)
            case "m":
                guard let listID = self.store.selectedListID,
                      let cue = self.store.selectedCue else { return event }
                if !event.isARepeat {
                    let position = self.playback.snapshots[cue.id]?.elapsed
                        ?? self.playback.cuePlayCursor(cue.id)
                    self.selectedMarkerID = self.store.addMarker(to: cue.id, in: listID, at: position)
                }
            case "n": self.store.selectNextList()
            default: return event
            }
            return nil
        }
    }

    private func deleteSelectedCue() {
        // Text fields (including the Inspector and sheet field editors) own their
        // Backspace/Delete key. Never remove a cue while typing into one.
        if NSApp.keyWindow?.firstResponder is NSTextView ||
           NSApp.keyWindow?.firstResponder is NSTextField { return }
        guard let listID = store.selectedListID,
              let cueID = store.selectedCueID,
              store.show.cueLists.first(where: { $0.id == listID })?.cues.contains(where: { $0.id == cueID }) == true else { return }
        playback.stop(cueID, notifyRules: false)
        store.removeCue(cueID, from: listID)
    }

    /// The cue-list workspace alone participates in the mixer VSplitView.
    /// Inspector and LTC reader remain in the foreground to its right.
    private var cueListWorkspace: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.show.cueLists) { list in
                    CueListPanel(list: list)
                }
            }
            .padding(16)
        }
        .background(Skin.base)
        .frame(minWidth: 300)
    }

    private var cueListAndMixer: some View {
        Group {
            if showingOutputMixer || showingWaveforms {
                VSplitView {
                    cueListWorkspace.frame(minHeight: 235)
                    waveformAndMixer.frame(minHeight: 240, idealHeight: 340)
                }
            } else {
                cueListWorkspace
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainEditor: some View {
        HStack(spacing: 0) {
            cueListAndMixer

            // Drag left to widen Inspector; the Timecode pane inherits its width.
            Rectangle()
                .fill(Skin.stroke)
                .frame(width: 8)
                .overlay {
                    Capsule().fill(Skin.gold.opacity(0.65))
                        .frame(width: 3, height: 48)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if inspectorResizeStart == nil { inspectorResizeStart = inspectorWidth }
                        let initial = inspectorResizeStart ?? inspectorWidth
                        inspectorWidth = min(650, max(280, initial - Double(value.translation.width)))
                    }
                    .onEnded { _ in inspectorResizeStart = nil })
                .help("Drag to resize Cue Lists and Inspector")

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // The Inspector occupies the top portion of the right rail.
                    inspector
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(0)

                    if showingTimecodeReader {
                        Divider().overlay(Skin.stroke)
                        TimecodeReaderView()
                            .environmentObject(timecodeReader)
                            .environmentObject(playback)
                            // The LTC monitor fills the lower Inspector, never the mixer.
                            // Capped so the Inspector always retains usable vertical space.
                            .frame(height: min(405, max(225, geometry.size.height * 0.46)))
                            .frame(maxWidth: .infinity)
                            .background(Skin.panel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(Skin.panel)
            }
            .frame(width: min(650, max(280, inspectorWidth)))
            .zIndex(2) // Keep the right rail above the mixer during split resizing.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var waveformAndMixer: some View {
        // Exactly one primary dock. The Timecode Reader has its own right panel.
        if showingOutputMixer {
            ShowOutputMixerView().environmentObject(playback)
        } else if showingWaveforms {
            ShowWaveformOverview(selectedMarkerID: $selectedMarkerID)
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
        HStack(spacing: 6) {
            Button { store.fireSelected(using: playback) } label: {
                Label("GO", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .frame(width: 100, height: 43)
                    .background(Skin.green, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(store.selectedCue == nil)
            .help("GO · Space")

            transportAction("PAUSE", "pause.fill") { store.togglePauseAll(using: playback) }
            transportAction("STOP", "stop.fill", destructive: true) { store.stopAll(using: playback) }
            transportAction("FADE", "arrow.down.right") { store.fadeAll(using: playback) }
            transportSeparator
            transportAction("PREV", "chevron.up", compact: true) {
                if let id = store.selectedListID { store.selectPrevious(in: id) }
            }
            transportAction("NEXT", "chevron.down", compact: true) {
                if let id = store.selectedListID { store.selectNext(in: id) }
            }
            transportAction("NEXT LIST", "rectangle.stack", compact: true) { store.selectNextList() }
            transportSeparator

            Text(store.selectedCue?.name ?? "No cue selected")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundColor(Skin.gold)
                .lineLimit(1)
                .minimumScaleFactor(0.60)
                .help(store.selectedCue?.name ?? "No cue selected")
            .frame(minWidth: 125, maxWidth: .infinity, alignment: .leading)

            Toggle("AUTO", isOn: $store.advanceAfterGO)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
                .help("Automatically select the next cue after GO")

            Button {
                let open = !showingOutputMixer
                showingOutputMixer = open
                if open { showingWaveforms = false }
            } label: {
                Image(systemName: "slider.vertical.3")
                    .frame(width: 24, height: 29)
            }
            .tint(showingOutputMixer ? Skin.gold : Skin.raised)
            .help(showingOutputMixer ? "Hide output mixer" : "Show output mixer")
            .accessibilityLabel("Mixer")

            Button {
                let open = !showingWaveforms
                showingWaveforms = open
                if open { showingOutputMixer = false }
            } label: {
                Image(systemName: "waveform")
                    .frame(width: 24, height: 29)
            }
            .tint(showingWaveforms ? Skin.gold : Skin.raised)
            .help("Waveform editor and markers")
            .accessibilityLabel("Waveforms")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingTimecodeReader.toggle() }
            } label: {
                Image(systemName: "clock")
                    .frame(width: 24, height: 29)
            }
            .tint(showingTimecodeReader ? Skin.gold : Skin.raised)
            .help("Timecode reader / LTC monitor")
            .accessibilityLabel("Timecode")
            
            HStack(spacing: 3) {
                Circle().fill(playback.routingEnabled ? Skin.green : .red)
                    .frame(width: 6, height: 6)
                Text(playback.routingEnabled ? "\(playback.routingOutputCount)CH" : "OFF")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .fixedSize()
            .help("Core Audio routing status")
            Text("A\(playback.snapshots.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Skin.gold)
                .fixedSize()
                .help("\(playback.snapshots.count) active cues")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Skin.panel)
    }

    private var transportSeparator: some View {
        Rectangle().fill(Skin.stroke).frame(width: 1, height: 23)
    }

    private func transportAction(_ name: String, _ symbol: String, destructive: Bool = false,
                                 compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if !compact { Text(name) }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .frame(minHeight: 29)
            .fixedSize(horizontal: true, vertical: false)
        }
        .tint(destructive ? .red : Skin.raised)
        .help(name)
        .accessibilityLabel(name)
    }

    private var inspector: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CUE INSPECTOR")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundColor(Skin.gold)
                    .padding(.bottom, 4)

                if let listID = store.selectedListID, let cue = store.selectedCue {
                    EditableTitle(title: cue.name, context: "Cue", fontSize: 16,
                                  fontWeight: .medium) { newName in
                        store.renameCue(cue.id, in: listID, to: newName)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(["GENERAL", "MARKER", "STEMS LTC", "RULES & ACTIONS"], id: \.self) { tab in
                                Button(tab) { inspectorTab = tab }
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(inspectorTab == tab ? Color.black : Skin.gold)
                                    .background(inspectorTab == tab ? Skin.gold : Skin.raised,
                                                in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    Group {
                        if inspectorTab == "GENERAL" {
                            VStack(alignment: .leading, spacing: 12) {
                        CueColorPicker(cue: cue, listID: listID)                                Divider()
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
                                Divider()
                        CueTimingEditor(cue: cue, listID: listID)
                            .id(cue.id) // independent draft + focus for every selected cue
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
                            }
                        } else if inspectorTab == "MARKER" {
                        CueMarkersEditor(cue: cue, listID: listID,
                                         selectedMarkerID: $selectedMarkerID)
                        } else if inspectorTab == "STEMS LTC" {
                        CueContentsEditor(cue: cue, listID: listID)
                        } else {
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
                        }                            if cue.hasAudio {
                            Button {
                                normalizeSelection = NormalizationCueSelection(cueID: cue.id, listID: listID)
                            } label: {
                                Label("NORMALIZE AUDIO…", systemImage: "waveform.path")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.normalizingCueID != nil || !playback.snapshots.isEmpty)
                            .help("Offline LUFS-I or Peak normalization, default -18 LUFS. Makes new media copies; leaves original audio untouched.")
                            if store.normalizingCueID == cue.id {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Analyzing / rendering…").font(.caption)
                                }
                            }                            }
                        }
                    }

                } else {
                    Text("Select a cue to edit its properties.")
                        .foregroundColor(Skin.soft)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Skin.panel)
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expandedInspectorSections.contains(title) {
                    expandedInspectorSections.remove(title)
                } else {
                    expandedInspectorSections.insert(title)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expandedInspectorSections.contains(title) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                    Spacer()
                }
                .foregroundColor(Skin.gold)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(expandedInspectorSections.contains(title) ? "collapse" : "expand")")
            if expandedInspectorSections.contains(title) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Skin.raised.opacity(0.56), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Skin.stroke.opacity(0.7)))
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(Skin.green).frame(width: 7, height: 7)
            Text("CORE AUDIO  •  SYSTEM DEFAULT OUTPUT")
            if let message = store.dawBridgeMessage {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 380, alignment: .leading)
                    .help(message)
            }
            Spacer()
            Text("\(store.show.cueLists.count) CUE LISTS")
            Text("•")
            Text("\(store.show.cueLists.reduce(0) { $0 + $1.cues.count }) CUES")
            if store.pendingAudioImports > 0 {
                ProgressView().controlSize(.mini)
                Text("ANALYZING AUDIO IMPORT…")
            }
            if store.normalizingListID != nil {
                ProgressView().controlSize(.mini)
                Text("NORMALIZING CUE LIST…")
            }
            Spacer()
            Text("SCULPT SHOW 0.18.2")
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
    @State private var showingListOptions = false
    @State private var trimDraft: Double = 0
    @State private var showingBulkFade = false
    @State private var bulkFadeDraft = "5"
    @State private var panelWidth: Double = 418
    @State private var resizeStart: Double?
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
                Button {
                    trimDraft = list.trimDB
                    showingListOptions.toggle()
                } label: {
                    Label("MENU", systemImage: "ellipsis.circle.fill")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Skin.gold)
                        .frame(minWidth: 82, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .help("Open Cue List menu")
                .popover(isPresented: $showingListOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Edit List Rules…") {
                            showingListOptions = false
                            editingRules = true
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("LIST TRIM (VCA)")
                                Spacer()
                                Text(String(format: "%+.1f dB", trimDraft))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Slider(value: $trimDraft, in: -60...6, step: 0.5,
                                   onEditingChanged: { editing in
                                if !editing { store.setCueListTrim(list.id, decibels: trimDraft) }
                            })
                            .onChange(of: trimDraft) { level in
                                playback.previewCueListTrim(list, db: level)
                            }
                            .help("Live gain trim on all cues in this list; does not move individual cue gains")
                            Button("RESET TRIM 0 dB") {
                                trimDraft = 0
                                store.setCueListTrim(list.id, decibels: 0)
                            }
                            .font(.system(size: 10, design: .monospaced))
                        }
                        .frame(width: 265)
                        Divider()
                        Button("SET FADE OUT FOR ALL CUES…") {
                            showingListOptions = false
                            bulkFadeDraft = "5"
                            showingBulkFade = true
                        }
                        .disabled(list.cues.isEmpty)
                        Divider()
                        Button {
                            showingListOptions = false
                            store.normalizeCueList(list.id, using: playback)
                        } label: {
                            Label("NORMALIZE LIST  -18 LUFS", systemImage: "waveform.path")
                        }
                        .disabled(!list.cues.contains(where: { $0.hasAudio }) ||
                                  store.normalizingCueID != nil ||
                                  store.normalizingListID != nil ||
                                  store.isLoadingProject ||
                                  store.pendingAudioImports > 0 ||
                                  !playback.snapshots.isEmpty)
                        .help("Normalize every mono/stereo stem in this Cue List. Preset -18 LUFS-I, sample peak ceiling -1 dBFS")
                        Divider()
                        Button("Remove Cue List", role: .destructive) {
                            showingListOptions = false
                            for cue in list.cues { playback.stop(cue.id, notifyRules: false) }
                            store.removeList(list.id)
                        }
                        .disabled(store.show.cueLists.count < 2)
                    }
                    .padding(14)
                    .frame(minWidth: 190)
                    .onDisappear { playback.applyCueListTrims(store.show) }
                }
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
        .frame(width: min(900, max(355, panelWidth)))
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Skin.stroke.opacity(0.7))
                .frame(width: 10)
                .overlay {
                    Capsule().fill(Skin.gold.opacity(0.7)).frame(width: 3, height: 36)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = panelWidth }
                        panelWidth = min(900, max(355, (resizeStart ?? panelWidth) + Double(value.translation.width)))
                    }
                    .onEnded { _ in resizeStart = nil })
                .help("Drag horizontally to resize this Cue List")
        }
        .onAppear {
            let stored = UserDefaults.standard.double(forKey: "SculptShow.CueListWidth.\(list.id.uuidString)")
            if stored >= 355 && stored <= 900 { panelWidth = stored }
        }
        .onChange(of: panelWidth) { newWidth in
            UserDefaults.standard.set(newWidth, forKey: "SculptShow.CueListWidth.\(list.id.uuidString)")
        }
        .sheet(isPresented: $editingRules) {
            RulesEditor(scope: .cueList(list.id)).environmentObject(store)
        }
        .sheet(isPresented: $showingBulkFade) {
            VStack(alignment: .leading, spacing: 14) {
                Text("SET CUE LIST FADE OUT")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                Text("Apply the same fade-out duration to every cue in ‘\(list.name)’. Undo with Cmd+Z.")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Seconds")
                    TextField("Fade out", text: $bulkFadeDraft).frame(width: 110)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingBulkFade = false }
                    Button("Apply") {
                        if let value = Double(bulkFadeDraft.replacingOccurrences(of: ",", with: ".")),
                           value.isFinite, (0...600).contains(value) {
                            store.setFadeOutForList(list.id, to: value)
                            showingBulkFade = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled({
                        guard let value = Double(bulkFadeDraft.replacingOccurrences(of: ",", with: ".")) else { return true }
                        return !value.isFinite || !(0...600).contains(value)
                    }())
                }
            }
            .padding(24)
            .frame(width: 430)
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

private struct NormalizationCueSelection: Identifiable {
    let cueID: UUID
    let listID: UUID
    var id: UUID { cueID }
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
    @State private var showingRowNormalization = false
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
        .overlay(alignment: .leading) {
            if cue.tint != .none {
                RoundedRectangle(cornerRadius: 2)
                    .fill(cue.tint.swatch)
                    .frame(width: 4)
                    .padding(.vertical, 5)
            }
        }
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
            if cue.hasAudio {
                Button("Normalize Audio…") { showingRowNormalization = true }
                    .disabled(store.normalizingCueID != nil || !playback.snapshots.isEmpty)
            }
            Menu("Cue Color") {
                ForEach(CueTint.allCases, id: \.self) { tint in
                    Button {
                        store.setCueTint(cue.id, in: listID, to: tint)
                    } label: {
                        if tint == cue.tint { Label(tint.label, systemImage: "checkmark.circle.fill") }
                        else { Text(tint.label) }
                    }
                }
            }
            Button("Delete Cue", role: .destructive) {
                playback.stop(cue.id, notifyRules: false)
                store.removeCue(cue.id, from: listID)
            }
            Menu("Move to Cue List") {
                ForEach(store.show.cueLists.filter { $0.id != listID }) { destination in
                    Button(destination.name) {
                        _ = store.relocateCue(cue.id, to: destination.id,
                                              before: nil, using: playback)
                    }
                }
            }
        }
        .sheet(isPresented: $showingRowNormalization) {
            CueNormalizationView(cueID: cue.id, listID: listID)
                .environmentObject(store)
                .environmentObject(playback)
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
        if cue.tint == .none { return selected ? Skin.gold.opacity(0.15) : Skin.raised }
        return cue.tint.swatch.opacity(selected ? 0.32 : 0.22)
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
            if cue.hasAudio {
                Button {
                    store.editCueInDAW(cue.id, in: listID)
                } label: {
                    if store.dawBridgeBusy && store.dawBridgeCueID == cue.id {
                        ProgressView().controlSize(.mini).frame(width: 21, height: 21)
                    } else {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .foregroundColor(Skin.gold)
                    }
                }
                .disabled(store.dawBridgeBusy)
                .help("EDIT IN SCULPT DAW — open this cue as an editable DAW session")
                .accessibilityLabel("Edit cue in Sculpt DAW")
            }
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
            Button { playback.playCueLocally(cue) } label: { Image(systemName: "play.fill") }
                .disabled(!cue.enabled)
                .help("Cue PLAY: start from the blue audition cursor set on WAVEFORMS. Global GO always starts at zero.")
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
