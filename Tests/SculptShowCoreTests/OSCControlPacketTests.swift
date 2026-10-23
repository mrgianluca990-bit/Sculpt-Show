import XCTest
@testable import SculptShowCore

final class OSCControlPacketTests: XCTestCase {
    private func string(_ s: String) -> Data {
        var data = Data(s.utf8); data.append(0); while data.count % 4 != 0 { data.append(0) }; return data
    }
    private func message(_ address: String, tags: String = ",", word: UInt32? = nil) -> Data {
        var data = string(address) + string(tags)
        if let word { data += Data([UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]) }
        return data
    }
    private func bundle(_ packets: [Data], immediate: Bool = true) -> Data {
        var data = string("#bundle") + Data([0,0,0,0,0,0,0,immediate ? 1 : 2])
        for packet in packets { let n = UInt32(packet.count); data += Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]); data += packet }
        return data
    }
    func testTransportButtonsIgnoreReleaseAndValidateArguments() throws {
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/go")), [.global("go")])
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/go", tags: ",f", word: Float(1).bitPattern)), [.global("go")])
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/go", tags: ",i", word: 0)), [])
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/stopAll", tags: ",T")), [.global("stopAll")])
        XCTAssertThrowsError(try OSCControlPacket.decode(message("/sculpt/go", tags: ",i", word: 2)))
    }
    func testStableCueListIDsAndExplicitLoopState() throws {
        let id = UUID()
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/cue/\(id)/fire")), [.cue(id, "fire", nil)])
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/cue/\(id)/loop", tags: ",i", word: 0)), [.cue(id, "loop", false)])
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/list/\(id)/play")), [.list(id, "play")])
        XCTAssertThrowsError(try OSCControlPacket.decode(message("/sculpt/cue/\(id)/loop")))
        XCTAssertThrowsError(try OSCControlPacket.decode(message("/sculpt/cue/1/fire")))
    }
    func testImmediateBundlesPreserveOrderAndRejectWholeMalformedPacket() throws {
        let packet = bundle([message("/sculpt/stopAll"), bundle([message("/sculpt/go")])])
        XCTAssertEqual(try OSCControlPacket.decode(packet), [.global("stopAll"), .global("go")])
        XCTAssertThrowsError(try OSCControlPacket.decode(bundle([message("/sculpt/go"), message("/unknown")])))
        XCTAssertThrowsError(try OSCControlPacket.decode(bundle([message("/sculpt/go")], immediate: false)))
        XCTAssertThrowsError(try OSCControlPacket.decode(bundle(Array(repeating: message("/sculpt/go"), count: 65))))
    }
    func testTruncationPaddingPatternsAndDepthAreRejected() throws {
        let valid = message("/sculpt/go")
        for length in 0..<valid.count { XCTAssertThrowsError(try OSCControlPacket.decode(Data(valid.prefix(length)))) }
        XCTAssertThrowsError(try OSCControlPacket.decode(message("/sculpt/*")))
        XCTAssertThrowsError(try OSCControlPacket.decode(valid + Data([0,0,0,0])))
        var nested = valid
        for _ in 0..<6 { nested = bundle([nested]) }
        XCTAssertThrowsError(try OSCControlPacket.decode(nested))
        XCTAssertThrowsError(try OSCControlPacket.decode(Data(repeating: 0, count: 16388)))
    }
    func testStatusAndStringReplyPadding() throws {
        XCTAssertEqual(try OSCControlPacket.decode(message("/sculpt/status")), [.status])
        XCTAssertEqual(OSCControlPacket.stringMessage(address: "/sculpt/status", value: "{}"), string("/sculpt/status") + string(",s") + string("{}"))
    }
}
