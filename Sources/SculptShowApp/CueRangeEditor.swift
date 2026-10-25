import SwiftUI
import SculptShowCore

extension ShowStore {
    func cueSourceDuration(_ cue: Cue) -> Double {
        if let video = cue.video { return video.duration }
        if cue.durationMode == .fixed { return max(0,min(86400,cue.durationSeconds)) }
        return cue.sourceTimelineLength(audioEnds: cue.audioElements.compactMap { element -> Double? in
            if let cached = ShowWaveformCache.shared.envelopes[element.sourcePath] { return cached.duration }
            guard let file = try? SculptPCMReader(URL(fileURLWithPath: element.sourcePath)) else { return nil }
            return Double(file.frameCount) / Double(file.sampleRate)
        })
    }
    func setCuePlaybackRange(_ cueID: UUID, in listID: UUID, start: Double?, end: Double?, using playback: PlaybackEngine) {
        guard playback.snapshots[cueID] == nil, let cue = show.cue(cueID) else { errorMessage = "Stop this cue before editing IN/OUT."; return }
        var updated = show
        if start == nil && end == nil { updated.updateCue(cueID, in:listID) { $0.playbackRange = nil } }
        else {
            let full = cueSourceDuration(cue)
            let next = CuePlaybackRange(start: start ?? cue.playbackStart, end: end ?? cue.playbackRange?.end ?? full)
            guard next.isValid, next.end <= full + 0.00001 else { errorMessage = "IN must precede OUT by at least 1 ms; both must be within the full cue timeline."; return }
            updated.updateCue(cueID, in:listID) { $0.playbackRange = next }
        }
        // Preserve one atomic Undo/save transaction and the source timeline/markers.
        commitCueRange(updated)
    }
}

struct CueRangeEditor: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    var compact = false
    var body: some View {
        let full = store.cueSourceDuration(cue)
        VStack(alignment:.leading, spacing:6) {
            if !compact { Text("PLAYBACK IN / OUT · HH:MM:SS:MMM").font(.caption.bold()) }
            HStack(spacing:6) {
                Text("IN").font(.caption.bold())
                ConfirmedNumberField(value:cue.playbackStart,range:0...max(0,full-0.001),clock:true,label:"Cue IN HH:MM:SS:MMM") {
                    store.setCuePlaybackRange(cue.id,in:listID,start:$0,end:nil,using:playback)
                }.frame(width:120,height:24)
                Text("OUT").font(.caption.bold())
                ConfirmedNumberField(value:cue.playbackRange?.end ?? full,range:0...max(0,full),clock:true,label:"Cue OUT HH:MM:SS:MMM") {
                    store.setCuePlaybackRange(cue.id,in:listID,start:nil,end:$0,using:playback)
                }.frame(width:120,height:24)
            }
            if !compact { Text("Return confirms. GO starts at IN; playback ends at OUT. Enable automatic fades separately in General. Stop this cue before editing.").font(.caption2).foregroundStyle(.secondary) }
            Button("Full range") { store.setCuePlaybackRange(cue.id,in:listID,start:nil,end:nil,using:playback) }.controlSize(.small)
        }.disabled(playback.snapshots[cue.id] != nil || full < 0.001)
    }
}

struct CueRangeWaveformRail: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    let duration: Double
    let snap: Double
    @State private var preview: Double?
    @State private var movingStart = false
    var body: some View {
        GeometryReader { geo in
            let start = movingStart ? (preview ?? cue.playbackStart) : cue.playbackStart
            let end = !movingStart ? (preview ?? cue.playbackRange?.end ?? duration) : (cue.playbackRange?.end ?? duration)
            let x1 = CGFloat(start / duration) * geo.size.width, x2 = CGFloat(end / duration) * geo.size.width
            ZStack(alignment:.topLeading) {
                Rectangle().fill(Color.black.opacity(0.35))
                Rectangle().fill(Color.cyan.opacity(0.18)).frame(width:max(0,x2-x1)).offset(x:x1)
                handle("IN",x:x1,start:true,width:geo.size.width)
                handle("OUT",x:x2,start:false,width:geo.size.width)
            }.coordinateSpace(name:"cue-range-rail")
        }.frame(height:28).disabled(playback.snapshots[cue.id] != nil)
    }
    private func handle(_ label:String,x:CGFloat,start:Bool,width:CGFloat) -> some View {
        Text(label).font(.system(size:10,weight:.bold,design:.monospaced)).foregroundStyle(Color.cyan)
            .frame(width:32,height:26).background(Color.black.opacity(0.8),in:RoundedRectangle(cornerRadius:4))
            .offset(x:min(max(0,x-16),max(0,width-32)))
            .gesture(DragGesture(minimumDistance:2,coordinateSpace:.named("cue-range-rail"))
                .onChanged { value in
                    movingStart = start
                    let seconds = MarkerTimelineGeometry.clampedTime(x:Double(value.location.x),width:Double(width),duration:duration,snap:snap)
                    preview = start ? min(seconds,(cue.playbackRange?.end ?? duration)-0.001) : max(cue.playbackStart+0.001,seconds)
                }.onEnded { _ in
                    if let preview { store.setCuePlaybackRange(cue.id,in:listID,start:start ? preview : nil,end:start ? nil : preview,using:playback) }
                    preview = nil
                })
            .help("Drag \(label); source seconds can also be typed in General or above the waveform. Stop this cue first.")
    }
}

struct WaveformRangeBoundary: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let listID: UUID
    let duration: Double
    let width: CGFloat
    let snap: Double
    let start: Bool
    @State private var preview: Double?
    var body: some View {
        let position = preview ?? (start ? cue.playbackStart : (cue.playbackRange?.end ?? duration))
        ZStack(alignment:.top) {
            Rectangle().fill(Color.cyan).frame(width:2)
            Text(start ? "IN" : "OUT").font(.system(size:9,weight:.bold,design:.monospaced)).foregroundStyle(SculptTheme.accent).padding(2).background(.black.opacity(0.8))
        }.frame(width:26).contentShape(Rectangle())
            .offset(x:CGFloat(position/duration)*width-13)
            .gesture(DragGesture(minimumDistance:2,coordinateSpace:.named("waveform-marker-lane"))
                .onChanged { value in
                    let time = MarkerTimelineGeometry.clampedTime(x:Double(value.location.x),width:Double(width),duration:duration,snap:snap)
                    preview = start ? min(time,(cue.playbackRange?.end ?? duration)-0.001) : max(cue.playbackStart+0.001,time)
                }.onEnded { _ in
                    if let preview { store.setCuePlaybackRange(cue.id,in:listID,start:start ? preview : nil,end:start ? nil : preview,using:playback) }
                    preview = nil
                })
            .disabled(playback.snapshots[cue.id] != nil)
            .help(start ? "Drag cue IN" : "Drag cue OUT")
    }
}
