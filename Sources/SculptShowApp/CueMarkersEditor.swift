import SwiftUI
import SculptShowCore

/// Ovation-inspired cue timeline ruler: markers are numbered in chronological order,
/// selectable, draggable, editable and may hold their own Interaction Rules.
struct CueMarkersEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID

    @State private var selectedMarkerID: UUID?
    @State private var editingMarker: CueMarker?
    @State private var markerName = ""
    @State private var markerTime = ""
    @State private var invalidTime = false
    @FocusState private var editingTime: Bool

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
    private var playhead: Double { playback.snapshots[cue.id]?.elapsed ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CUE MARKERS (\(cue.markers.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Button { addAtPlayhead() } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Insert a marker at the playing cue position, or at 00:00:00:000 when stopped")
            }
            ruler
            if ordered.isEmpty {
                Text("Add a marker, drag it on the timeline, then assign Reaching Marker rules.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { numbered in
                    HStack(spacing: 6) {
                        Button {
                            choose(numbered.element)
                        } label: {
                            HStack(spacing: 5) {
                                Text("M\(numbered.offset + 1)").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange)
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
                    .onSubmit(commitName)
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
                        .foregroundStyle(.orange).font(.caption)
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
        .onChange(of: cue.markers) { changed in
            playback.updateMarkers(changed, for: cue.id)
            if let selectedID = selectedMarkerID,
               !changed.contains(where: { $0.id == selectedID }) { selectedMarkerID = nil }
        }
        .sheet(item: $editingMarker) { marker in
            RulesEditor(scope: .marker(marker.id, in: cue.id))
                .environmentObject(store)
        }
    }

    private var ruler: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.gray.opacity(0.16))
                    .frame(height: 50)
                Rectangle().fill(Color.gray.opacity(0.45))
                    .frame(height: 1).padding(.horizontal, 8)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { numbered in
                    markerHandle(numbered.element, number: numbered.offset + 1, width: geo.size.width)
                }
                if playback.snapshots[cue.id] != nil {
                    Rectangle().fill(Color.green)
                        .frame(width: 2, height: 44)
                        .offset(x: xPosition(playhead, width: geo.size.width) - 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 50)
            .coordinateSpace(name: "marker-timeline")
        }
        .frame(height: 50)
        .help("Click a marker to select; drag a marker horizontally to reposition; double-click for Rules")
    }

    private func markerHandle(_ marker: CueMarker, number: Int, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text("\(number)").font(.system(size: 10, weight: .bold, design: .monospaced))
            Image(systemName: marker.rules.isEmpty ? "mappin" : "mappin.and.ellipse")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(selectedMarkerID == marker.id ? Color.yellow : Color.orange)
        .frame(width: 27, height: 41)
        .contentShape(Rectangle())
        .position(x: xPosition(marker.positionSeconds, width: width), y: 24)
        .onTapGesture(count: 2) {
            choose(marker)
            editingMarker = marker
        }
        .onTapGesture { choose(marker) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("marker-timeline"))
            .onEnded { value in
                let fraction = min(max(Double(value.location.x / max(1, width)), 0), 1)
                let updated = (fraction * duration * 1000).rounded() / 1000
                store.setMarkerPosition(marker.id, cueID: cue.id, listID: listID, to: updated)
                selectedMarkerID = marker.id
                markerTime = CueClock.format(updated)
            })
    }

    private func xPosition(_ time: Double, width: CGFloat) -> CGFloat {
        max(14, min(max(14, width - 14), CGFloat(min(max(0, time / duration), 1)) * width))
    }

    private func restoreSelection() {
        if let marker = cue.sortedMarkers.first { choose(marker) }
    }

    private func choose(_ marker: CueMarker) {
        selectedMarkerID = marker.id
        markerName = marker.name
        markerTime = CueClock.format(marker.positionSeconds)
        invalidTime = false
    }

    private func addAtPlayhead() {
        guard let id = store.addMarker(to: cue.id, in: listID, at: playhead) else { return }
        selectedMarkerID = id
        markerName = "Marker \(cue.markers.count + 1)"
        markerTime = CueClock.format(playhead)
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
