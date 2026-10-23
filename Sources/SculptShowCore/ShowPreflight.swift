import Foundation

/// A deterministic, side-effect-free show validation pass. The UI provides
/// real decoded file metadata; Core does not open files or touch the audio graph.
public struct PreflightAudioInfo: Equatable, Sendable {
    public var channelCount: Int
    public var duration: Double
    public var sampleRate: Double
    public init(channelCount: Int, duration: Double, sampleRate: Double) {
        self.channelCount = channelCount
        self.duration = duration
        self.sampleRate = sampleRate
    }
}

public enum PreflightSeverity: Int, Codable, Sendable {
    case warning = 1
    case blocking = 2
}

public struct PreflightIssue: Identifiable, Equatable, Sendable {
    public var id: String { "\(cueID?.uuidString ?? "show"):\(code):\(mediaPath ?? "")" }
    public let severity: PreflightSeverity
    public let code: String
    public let cueID: UUID?
    public let cueName: String
    public let mediaPath: String?
    public let message: String
}

public struct ShowPreflightReport: Sendable {
    public let checkedCues: Int
    public let checkedAudioFiles: Int
    public let issues: [PreflightIssue]
    public var blockingCount: Int { issues.filter { $0.severity == .blocking }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public var ready: Bool { blockingCount == 0 }
}

public enum ShowPreflight {
    /// `media` contains successfully decoded source metadata; `nil` means that
    /// the path does not exist or could not be decoded. Paths are exact strings.
    public static func check(_ show: Show, outputChannels: Int,
                             media: [String: PreflightAudioInfo],
                             voiceLimit: Int = 16, deviceUID: String = "") -> ShowPreflightReport {
        var issues: [PreflightIssue] = []
        let cues = show.cueLists.flatMap(\.cues)
        let stems = cues.flatMap(\.audioElements)
        func add(_ severity: PreflightSeverity, _ code: String,
                 _ cue: Cue?, _ path: String? = nil, _ message: String) {
            issues.append(PreflightIssue(severity: severity, code: code,
                cueID: cue?.id, cueName: cue?.name ?? "SHOW",
                mediaPath: path, message: message))
        }
        if outputChannels <= 0 && (!stems.isEmpty || cues.contains(where: { $0.elements.contains(where: { $0.kind == .timecode && !$0.muted }) })) {
            add(.blocking, "no-device", nil, nil,
                "No active Core Audio output. Configure an output device before GO.")
        }
        if outputChannels > 64 {
            add(.blocking, "device-channels", nil, nil,
                "The current audio routing engine supports up to 64 device outputs.")
        }
        let monitorOutputs = show.monitor.reservedOutputs(deviceUID: deviceUID, channels: outputChannels)
        for cue in cues {
            if cue.hasAudio && show.monitor.enabled && !show.monitor.isAvailable(deviceUID: deviceUID, channels: outputChannels) {
                add(.blocking, "monitor-unavailable", cue, nil, ShowMonitorSettings.Failure.unavailable.localizedDescription)
            }
            if cue.audioElements.count > voiceLimit {
                add(.blocking, "voices", cue, nil,
                    "\(cue.audioElements.count) simultaneous stems in this cue exceed the \(voiceLimit)-voice limit.")
            }
            let ltcs = cue.elements.filter { $0.kind == .timecode && !$0.muted }
            if ltcs.count > 1 {
                add(.blocking, "ltc-multiple", cue, nil,
                    "Only one LTC generator can run in one cue.")
            }
            for tc in ltcs {
                if let output = tc.ltcOutputChannel, monitorOutputs.contains(output) {
                    add(.blocking, "ltc-monitor-collision", cue, nil, "LTC output is reserved for Monitor.")
                }
                if tc.ltcOutputChannel == nil || tc.ltcOutputChannel! > outputChannels {
                    add(.blocking, "ltc-output", cue, nil,
                        "LTC requires an explicitly assigned, connected physical output.")
                }
                let rate = LTCFrameRate(fps: tc.frameRate, drop: tc.timecodeDropFrame)
                if LTCTimecode(text: tc.timecodeStart, rate: rate) == nil {
                    add(.blocking, "ltc-start", cue, nil,
                        "Invalid SMPTE timecode for \(rate.label).")
                }
                if LTCFrameTrim(text: tc.ltcTrim, rate: rate) == nil {
                    add(.blocking, "ltc-trim", cue, nil,
                        "Invalid signed LTC trim for \(rate.label). Use ±HH:MM:SS:FF.")
                }
                if cue.durationMode == .fixed && tc.startSeconds >= cue.durationSeconds {
                    add(.warning, "ltc-unreachable", cue, nil,
                        "LTC offset is not inside the cue duration.")
                }
                if cue.durationMode == .mediaEnd && cue.audioElements.isEmpty {
                    add(.blocking, "ltc-duration", cue, nil,
                        "LTC-only cue requires a FIXED container duration.")
                }
            }
            for element in cue.audioElements {
                let path = element.sourcePath
                guard let info = media[path] else {
                    add(.blocking, "media-missing", cue, path,
                        "Missing or unreadable media: \(URL(fileURLWithPath: path).lastPathComponent)")
                    continue
                }
                if ![1, 2].contains(info.channelCount) {
                    add(.blocking, "source-channels", cue, path,
                        "\(element.name): \(info.channelCount)-channel file unsupported (mono/stereo only).")
                    continue
                }
                if !info.duration.isFinite || info.duration <= 0 || info.sampleRate <= 0 {
                    add(.blocking, "invalid-media", cue, path,
                        "\(element.name): invalid source duration or sample rate.")
                }
                let points: [AudioRoutePlan.Crosspoint]
                do {
                    points = try show.outputPatch.crosspoints(firstOutput: element.outputStartChannel,
                        sourceChannels: info.channelCount, deviceUID: deviceUID, deviceChannels: outputChannels, excluding: monitorOutputs)
                } catch {
                    points = []
                    if outputChannels > 0 { add(.blocking, "bad-route", cue, path, "\(element.name): \(error.localizedDescription)") }
                }
                if abs(info.sampleRate - Double(show.sampleRate)) > 0.5 {
                    add(.blocking, "sample-rate", cue, path,
                        "\(element.name): prepare a \(show.sampleRate) Hz copy before GO. Live SRC is disabled.")
                }
                for tc in ltcs {
                    if let out = tc.ltcOutputChannel,
                       points.contains(where: { $0.deviceChannel + 1 == out }) {
                        add(.blocking, "ltc-route-collision", cue, path,
                            "LTC OUT \(out) overlaps a music stem; select a dedicated output.")
                    }
                }
                if show.outputPatch.isAutomatic(on: deviceUID), let first = points.first?.deviceChannel,
                   first + 1 != element.outputStartChannel {
                    add(.warning, "wrapped-route", cue, path,
                        "\(element.name): output wraps to OUT \(first + 1) on this device.")
                }
            }
            if cue.durationMode == .fixed {
                for marker in cue.markers where marker.positionSeconds > cue.durationSeconds {
                    add(.warning, "unreachable-marker", cue, nil,
                        "Marker \(marker.name) occurs after the cue's fixed duration.")
                }
            }
        }
        return ShowPreflightReport(checkedCues: cues.count,
                                  checkedAudioFiles: stems.count,
                                  issues: issues)
    }
}
