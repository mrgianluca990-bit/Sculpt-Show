import SwiftUI
import AVFAudio
import SculptShowCore

/// Reduced-resolution sample peaks, computed off the main thread. Original
/// audio is never modified. Mono/stereo files have independent channel lanes.
private struct ShowWaveformEnvelope {
    let duration: Double
    let peaks: [[Float]]
}

private enum ShowWaveformDecoder {
    static func scan(_ path: String, bins: Int = 1800) -> ShowWaveformEnvelope? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              file.processingFormat.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              file.processingFormat.sampleRate > 0, file.length > 0 else { return nil }
        let channels = min(2, Int(file.processingFormat.channelCount))
        guard channels > 0 else { return nil }
        let totalFrames = file.length
        let slotCount = max(64, bins)
        var output = [[Float]](repeating: [Float](repeating: 0, count: slotCount), count: channels)
        var seen: AVAudioFramePosition = 0
        do {
            while seen < totalFrames {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(8192), totalFrames - seen)))
                let n = Int(buffer.frameLength)
                guard n > 0, let samples = buffer.floatChannelData else { break }
                for frame in 0..<n {
                    let bin = min(slotCount - 1, Int((Double(seen) + Double(frame)) / Double(totalFrames) * Double(slotCount)))
                    for channel in 0..<channels {
                        let value = abs(samples[channel][frame])
                        if value.isFinite { output[channel][bin] = max(output[channel][bin], value) }
                    }
                }
                seen += AVAudioFramePosition(n)
            }
        } catch { return nil }
        return ShowWaveformEnvelope(duration: Double(totalFrames) / file.processingFormat.sampleRate,
                                    peaks: output)
    }
}

/// Shared cache ensures that switching cues, resizing the dock and the Inspector
/// don't continually decode the same files. No disk caches, no audio graph calls.
@MainActor
private final class ShowWaveformCache: ObservableObject {
    static let shared = ShowWaveformCache()
    @Published private(set) var envelopes: [String: ShowWaveformEnvelope] = [:]
    @Published private(set) var failed: Set<String> = []
    private var pending: Set<String> = []

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

/// Cue Native -> Show: multitrack waveform dock with shared playback playhead,
/// overlay of cue-local markers, horizontal zoom, per-stem L/R and live seeking.
struct ShowWaveformOverview: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var zoom: Double = 1
    @StateObject private var cache = ShowWaveformCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("CUE WAVEFORMS", systemImage: "waveform")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.93, green: 0.70, blue: 0.38))
                if let cue = store.selectedCue {
                    Text(cue.name).lineLimit(1).foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                }
                Spacer(minLength: 3)
                Text("ZOOM").font(.system(size: 9, design: .monospaced))
                Slider(value: $zoom, in: 1...12, step: 1).frame(width: 110)
                Text("\(Int(zoom))×").font(.system(size: 10, design: .monospaced)).frame(width: 26)
                if let cue = store.selectedCue,
                   let listID = store.selectedListID,
                   let state = playback.snapshots[cue.id] {
                    Button("MARK AT PLAYHEAD") {
                        store.addMarker(to: cue.id, in: listID, at: state.elapsed)
                    }
                    .controlSize(.small)
                }
            }
            if let cue = store.selectedCue, !cue.audioElements.isEmpty {
                waveformTracks(cue)
            } else {
                Text("Select a cue containing audio to inspect its aligned waveforms and markers.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18))
    }

    private func waveformTracks(_ cue: Cue) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cue.alignedAudioElements) { element in
                        WaveformStemLane(cue: cue, element: element,
                            envelope: cache.envelopes[element.sourcePath],
                            failed: cache.failed.contains(element.sourcePath),
                            duration: timelineDuration(cue),
                            playhead: playback.snapshots[cue.id]?.elapsed,
                            zoom: zoom)
                            .environmentObject(playback)
                    }
                }
                .frame(width: max(350, geo.size.width * zoom - 8), alignment: .leading)
            }
        }
        .onAppear { queue(cue) }
        .onChange(of: cue.id) { _ in queue(cue) }
        .onChange(of: cue.elements) { _ in queue(cue) }
    }

    private func queue(_ cue: Cue) {
        for element in cue.audioElements { cache.request(element.sourcePath) }
    }

    private func timelineDuration(_ cue: Cue) -> Double {
        if cue.durationMode == .fixed { return max(cue.durationSeconds, 0.01) }
        return max(0.01, cue.audioElements.compactMap { cache.envelopes[$0.sourcePath]?.duration }.max() ?? 10)
    }
}

private struct WaveformStemLane: View {
    @EnvironmentObject private var playback: PlaybackEngine
    let cue: Cue
    let element: CueElement
    let envelope: ShowWaveformEnvelope?
    let failed: Bool
    let duration: Double
    let playhead: Double?
    let zoom: Double

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(element.name).font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text("OUT \(element.outputStartChannel)" +
                     ((envelope?.peaks.count ?? 1) > 1 ? "/\(element.outputStartChannel + 1)" : ""))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 135, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5))
                    if let envelope {
                        Canvas { context, size in
                            let lanes = envelope.peaks
                            guard !lanes.isEmpty else { return }
                            let channelHeight = size.height / CGFloat(lanes.count)
                            for (channel, peaks) in lanes.enumerated() {
                                let midY = CGFloat(channel) * channelHeight + channelHeight / 2
                                let height = channelHeight * 0.45
                                var line = Path()
                                for (index, peak) in peaks.enumerated() {
                                    let seconds = Double(index) / Double(max(1, peaks.count)) * envelope.duration
                                    if seconds > duration { break }
                                    let x = size.width * CGFloat(seconds / duration)
                                    let strength = min(CGFloat(peak), 1) * height
                                    line.move(to: CGPoint(x: x, y: midY - strength))
                                    line.addLine(to: CGPoint(x: x, y: midY + strength))
                                }
                                context.stroke(line, with: .color(channel == 0 ? .green.opacity(0.85) : .cyan.opacity(0.85)), lineWidth: 1)
                                var center = Path()
                                center.move(to: CGPoint(x: 0, y: midY))
                                center.addLine(to: CGPoint(x: size.width, y: midY))
                                context.stroke(center, with: .color(.gray.opacity(0.24)), lineWidth: 0.6)
                            }
                        }
                    } else {
                        Text(failed ? "MISSING / UNSUPPORTED AUDIO" : "ANALYZING AUDIO...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(failed ? .orange : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(cue.markers) { marker in
                        if marker.positionSeconds <= duration {
                            Rectangle().fill(Color.orange.opacity(0.85))
                                .frame(width: 1.5)
                                .offset(x: CGFloat(marker.positionSeconds / duration) * geometry.size.width)
                                .help("\(marker.name) · \(String(format: "%.3fs", marker.positionSeconds))")
                        }
                    }
                    if let playhead {
                        Rectangle().fill(Color.white)
                            .frame(width: 2)
                            .offset(x: CGFloat(min(max(playhead / duration, 0), 1)) * geometry.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard playback.snapshots[cue.id] != nil else { return }
                    let ratio = min(max(value.location.x / max(1, geometry.size.width), 0), 1)
                    playback.seek(cue.id, toSeconds: duration * Double(ratio))
                })
                .help("Click waveform to seek an active cue. Orange lines = cue markers; white line = playhead.")
            }
            .frame(height: (envelope?.peaks.count ?? 1) > 1 ? 104 : 68)
        }
        .padding(.vertical, 3)
    }
}
