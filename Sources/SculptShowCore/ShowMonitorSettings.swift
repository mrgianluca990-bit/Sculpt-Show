import Foundation

public struct ShowMonitorSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var deviceUID = ""
    public var leftOutput = 1
    public var rightOutput = 2
    public var gain: Double = 1
    public var pan: Double = 0
    public var muted = false
    public var excludeFromMuteAll = true
    public init() {}
    public func validate() throws {
        guard (1...64).contains(leftOutput), (1...64).contains(rightOutput), leftOutput != rightOutput,
              gain.isFinite, (0...1).contains(gain), pan.isFinite, (-1...1).contains(pan),
              !enabled || !deviceUID.isEmpty else { throw Failure.invalid }
    }
    public func isAvailable(deviceUID: String, channels: Int) -> Bool {
        enabled && self.deviceUID == deviceUID && leftOutput != rightOutput &&
        (1...max(1, channels)).contains(leftOutput) && (1...max(1, channels)).contains(rightOutput) && channels > 0
    }
    public func reservedOutputs(deviceUID: String, channels: Int) -> Set<Int> {
        isAvailable(deviceUID: deviceUID, channels: channels) ? [leftOutput, rightOutput] : []
    }
    public enum Failure: LocalizedError {
        case invalid, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalid: return "Select two different physical Monitor outputs and valid gain/pan values."
            case .unavailable: return "The Monitor outputs are unavailable on this interface. Configure or disable Monitor in the mixer before GO."
            }
        }
    }
}

/// Crosspoint weights after the existing per-stem gain node. No duplicate player or file reader.
public enum MonitorMixPlan {
    public struct Gain: Equatable, Sendable {
        public let source: Int
        public let output: Int
        public let value: Float
        public init(source: Int, output: Int, value: Float) { self.source = source; self.output = output; self.value = value }
    }
    private static func balance(_ pan: Double) -> (Double, Double) {
        let p = pan.isFinite ? min(1, max(-1, pan)) : 0
        return (p > 0 ? 1 - p : 1, p < 0 ? 1 + p : 1)
    }
    public static func gains(channels: Int, program: [AudioRoutePlan.Crosspoint], pan: Double,
                             send: Bool, monitor: ShowMonitorSettings) -> [Gain] {
        let input = balance(pan)
        var result = program.map { Gain(source: $0.sourceChannel, output: $0.deviceChannel,
            value: Float(channels == 1 ? 1 : ($0.sourceChannel == 0 ? input.0 : input.1))) }
        guard monitor.enabled, send, !monitor.muted else { return result }
        let master = balance(monitor.pan)
        if channels == 1 {
            let p = pan.isFinite ? min(1, max(-1, pan)) : 0
            result += [Gain(source: 0, output: monitor.leftOutput - 1, value: Float(cos((p + 1) * .pi / 4) * master.0 * monitor.gain)),
                       Gain(source: 0, output: monitor.rightOutput - 1, value: Float(sin((p + 1) * .pi / 4) * master.1 * monitor.gain))]
        } else {
            result += [Gain(source: 0, output: monitor.leftOutput - 1, value: Float(input.0 * master.0 * monitor.gain)),
                       Gain(source: 1, output: monitor.rightOutput - 1, value: Float(input.1 * master.1 * monitor.gain))]
        }
        return result
    }
}
