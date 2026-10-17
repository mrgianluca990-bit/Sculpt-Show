import SwiftUI
import AVFAudio
import SculptShowCore

/// Reduced-resolution sample peaks, computed off the main thread. Original
/// audio is never modified. Mono/stereo files have independent channel lanes.
struct ShowWaveformEnvelope: Sendable {
    let duration: Double
    let peaks: [[Float]]
}

private enum ShowWaveformDecoder {
    // Increased temporal resolution: on a 4-minute cue 16k bins provide
    // approximately 15ms peak windows, compared to ~133ms at 1800 bins.
    // The canvas below aggregates peaks per screen pixel to keep UI responsive.
    static func scan(_ path: String, bins: Int = 64000) -> ShowWaveformEnvelope? {
        guard let source = try? SculptPCMReader(URL(fileURLWithPath: path)),
              source.sampleRate > 0, source.frameCount > 0 else { return nil }
        let count = max(64, bins)
        let total = Double(source.frameCount)
        var output = [[Float]](repeating: [Float](repeating: 0, count: count),
                               count: source.channels)
        var seen: Int64 = 0
        do {
            while true {
                let pcm = try source.next()
                guard let first = pcm.first, !first.isEmpty else { break }
                for frame in 0..<first.count {
                    let bin = min(count - 1, max(0,
                        Int(((Double(seen) + Double(frame)) / total) * Double(count))))
                    for channel in 0..<source.channels {
                        let value = abs(pcm[channel][frame])
                        if value.isFinite { output[channel][bin] = max(output[channel][bin], value) }
                    }
                }
                seen += Int64(first.count)
            }
        } catch { return nil }
        guard seen > 0 else { return nil }
        return ShowWaveformEnvelope(duration: Double(seen) / source.sampleRate,
                                    peaks: output)
    }

    /// Detect attacks at approximately 5ms hop size directly from PCM;
    /// never infer transients from a screen-resolution waveform.
    static func transients(_ path: String) -> [Double] {
        guard let reader = try? SculptPCMReader(URL(fileURLWithPath: path)),
              reader.sampleRate > 0, reader.frameCount > 0 else { return [] }
        let hop = max(48, Int(reader.sampleRate * 0.005))
        var peaks: [Float] = []
        var framesInHop = 0
        var peak: Float = 0
        var globalPeak: Float = 0
        do {
            while true {
                let channels = try reader.next()
                guard let first = channels.first, !first.isEmpty else { break }
                for i in first.indices {
                    var amplitude: Float = 0
                    for ch in channels {
                        amplitude = max(amplitude, abs(ch[i]))
                    }
                    if amplitude.isFinite { peak = max(peak, amplitude) }
                    framesInHop += 1
                    if framesInHop == hop {
                        peaks.append(peak)
                        globalPeak = max(globalPeak, peak)
                        peak = 0
                        framesInHop = 0
                    }
                }
            }
        } catch { return [] }
        guard globalPeak > 0.0001 else { return [] }
        let threshold = max(0.006, globalPeak * 0.065)
        var baseline: Float = 0
        var attacks: [Double] = []
        var lastHit = -1.0
        for (index, samplePeak) in peaks.enumerated() {
            let seconds = Double(index * hop) / reader.sampleRate
            if samplePeak >= threshold,
               samplePeak > baseline * 1.55,
               samplePeak - baseline > max(0.004, globalPeak * 0.025),
               seconds - lastHit >= 0.045 {
                attacks.append(seconds)
                lastHit = seconds
            }
            baseline = baseline * 0.88 + samplePeak * 0.12
        }
        return attacks
    }
}

/// Preflight before importing: commit a cue only when its waveforms are ready.
/// Previously waveform requests ran after the cue was displayed, requiring
/// users to switch cue to force a refreshed waveform/channel layout.
@MainActor
final class ShowWaveformCache: ObservableObject {
    static let shared = ShowWaveformCache()
    @Published private(set) var envelopes: [String: ShowWaveformEnvelope] = [:]
    @Published private(set) var failed: Set<String> = []
    private var pending: Set<String> = []
    private var transientCache: [String: [Double]] = [:]
    /// Clicking a waveform stem selects the track that Tab follows.
    var focusedTransientPath: String?

