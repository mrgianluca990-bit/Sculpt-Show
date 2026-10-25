import SwiftUI
import SculptShowCore

/// Ovation-inspired cue timeline ruler: markers are numbered in chronological order,
/// selectable, draggable, editable and may hold their own Interaction Rules.
struct CueMarkersEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

    /// Shared selection with Waveforms: Inspector edits the marker picked on the waveform.
    @Binding var selectedMarkerID: UUID?
    @State private var editingMarker: CueMarker?
    @State private var markerName = ""
    @State private var markerTime = ""
    @State private var invalidTime = false
    @FocusState private var editingTime: Bool
    @FocusState private var editingName: Bool

    private var selected: CueMarker? {
        cue.markers.first(where: { $0.id == selectedMarkerID })
    }
    private var ordered: [CueMarker] { cue.sortedMarkers }
    private var duration: Double {
        if let state = playback.snapshots[cue.id], state.phase != .waiting {
            return max(0.001, state.duration)
        }
        if cue.durationMode == .fixed { return max(0.001, cue.durationSeconds) }
        return max(0.001, cue.audioElements.compactMap { element in
            playback.mediaDuration(for: Cue(name: element.name, mediaPath: element.sourcePath))
        }.max() ?? cue.durationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CUE MARKERS (\(cue.markers.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("ADD / DRAG IN WAVEFORMS")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if ordered.isEmpty {
                Text("Open WAVEFORMS: double-click the marker ruler to create a marker, then select it here to edit name, time and Rules.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { numbered in
                    HStack(spacing: 6) {
                        Button {
                            choose(numbered.element)
                        } label: {
                            HStack(spacing: 5) {
                                Text("M\(numbered.offset + 1)").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(SculptTheme.gold)
                                    .frame(width: 28, alignment: .leading)
                                Text(numbered.element.name).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(CueClock.format(numbered.element.positionSeconds))
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 7)
                            .background(selectedMarkerID == numbered.element.id
                                        ? Color.orange.opacity(0.20) : Color.gray.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        Button {
                            choose(numbered.element)
                            editingMarker = numbered.element
                        } label: {
                            Image(systemName: numbered.element.rules.isEmpty ? "arrow.triangle.branch" : "bolt.fill")
                                .foregroundStyle(numbered.element.rules.isEmpty ? Color.gray : Color.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Edit Reaching Marker Interaction Rules")
                    }
                }
            }

            if let selected {
                Divider()
                Text("SELECTED MARKER · M\((ordered.firstIndex(where: { $0.id == selected.id }) ?? 0) + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Marker name", text: $markerName)
                    .textFieldStyle(.roundedBorder)
                    .focused($editingName)
                    .onSubmit {
                        commitName()
                        editingName = false
                    }
                HStack(spacing: 6) {
                    TextField("HH:MM:SS:MMM", text: $markerTime)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($editingTime)
                        .onSubmit {
                            if commitPosition() { editingTime = false }
                        }
                    Button("Go") {
                        playback.seek(cue.id, toSeconds: selected.positionSeconds)
                    }
                    .disabled(playback.snapshots[cue.id] == nil)
                    .help("Locate the playing cue at this marker (without triggering skipped markers)")
                }
                if invalidTime {
                    Text("Use HH:MM:SS:MMM within the cue duration.")
                        .foregroundStyle(SculptTheme.gold).font(.caption)
                }
                HStack {
                    Button { editingMarker = selected } label: {
                        Label("Rules (\(selected.rules.count))", systemImage: "bolt.fill")
                    }
                    Button(role: .destructive) {
                        store.removeMarker(selected.id, cueID: cue.id, listID: listID)
                        selectedMarkerID = nil
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .controlSize(.small)
                Text("Reaching Marker is the fixed trigger. Fire → Itself loops to the previous marker; Fire → Cue at Marker can locate another cue at a specific marker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { restoreSelection() }
        .onChange(of: cue.id) { _ in
            selectedMarkerID = nil
            restoreSelection()
        }
        .onChange(of: selectedMarkerID) { newID in
            if let marker = cue.markers.first(where: { $0.id == newID }) { choose(marker) }
        }
        .onChange(of: cue.markers) { changed in
            playback.updateMarkers(changed, for: cue.id)
            if let marker = changed.first(where: { $0.id == selectedMarkerID }), !editingTime {
                markerTime = CueClock.format(marker.positionSeconds)
                markerName = marker.name
            }
            if let selectedID = selectedMarkerID,
               !changed.contains(where: { $0.id == selectedID }) { selectedMarkerID = nil }
        }
        .sheet(item: $editingMarker) { marker in
            RulesEditor(scope: .marker(marker.id, in: cue.id))
                .environmentObject(store)
        }
    }

    private func restoreSelection() {
        if let selectedMarkerID,
           let marker = cue.markers.first(where: { $0.id == selectedMarkerID }) {
            choose(marker)
        } else if let marker = cue.sortedMarkers.first {
            choose(marker)
        } else {
            selectedMarkerID = nil
        }
    }

    private func choose(_ marker: CueMarker) {
        selectedMarkerID = marker.id
        markerName = marker.name
        markerTime = CueClock.format(marker.positionSeconds)
        invalidTime = false
    }

    private func commitName() {
        guard let selected else { return }
        let name = markerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { markerName = selected.name; return }
        store.renameMarker(selected.id, cueID: cue.id, listID: listID, to: name)
    }

    private func commitPosition() -> Bool {
        guard let selected, let time = CueClock.parse(markerTime), time <= duration else {
            invalidTime = true
            return false
        }
        invalidTime = false
        store.setMarkerPosition(selected.id, cueID: cue.id, listID: listID, to: time)
        markerTime = CueClock.format(time)
        return true
    }
}
