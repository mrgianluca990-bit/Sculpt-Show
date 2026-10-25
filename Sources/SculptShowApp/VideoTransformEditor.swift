import SwiftUI
import SculptShowCore

struct VideoTransformEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cueID: UUID
    let listID: UUID
    @State private var expanded = false
    private var movie: CueVideo? { store.show.cue(cueID)?.video }
    private func refresh() { if let movie { playback.video.setGeometry(movie, for: cueID) } }
    private func row(_ name: String, value: Double, range: ClosedRange<Double>, edit: @escaping (Double) -> Void) -> some View {
        let binding = Binding(get: { value }, set: { edit($0); refresh() })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.caption)
                Spacer()
                ConfirmedNumberField(value: value * 100, range: (range.lowerBound * 100)...(range.upperBound * 100), label: name) { next in
                    edit(next / 100); refresh()
                }.frame(width: 70, height: 24)
                Text("%").font(.caption)
            }
            Slider(value: binding, in: range)
        }
    }
    var body: some View {
        if let movie {
            DisclosureGroup("VIDEO TRANSFORM", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Transform", selection: Binding(get: { movie.framing ?? .fit }, set: {
                    store.setVideoFraming($0, cueID: cueID, in: listID); refresh()
                })) { ForEach(VideoFraming.allCases, id: \.self) { Text($0.label).tag($0) } }
                row("ZOOM", value: movie.scale, range: 0.1...4) { store.setVideoScale($0, cueID: cueID, in: listID) }
                row("HORIZONTAL · →", value: movie.offsetX ?? 0, range: -2...2) { store.setVideoPosition(x: $0, cueID: cueID, in: listID) }
                row("VERTICAL · ↑", value: movie.offsetY ?? 0, range: -2...2) { store.setVideoPosition(y: $0, cueID: cueID, in: listID) }
                HStack {
                    Button("←") { store.setVideoPosition(x: (movie.offsetX ?? 0) - 0.0001, cueID: cueID, in: listID); refresh() }
                    Button("→") { store.setVideoPosition(x: (movie.offsetX ?? 0) + 0.0001, cueID: cueID, in: listID); refresh() }
                    Button("↑") { store.setVideoPosition(y: (movie.offsetY ?? 0) + 0.0001, cueID: cueID, in: listID); refresh() }
                    Button("↓") { store.setVideoPosition(y: (movie.offsetY ?? 0) - 0.0001, cueID: cueID, in: listID); refresh() }
                    Button("Center") { store.setVideoPosition(x: 0, y: 0, cueID: cueID, in: listID); refresh() }
                }.controlSize(.small).help("Move by 0.01% of the output canvas")
                Text(movie.framing == .fill ? "Crop: width and height resize the crop area; the image keeps its proportions." : movie.framing == .stretch ? "Stretch: width and height deform the image independently." : "Keep proportions: width and height move together.").font(.caption2).foregroundStyle(.secondary)
                row("WIDTH", value: movie.widthScale ?? 1, range: 0.1...4) { store.setVideoDimensions(width: $0, cueID: cueID, in: listID) }
                row("HEIGHT", value: movie.heightScale ?? 1, range: 0.1...4) { store.setVideoDimensions(height: $0, cueID: cueID, in: listID) }
                Button("Reset transform") { store.resetVideoTransform(cueID, in: listID); refresh() }
                HStack {
                    Button("Bring to front") { playback.video.bringToFront(cueID) }
                    Button("Send to back") { playback.video.sendToBack(cueID) }
                }.controlSize(.small).disabled(!playback.video.contains(cueID))
                Text("Multiple visual cues share the output. The last cue launched is on top; each cue keeps its own transform and audio.").font(.caption).foregroundColor(.secondary)
            }
            }
        }
    }
}