    func nextTransient(in cue: Cue, after seconds: Double) async -> Double? {
        let paths = cue.audioElements.map(\.sourcePath)
        guard let path = (focusedTransientPath.flatMap { paths.contains($0) ? $0 : nil }) ?? paths.first else { return nil }
        if transientCache[path] == nil {
            let hits = await Task.detached(priority: .userInitiated) {
                ShowWaveformDecoder.transients(path)
            }.value
            transientCache[path] = hits
        }
        return transientCache[path]?.first(where: { $0 > seconds + 0.002 })
    }

    func channels(at path: String) -> Int? { envelopes[path]?.peaks.count }

    /// Saving a portable Show copies its media under Audio Files and relinks
    /// each stem to that copy. The bytes are identical: transfer prepared peaks
    /// immediately instead of showing an empty waveform until a cue switch.
    func adoptSavedMedia(from previous: Show, to saved: Show) {
        var oldPaths: [UUID: String] = [:]
        for list in previous.cueLists {
            for cue in list.cues {
                for element in cue.audioElements { oldPaths[element.id] = element.sourcePath }
            }
        }
        for list in saved.cueLists {
            for cue in list.cues {
                for element in cue.audioElements {
                    let path = element.sourcePath
                    if let oldPath = oldPaths[element.id],
                       let previousEnvelope = envelopes[oldPath] {
                        envelopes[path] = previousEnvelope
                        failed.remove(path)
                    } else {
                        request(path)
                    }
                }
            }
        }
    }

    /// Report actual completed file scans to import UI; other callers remain compatible.
    func prepare(paths: [String], onProgress: ((Int, Int) -> Void)? = nil) async -> [String] {
        let unique = Array(Set(paths))
        let todo = unique.filter { envelopes[$0] == nil }
        guard !todo.isEmpty else { onProgress?(unique.count, unique.count); return [] }
        onProgress?(0, todo.count)
        for (index, path) in todo.enumerated() {
            let envelope = await Task.detached(priority: .userInitiated) {
                ShowWaveformDecoder.scan(path)
            }.value
            if let envelope {
                envelopes[path] = envelope
                failed.remove(path)
            } else {
                failed.insert(path)
            }
            onProgress?(index + 1, todo.count)
        }
        return unique.filter { envelopes[$0] == nil }
    }

    func request(_ path: String) {
        guard !pending.contains(path), envelopes[path] == nil, !failed.contains(path) else { return }
        pending.insert(path)
        Task {
            let result = await Task.detached(priority: .utility) {
                ShowWaveformDecoder.scan(path)
            }.value
            pending.remove(path)
            if let result { envelopes[path] = result }
            else { failed.insert(path) }
        }
    }
}

