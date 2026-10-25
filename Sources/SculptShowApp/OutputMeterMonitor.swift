import Foundation
import Combine
import SculptShowCore

/// UI-only sampled telemetry. Never publishes through PlaybackEngine and never
/// touches Core Audio: updates to meters cannot invalidate the cue list/editor.
@MainActor
final class OutputMeterMonitor: ObservableObject {
    struct Snapshot: Equatable {
        var peaks: [Float] = []
        var rms: [Float] = []
        var holds: [Float] = []
    }

    @Published private(set) var snapshot = Snapshot()
    private var state = OutputPeakHoldState(channelCount: 0)
    private var lastUIUpdate: TimeInterval = 0
    private let minUIInterval: TimeInterval = 1.0 / 12.0

    func configure(channels: Int) {
        state = OutputPeakHoldState(channelCount: channels)
        snapshot = Snapshot(peaks: [Float](repeating: 0, count: channels),
                            rms: [Float](repeating: 0, count: channels),
                            holds: state.values)
        lastUIUpdate = 0
    }

    func observe(peaks: [Float], rms: [Float]) {
        state.observe(peaks)
        let now = ProcessInfo.processInfo.systemUptime
        // The hold state receives *every* peak. Only UI refreshes are capped.
        guard now - lastUIUpdate >= minUIInterval else { return }
        lastUIUpdate = now
        let next = Snapshot(peaks: peaks, rms: rms, holds: state.values)
        if next != snapshot { snapshot = next }
    }

    func resetHolds() {
        state.reset()
        snapshot.holds = state.values
    }

    func level(channel: Int) -> (peak: Float, rms: Float) {
        let index = channel - 1
        guard index >= 0, index < snapshot.peaks.count,
              index < snapshot.rms.count else { return (0, 0) }
        return (snapshot.peaks[index], snapshot.rms[index])
    }

    func peakHold(channel: Int) -> Float {
        let index = channel - 1
        return index >= 0 && index < snapshot.holds.count ? snapshot.holds[index] : 0
    }
}
