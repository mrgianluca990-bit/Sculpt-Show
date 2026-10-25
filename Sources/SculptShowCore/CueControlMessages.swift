import Foundation

public struct CueTimecodeTrigger: Codable, Equatable, Sendable {
    public var address: String
    public var rate: LTCFrameRate
    public init(address: String = "00:00:00:00", rate: LTCFrameRate = .fps25) { self.address = address; self.rate = rate }
}

/// Forward crossings only within a continuous, recently received LTC stream.
/// Locate/backwards/large jumps do not launch all intervening cues. They establish a new baseline.
public struct TimecodeCueScheduler {
    private var previous: LTCTimecode?
    private var stamp: Double?
    public init() {}
    public mutating func reset() { previous = nil; stamp = nil }
    public mutating func consume(_ current: LTCTimecode, at now: Double, in show: Show) -> [UUID] {
        defer { previous = current; stamp = now }
        let day = current.rate == .fps2997DF ? Int64(2_589_408) : Int64(current.rate.nominal * 86400)
        let frame = current.absoluteFrames
        var span: Int64 = 0
        if let previous, previous.rate == current.rate, let stamp, now >= stamp, now - stamp < 0.7 {
            let delta = (frame - previous.absoluteFrames + day) % day
            if delta == 0 { return [] }
            if delta <= Int64(ceil(current.rate.actual * 0.5)) { span = delta }
        }
        return show.cueLists.flatMap(\.cues).compactMap { cue in
            guard cue.enabled, let trigger = cue.triggers.timecode, trigger.rate == current.rate,
                  let target = LTCTimecode(text: trigger.address, rate: trigger.rate) else { return nil }
            let distance = (frame - target.absoluteFrames + day) % day
            return distance == 0 || (span > 0 && distance < span) ? cue.id : nil
        }
    }
}

public struct CueMIDIMessage: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var destination: Int32
    public var status: Int
    public var channel: Int
    public var number: Int
    public var value: Int
    public init(destination: Int32, status: Int = 0xB0, channel: Int = 0, number: Int = 1, value: Int = 127) {
        self.destination = destination; self.status = status; self.channel = channel; self.number = number; self.value = value
    }
    public var isValid: Bool { destination != 0 && [0x80,0x90,0xB0,0xC0].contains(status) && (0...15).contains(channel) && (0...127).contains(number) && (0...127).contains(value) }
    public var bytes: [UInt8] {
        guard isValid else { return [] }
        let prefix = [UInt8(status | channel), UInt8(number)]
        return status == 0xC0 ? prefix : prefix + [UInt8(value)]
    }
}

public enum CueOSCArgument: String, Codable, CaseIterable, Sendable { case none, integer, float, string }
public struct CueOSCMessage: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var host = "127.0.0.1"
    public var port = 53000
    public var address = "/cue"
    public var argument: CueOSCArgument = .none
    public var value = ""
    public init() {}
    public var isValid: Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }),
              (1...65535).contains(port), address.hasPrefix("/"), address.utf8.count <= 256,
              !address.contains(where: { $0.isWhitespace || "\0*?[]{},#".contains($0) }), value.utf8.count <= 1024, !value.contains("\0") else { return false }
        switch argument {
        case .integer: return Int32(value) != nil
        case .float: return Float(value)?.isFinite == true
        default: return true
        }
    }
    public var packet: Data? {
        guard isValid else { return nil }
        func padded(_ value: String) -> Data { var d = Data(value.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; return d }
        var data = padded(address)
        switch argument {
        case .none: data += padded(",")
        case .string: data += padded(",s"); data += padded(value)
        case .integer:
            data += padded(",i"); var bits = Int32(value)!.bigEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        case .float:
            data += padded(",f"); var bits = Float(value)!.bitPattern.bigEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