/// Cue Native -> Show: shared cue waveform editor and Ovation-like marker rail.
/// Static PCM waveform canvases are Equatable and are NOT redrawn at every playhead tick.
struct ShowWaveformOverview: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @Binding var selectedMarkerID: UUID?
    @State private var zoom: Double = 1
    @State private var snap: Double = 0.001
    @StateObject private var cache = ShowWaveformCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Label("CUE WAVEFORMS", systemImage: "waveform")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.93, green: 0.70, blue: 0.38))
                if let cue = store.selectedCue {
                    Text(cue.name).lineLimit(1).foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                }
                Spacer(minLength: 3)
                Button {
                    guard let listID = store.selectedListID else { return }
                    if let cueID = store.selectedCueID {
                        store.attachAudio(to: cueID, in: listID, using: playback)
                    } else {
                        store.importAudio(to: listID)
                    }
                } label: {
                    Label("IMPORT", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(store.isLoadingProject || store.pendingAudioImports > 0)
                .help("Import audio into the selected cue, or create a new cue if none is selected")
                Button("FIT") { zoom = 1 }.controlSize(.small).help("Zoom to full cue")
                Slider(value: $zoom, in: 1...64, step: 1).frame(width: 95)
                Text("\(Int(zoom))×").font(.system(size: 10, design: .monospaced))
                Picker("SNAP", selection: $snap) {
                    Text("1 ms").tag(0.001)
                    Text("100 ms").tag(0.1)
                    Text("1 s").tag(1.0)
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            if let cue = store.selectedCue, let listID = store.selectedListID {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundColor(.cyan)
                    CuePlayFromEditor(cue: cue)
                        .environmentObject(playback)
                    Spacer(minLength: 3)
                    Text("TAB → TRANSIENT")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("+ MARK") {
                        let current = playback.snapshots[cue.id]?.elapsed ?? playback.cuePlayCursor(cue.id)
                        addMarker(cue, listID: listID, at: min(timelineDuration(cue), current))
                    }.controlSize(.small)
                    Button("‹") { seekAdjacent(cue, forward: false) }.help("Previous marker")
                    Button("›") { seekAdjacent(cue, forward: true) }.help("Next marker")
                }
            }
            if let cue = store.selectedCue, let listID = store.selectedListID {
                waveformTracks(cue, listID: listID)
            } else {
                Text("Select a cue to add or drag markers directly on the waveform timeline.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
    }

    private func waveformTracks(_ cue: Cue, listID: UUID) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("MARKERS · double-click to add")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 135, alignment: .leading)
                        MarkerWaveformRuler(cue: cue, listID: listID,
                            duration: timelineDuration(cue), snap: snap,
                            selectedMarkerID: $selectedMarkerID)
                            .environmentObject(store)
                            .environmentObject(playback)
                    }
                    .frame(height: 52)
                    if cue.alignedAudioElements.isEmpty {
                        Text("Empty cue container · marker Rules can still trigger without audio.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    ForEach(cue.alignedAudioElements) { element in
                        WaveformStemLane(cue: cue, element: element,
                            envelope: cache.envelopes[element.sourcePath],
                            failed: cache.failed.contains(element.sourcePath),
                            duration: timelineDuration(cue),
                            playhead: playback.snapshots[cue.id]?.elapsed,
                            auditionCursor: playback.cuePlayCursor(cue.id),
                            listID: listID, snap: snap,
                            selectedMarkerID: $selectedMarkerID)
                            .environmentObject(playback)
                    }
                }
                .frame(width: max(350, geo.size.width * zoom - 8), alignment: .leading)
            }
        }
        .onAppear { queue(cue) }
        .onChange(of: cue.id) { _ in
            selectedMarkerID = nil
            queue(cue)
        }
        .onChange(of: cue.elements) { _ in queue(cue) }
    }

    private func addMarker(_ cue: Cue, listID: UUID, at seconds: Double) {
        let snapped = (seconds / snap).rounded() * snap
        selectedMarkerID = store.addMarker(to: cue.id, in: listID,
                                            at: max(0, min(timelineDuration(cue), snapped)))
    }

    private func seekAdjacent(_ cue: Cue, forward: Bool) {
        let position = playback.snapshots[cue.id]?.elapsed ?? playback.cuePlayCursor(cue.id)
        if let marker = MarkerTimelineGeometry.adjacent(to: position, markers: cue.markers,
                                                        forward: forward) {
            selectedMarkerID = marker.id
            playback.setCuePlayCursor(cue.id, to: marker.positionSeconds)
            if playback.snapshots[cue.id] != nil {
                playback.seek(cue.id, toSeconds: marker.positionSeconds)
            }
        }
    }

    private func queue(_ cue: Cue) {
        for element in cue.audioElements { cache.request(element.sourcePath) }
    }

    private func timelineDuration(_ cue: Cue) -> Double {
        if cue.durationMode == .fixed { return max(cue.durationSeconds, 0.01) }
        return max(0.01, cue.audioElements.compactMap { cache.envelopes[$0.sourcePath]?.duration }.max() ?? cue.durationSeconds)
    }
}

