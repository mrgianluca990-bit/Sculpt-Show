import Foundation

/// Deliberately bounded OSC 1.0 control subset: literal methods, immediate bundles.
public enum OSCControlPacket {
    public enum Command: Equatable, Sendable {
        case global(String), cue(UUID, String, Bool?), list(UUID, String), status
    }
    public enum Failure: Error { case malformed, unsupported }
    public static func decode(_ data: Data) throws -> [Command] {
        guard !data.isEmpty, data.count <= 16384, data.count % 4 == 0 else { throw Failure.malformed }
        var result: [Command] = []
        try decode(Array(data), depth: 0, into: &result)
        return result
    }
    private static func decode(_ bytes: [UInt8], depth: Int, into result: inout [Command]) throws {
        guard depth <= 4 else { throw Failure.malformed }
        var cursor = 0
        func word() throws -> UInt32 {
            guard cursor + 4 <= bytes.count else { throw Failure.malformed }
            defer { cursor += 4 }
            return bytes[cursor..<cursor+4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func string() throws -> String {
            let start = cursor
            guard let end = bytes[cursor...].firstIndex(of: 0) else { throw Failure.malformed }
            let padded = (end + 4) & ~3
            guard padded <= bytes.count, bytes[end..<padded].allSatisfy({ $0 == 0 }),
                  bytes[start..<end].allSatisfy({ $0 < 128 }), let text = String(bytes: bytes[start..<end], encoding: .ascii) else { throw Failure.malformed }
            cursor = padded
            return text
        }
        let address = try string()
        if address == "#bundle" {
            let high = try word(), low = try word()
            guard high == 0, low == 1 else { throw Failure.unsupported }
            while cursor < bytes.count {
                let size = Int(try word())
                guard size > 0, size % 4 == 0, size <= bytes.count - cursor else { throw Failure.malformed }
                try decode(Array(bytes[cursor..<cursor+size]), depth: depth + 1, into: &result)
                cursor += size
            }
            return
        }
        guard address.hasPrefix("/sculpt/") else { throw Failure.unsupported }
        let tags = try string()
        let value: Bool?
        switch tags {
        case ",": value = nil
        case ",i": let v = try word(); guard v <= 1 else { throw Failure.unsupported }; value = v == 1
        case ",f": let v = Float(bitPattern: try word()); guard v == 0 || v == 1 else { throw Failure.unsupported }; value = v == 1
        case ",T": value = true
        case ",F": value = false
        default: throw Failure.unsupported
        }
        guard cursor == bytes.count, result.count < 64 else { throw Failure.malformed }
        let parts = address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "sculpt" else { throw Failure.unsupported }
        if parts.count == 3 {
            let action = String(parts[2])
            if action == "status", value == nil { result.append(.status); return }
            guard ["go", "stopAll", "pauseAll", "resumeAll", "fadeAll", "next", "previous", "nextList"].contains(action) else { throw Failure.unsupported }
            if value != false { result.append(.global(action)) }
        } else if parts.count == 5, let id = UUID(uuidString: String(parts[3])) {
            let action = String(parts[4])
            if parts[2] == "cue", ["fire", "stop", "pause", "resume", "fade", "select", "loop"].contains(action) {
                if action == "loop" { guard let value else { throw Failure.unsupported }; result.append(.cue(id, action, value)) }
                else if value != false { result.append(.cue(id, action, nil)) }
            } else if parts[2] == "list", ["play", "stop", "fade"].contains(action) {
                if value != false { result.append(.list(id, action)) }
            } else { throw Failure.unsupported }
        } else { throw Failure.unsupported }
    }
    public static func stringMessage(address: String, value: String) -> Data {
        func padded(_ text: String) -> [UInt8] {
            var b = Array(text.utf8); b.append(0)
            while b.count % 4 != 0 { b.append(0) }; return b
        }
        return Data(padded(address) + padded(",s") + padded(value))
    }
}
