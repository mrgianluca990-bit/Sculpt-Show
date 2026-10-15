import Foundation

/// Sample-independent marker placement geometry. UI drag preview must not
/// mutate a running cue; the final value is committed only on gesture end.
public enum MarkerTimelineGeometry {
    public static func clampedTime(x: Double, width: Double, duration: Double,
                                   snap: Double = 0.001) -> Double {
        guard x.isFinite, width.isFinite, duration.isFinite,
              width > 0, duration > 0 else { return 0 }
        let raw = min(max(0, x / width), 1) * min(duration, 86400)
        let step = snap.isFinite && snap > 0 ? snap : 0.001
        return min(min(duration, 86400), max(0, (raw / step).rounded() * step))
    }

    public static func x(time: Double, width: Double, duration: Double) -> Double {
        guard time.isFinite, width.isFinite, duration.isFinite,
              width > 0, duration > 0 else { return 0 }
        return min(max(0, time / duration), 1) * width
    }

    public static func adjacent(to seconds: Double, markers: [CueMarker], forward: Bool) -> CueMarker? {
        let ordered = markers.sorted {
            $0.positionSeconds == $1.positionSeconds
                ? $0.id.uuidString < $1.id.uuidString
                : $0.positionSeconds < $1.positionSeconds
        }
        if forward { return ordered.first { $0.positionSeconds > seconds + 0.0005 } }
        return ordered.last { $0.positionSeconds < seconds - 0.0005 }
    }
}