/// Interactive ruler shares the precise x-axis with every waveform lane.
/// Drag updates a LOCAL preview only; the show model gets one atomic edit
/// on release. The active audio engine is never paused or rescheduled.
private struct MarkerWaveformRuler: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    let duration: Double
    let snap: Double
    @Binding var selectedMarkerID: UUID?
    @State private var draggingMarkerID: UUID?
    @State private var previewSeconds: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.16))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                        let seconds = MarkerTimelineGeometry.clampedTime(
                            x: Double(tap.location.x), width: Double(geo.size.width),
                            duration: duration, snap: snap)
                        selectedMarkerID = store.addMarker(to: cue.id, in: listID, at: seconds)
                    })
                // Light grid divides timeline into equal 10% intervals.
                ForEach(1..<10, id: \.self) { tick in
                    Rectangle().fill(Color.gray.opacity(0.20))
                        .frame(width: 1)
                        .offset(x: geo.size.width * CGFloat(tick) / 10)
                        .allowsHitTesting(false)
                }
                ForEach(Array(cue.sortedMarkers.enumerated()), id: \.element.id) { entry in
                    let marker = entry.element
                    let position = (draggingMarkerID == marker.id ? previewSeconds : nil)
                                   ?? marker.positionSeconds
                    markerHandle(marker, number: entry.offset + 1,
                                 x: CGFloat(MarkerTimelineGeometry.x(
                                      time: position, width: Double(geo.size.width),
                                      duration: duration)), width: geo.size.width)
                }
            }
            .frame(height: 52)
            .coordinateSpace(name: "waveform-marker-ruler")
        }
        .frame(height: 52)
    }

    private func markerHandle(_ marker: CueMarker, number: Int, x: CGFloat,
                              width: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text("M\(number)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Image(systemName: marker.rules.isEmpty ? "mappin" : "bolt.fill")
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundColor(selectedMarkerID == marker.id ? .yellow : .orange)
        .frame(width: 29, height: 43)
        .overlay(alignment: .topLeading) {
            Text(marker.name.isEmpty ? "Marker" : marker.name)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 115, alignment: .leading)
                .foregroundColor(selectedMarkerID == marker.id ? .yellow : .orange)
                .offset(x: 27, y: 12)
                .allowsHitTesting(false)
        }
        .background(selectedMarkerID == marker.id
                    ? Color.orange.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .position(x: min(max(15, x), max(15, width - 15)), y: 26)
        .onTapGesture {
            selectedMarkerID = marker.id
            playback.setCuePlayCursor(cue.id, to: marker.positionSeconds)
        }
        .gesture(DragGesture(minimumDistance: 3,
                             coordinateSpace: .named("waveform-marker-ruler"))
            .onChanged { move in
                draggingMarkerID = marker.id
                previewSeconds = MarkerTimelineGeometry.clampedTime(
                    x: Double(move.location.x), width: Double(width),
                    duration: duration, snap: snap)
                selectedMarkerID = marker.id
            }
            .onEnded { move in
                let seconds = MarkerTimelineGeometry.clampedTime(
                    x: Double(move.location.x), width: Double(width),
                    duration: duration, snap: snap)
                draggingMarkerID = nil
                previewSeconds = nil
                store.setMarkerPosition(marker.id, cueID: cue.id,
                                        listID: listID, to: seconds)
                selectedMarkerID = marker.id
            })
        .help("\(marker.name) · drag to move; click to edit name/time/Rules in Inspector")
    }
}

