import Foundation

/// Bound a seek against its file before converting untrusted seconds to an integer.
public enum AudioFramePlan {
    public static func position(seconds: Double, sampleRate: Double, fileLength: Int64) -> Int64 {
        guard seconds.isFinite, sampleRate.isFinite, seconds > 0, sampleRate > 0, fileLength > 0 else { return 0 }
        let frames = seconds * sampleRate
        if !frames.isFinite || frames >= Double(fileLength) { return fileLength }
        return Int64(frames)
    }
}
