import Foundation
import Darwin
import SculptShowCore

@MainActor enum CueOSCOutput {
    static func send(_ message: CueOSCMessage) -> String? {
        guard let packet = message.packet else { return "Invalid OSC output message" }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "Cannot create OSC output socket" }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return "Cannot configure OSC output socket" }
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(message.port).bigEndian
        guard inet_pton(AF_INET, message.host, &target.sin_addr) == 1 else { return "Invalid OSC IPv4 destination" }
        let count = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        return count == packet.count ? nil : "OSC send failed: \(String(cString: strerror(errno)))"
    }
}

extension ShowStore {
    func sendCueMessages(_ cue: Cue, using midi: MIDIControl) {
        var errors: [String] = []
        for message in cue.triggers.midiMessages ?? [] { if let error = midi.send(message) { errors.append(error) } }
        for message in cue.triggers.oscMessages ?? [] { if let error = CueOSCOutput.send(message) { errors.append(error) } }
        if !errors.isEmpty { errorMessage = "‘\(cue.name)’ output: " + errors.joined(separator: "; ") }
    }
}