private struct WaveformStemLane: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let element: CueElement
    let envelope: ShowWaveformEnvelope?
    let failed: Bool
    let duration: Double
    let playhead: Double?
    let auditionCursor: Double
    let listID: UUID
    let snap: Double
    @Binding var selectedMarkerID: UUID?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(element.name).font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text("OUT \(element.outputStartChannel)" +
                         ((envelope?.peaks.count ?? 1) > 1 ? "/\(element.outputStartChannel + 1)" : ""))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    if cue.audioElements.count > 1 {
                        Button {
                            store.moveAudioStem(element.id, in: cue.id, listID: listID, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(cue.audioElements.first?.id == element.id)
                        .help("Move stem up")
                        Button {
                            store.moveAudioStem(element.id, in: cue.id, listID: listID, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(cue.audioElements.last?.id == element.id)
                        .help("Move stem down")
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 135, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5))
                    if let envelope {
                        StaticWaveformDrawing(path: element.sourcePath,
                                              envelope: envelope, duration: duration)
                            .equatable()
                    } else {
                        Text(failed ? "MISSING / UNSUPPORTED AUDIO" : "ANALYZING AUDIO...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(failed ? .orange : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Marker lines are draggable directly ON every waveform,
                    // not just from the common ruler. They share one marker ID.
                    ForEach(cue.markers) { marker in
                        if marker.positionSeconds <= duration {
                            WaveformMarkerLine(cueID: cue.id, listID: listID,
                                marker: marker, duration: duration,
                                width: geometry.size.width, snap: snap,
                                selectedMarkerID: $selectedMarkerID)
                        }
                    }
                    if playhead == nil {
                        // Blue = an idle audition location, not the live cue playhead.
                        Rectangle().fill(Color.cyan.opacity(0.95))
                            .frame(width: 2)
                            .offset(x: CGFloat(MarkerTimelineGeometry.x(
                                time: auditionCursor, width: Double(geometry.size.width),
                                duration: duration)))
                            .allowsHitTesting(false)
                    }
                    if let playhead {
                        Rectangle().fill(Color.white)
                            .frame(width: 2)
                            .offset(x: CGFloat(MarkerTimelineGeometry.x(
                                time: playhead, width: Double(geometry.size.width),
                                duration: duration)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "waveform-marker-lane")
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let seconds = MarkerTimelineGeometry.clampedTime(
                        x: Double(tap.location.x), width: Double(geometry.size.width),
                        duration: duration, snap: snap)
                    // Tab-to-Transient follows the last clicked stem.
                    ShowWaveformCache.shared.focusedTransientPath = element.sourcePath
                    // A click locates the local audition cursor even if no cue
                    // is currently playing. The real SHOW GO ignores it.
                    playback.setCuePlayCursor(cue.id, to: seconds)
                    if playback.snapshots[cue.id] != nil {
                        playback.seek(cue.id, toSeconds: seconds)
                    }
                })
                .help("Click to set blue local PLAY cursor. If playing, also seek live. Global GO always starts at zero.")
            }
            .frame(height: (envelope?.peaks.count ?? 1) > 1 ? 104 : 68)
        }
        .padding(.vertical, 3)
    }
}

/// Cached PCM peak strokes are isolated from playhead updates.
/// SwiftUI compares only stable file identity and cue duration; audio buffers
/// stay cached separately. Zoom/resize still redraw because geometry changes.
private struct StaticWaveformDrawing: View, Equatable {
    let path: String
    let envelope: ShowWaveformEnvelope
    let duration: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.duration == rhs.duration &&
        lhs.envelope.duration == rhs.envelope.duration &&
        lhs.envelope.peaks.count == rhs.envelope.peaks.count &&
        lhs.envelope.peaks.first?.count == rhs.envelope.peaks.first?.count
    }

    var body: some View {
        GeometryReader { geometry in
            // Split very wide (64× zoom) waveforms into viewport-sized tiles.
            // A single 60k-pixel Canvas can exceed the GPU's texture limits.
            let fullWidth = max(1, Double(geometry.size.width))
            let tileWidth = 1536.0
            let tiles = max(1, Int(ceil(fullWidth / tileWidth)))
            LazyHStack(spacing: 0) {
                ForEach(0..<tiles, id: \.self) { tile in
                    let offset = Double(tile) * tileWidth
                    let width = min(tileWidth, fullWidth - offset)
                    Canvas { context, size in
                        let lanes = envelope.peaks
                        guard !lanes.isEmpty, duration > 0, envelope.duration > 0 else { return }
                        let channelHeight = size.height / CGFloat(lanes.count)
                        let secondsStart = (offset / fullWidth) * duration
                        let secondsEnd = ((offset + width) / fullWidth) * duration
                        for (channel, peaks) in lanes.enumerated() {
                            let midY = CGFloat(channel) * channelHeight + channelHeight / 2
                            let height = channelHeight * 0.45
                            var waveform = Path()
                            let columns = max(1, Int(width))
                            for column in 0..<columns {
                                let seconds = secondsStart +
                                    Double(column) / Double(columns) * (secondsEnd - secondsStart)
                                if seconds > min(duration, envelope.duration) { break }
                                let nextSeconds = secondsStart +
                                    Double(column + 1) / Double(columns) * (secondsEnd - secondsStart)
                                let begin = max(0, min(peaks.count - 1,
                                    Int(seconds / envelope.duration * Double(peaks.count))))
                                let end = max(begin + 1, min(peaks.count,
                                    Int(ceil(nextSeconds / envelope.duration * Double(peaks.count)))))
                                var peak: Float = 0
                                if !peaks.isEmpty {
                                    for i in begin..<end { peak = max(peak, peaks[i]) }
                                }
                                let x = CGFloat(column) / CGFloat(columns) * size.width
                                let strength = min(CGFloat(peak), 1) * height
                                waveform.move(to: CGPoint(x: x, y: midY - strength))
                                waveform.addLine(to: CGPoint(x: x, y: midY + strength))
                            }
                            context.stroke(waveform, with: .color(
                                channel == 0 ? .green.opacity(0.85) : .cyan.opacity(0.85)), lineWidth: 1)
                            var center = Path()
                            center.move(to: CGPoint(x: 0, y: midY))
                            center.addLine(to: CGPoint(x: size.width, y: midY))
                            context.stroke(center, with: .color(.gray.opacity(0.24)), lineWidth: 0.6)
                        }
                    }
                    .frame(width: CGFloat(width), height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
    }
}

/// A generous transparent hit target makes each marker line draggable on the
/// actual waveform. Position preview stays local until release.
private struct WaveformMarkerLine: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cueID: UUID
    let listID: UUID
    let marker: CueMarker
    let duration: Double
    let width: CGFloat
    let snap: Double
    @Binding var selectedMarkerID: UUID?
    @State private var preview: Double?

    var body: some View {
        let seconds = preview ?? marker.positionSeconds
        Rectangle()
            .fill(Color.clear)
            .frame(width: 18)
            .overlay {
                Rectangle()
                    .fill(selectedMarkerID == marker.id ? Color.yellow : Color.orange.opacity(0.65))
                    .frame(width: selectedMarkerID == marker.id ? 2.5 : 1.4)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                Text(marker.name.isEmpty ? "Marker" : marker.name)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(selectedMarkerID == marker.id ? .yellow : .orange)
                    .lineLimit(1)
                    .frame(width: 106, alignment: .leading)
                    .padding(.horizontal, 3)
                    .background(Color.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 2))
                    .offset(x: 13, y: 0)
                    .allowsHitTesting(false)
            }
            .offset(x: CGFloat(MarkerTimelineGeometry.x(time: seconds,
                      width: Double(width), duration: duration)) - 9)
            .onTapGesture {
                selectedMarkerID = marker.id
                playback.setCuePlayCursor(cueID, to: marker.positionSeconds)
            }
            .gesture(DragGesture(minimumDistance: 3,
                                coordinateSpace: .named("waveform-marker-lane"))
                .onChanged { move in
                    selectedMarkerID = marker.id
                    preview = MarkerTimelineGeometry.clampedTime(
                        x: Double(move.location.x), width: Double(width),
                        duration: duration, snap: snap)
                }
                .onEnded { move in
                    let seconds = MarkerTimelineGeometry.clampedTime(
                        x: Double(move.location.x), width: Double(width),
                        duration: duration, snap: snap)
                    preview = nil
                    store.setMarkerPosition(marker.id, cueID: cueID,
                                            listID: listID, to: seconds)
                    selectedMarkerID = marker.id
                })
            .help("Drag \(marker.name) on the waveform; edit its Rules in Inspector")
    }
}

/// Writable audition address, intentionally NOT part of the .scshow format.
/// Commit before local PLAY so the editor works even without pressing Return.
private struct CuePlayFromEditor: View {
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    @State private var typed = ""
    @State private var invalid = false
    @FocusState private var hasFocus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("PLAY FROM")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            TextField("HH:MM:SS:MMM", text: $typed)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .frame(width: 138)
                .focused($hasFocus)
                .foregroundColor(invalid ? .orange : .primary)
                .onSubmit { if commit() { hasFocus = false } }
                .onChange(of: hasFocus) { focused in
                    if !focused { commit() }
                }
                .onChange(of: playback.cuePlayCursor(cue.id)) { seconds in
                    if !hasFocus { typed = CueClock.format(seconds); invalid = false }
                }
            Button("ZERO") {
                playback.setCuePlayCursor(cue.id, to: 0)
                typed = CueClock.format(0)
                invalid = false
            }
            .controlSize(.small)
            Button {
                guard commit() else { return }
                _ = playback.playCueLocally(cue)
            } label: {
                Label("PLAY CUE", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(!cue.enabled)
            .help("PLAY uses this editable location; GLOBAL GO always starts at 00:00:00:000")
        }
        .onAppear { typed = CueClock.format(playback.cuePlayCursor(cue.id)) }
        .onChange(of: cue.id) { _ in
            typed = CueClock.format(playback.cuePlayCursor(cue.id))
            invalid = false
        }
    }

    @discardableResult private func commit() -> Bool {
        guard let seconds = CueClock.parse(typed),
              cue.durationMode != .fixed || seconds < cue.durationSeconds else {
            invalid = true
            return false
        }
        playback.setCuePlayCursor(cue.id, to: seconds)
        typed = CueClock.format(seconds)
        invalid = false
        return true
    }
}
