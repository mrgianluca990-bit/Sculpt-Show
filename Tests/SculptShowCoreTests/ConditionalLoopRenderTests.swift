import XCTest
import SculptLTCCore

final class ConditionalLoopRenderTests: XCTestCase {
    func testWholeCueLoopTogglePreservesSamplesAndSharedBoundary() throws {
        let own = try XCTUnwrap(sculpt_signal_create())
        defer { sculpt_signal_destroy(own) }
        let transport = try XCTUnwrap(sculpt_loop_create(48000, 0, 8, 8, nil, 1, own))
        defer { sculpt_loop_destroy(transport) }
        let source: [Float] = [1,2,3,4,5,6,7,8]
        source.withUnsafeBufferPointer { pcm in
            for voice in 0..<7 { XCTAssertTrue(sculpt_loop_voice(transport, UInt32(voice), pcm.baseAddress, nil, 8)) }
            sculpt_loop_arm(transport, 0, 0)
            sculpt_loop_set_repeat(transport, false)
            var left = [Float](repeating: 0, count: 4), right = left
            for voice in 0..<7 {
                sculpt_loop_render_frames(transport, UInt32(voice), 0, 4, &left, &right)
                XCTAssertEqual(left, [1,2,3,4])
            }
            sculpt_loop_set_repeat(transport, true)
            sculpt_loop_set_repeat(transport, false)
            sculpt_loop_set_repeat(transport, true)
            for voice in 0..<7 {
                sculpt_loop_render_frames(transport, UInt32(voice), 4, 4, &left, &right)
                XCTAssertEqual(left, [5,6,7,8])
            }
            for voice in 0..<7 {
                // First voice owns the decision; toggling between voices cannot split stems.
                if voice == 1 { sculpt_loop_set_repeat(transport, false) }
                sculpt_loop_render_frames(transport, UInt32(voice), 8, 4, &left, &right)
                XCTAssertEqual(left, [1,2,3,4])
            }
            for voice in 0..<7 {
                sculpt_loop_render_frames(transport, UInt32(voice), 12, 4, &left, &right)
                XCTAssertEqual(left, [5,6,7,8])
                sculpt_loop_render_frames(transport, UInt32(voice), 16, 4, &left, &right)
                XCTAssertEqual(left, [0,0,0,0])
            }
            XCTAssertEqual(sculpt_loop_boundary_count(transport), 2)
        }
    }

    func testSevenStemsRepeatAndExitAtExactBoundaryWithSharedDecision() throws {
        let condition = try XCTUnwrap(sculpt_signal_create())
        let own = try XCTUnwrap(sculpt_signal_create())
        defer { sculpt_signal_destroy(condition); sculpt_signal_destroy(own) }
        let transport = try XCTUnwrap(sculpt_loop_create(48000, 2, 6, 10, condition, 1, own))
        defer { sculpt_loop_destroy(transport) }
        let sources = (0..<7).map { voice -> UnsafeMutablePointer<Float> in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 10)
            for frame in 0..<10 { samples[frame] = Float(voice * 100 + frame + 1) }
            return samples
        }
        defer { for samples in sources { samples.deallocate() } }
        for voice in 0..<7 { XCTAssertTrue(sculpt_loop_voice(transport, UInt32(voice), sources[voice], nil, 10)) }
        sculpt_signal_set(condition, 1, 0, UInt64.max)
        sculpt_loop_arm(transport, 0, 0)
        XCTAssertEqual(sculpt_loop_boundary_count(transport), 0)
        var left = [Float](repeating: 0, count: 10)
        var right = left
        // First voice decides to repeat. A concurrent condition change must not
        // put later stems on a different side of that same sample boundary.
        for voice in 0..<7 {
            if voice == 1 { sculpt_signal_phase(condition, 0) }
            sculpt_loop_render_frames(transport, UInt32(voice), 0, 10, &left, &right)
            let expected = [0, 1, 2, 3, 4, 5, 2, 3, 4, 5].map { Float(voice * 100 + $0 + 1) }
            XCTAssertEqual(sculpt_loop_boundary_count(transport), 1)
            XCTAssertEqual(left, expected)
            XCTAssertEqual(right, [Float](repeating: 0, count: 10))
        }
        // At the next OUT, false means continue from OUT through the tail,
        // never a timer, seek, inserted gap, or repeated boundary sample.
        for voice in (0..<7).reversed() {
            sculpt_loop_render_frames(transport, UInt32(voice), 10, 6, &left, &right)
            XCTAssertEqual(sculpt_loop_boundary_count(transport), 2)
            XCTAssertEqual(Array(left.prefix(6)), [6, 7, 8, 9].map { Float(voice * 100 + $0 + 1) } + [0, 0])
        }
    }
    func testConditionUsesOtherCuesScheduledEndInsideRenderBlock() throws {
        let condition = try XCTUnwrap(sculpt_signal_create())
        defer { sculpt_signal_destroy(condition) }
        // The other cue ends exactly at the first OUT; Playing must be false
        // there even if the UI has not refreshed its snapshot yet.
        sculpt_signal_set(condition, 1, 0, 125_000)
        let transport = try XCTUnwrap(sculpt_loop_create(48000, 2, 6, 10, condition, 1, nil))
        defer { sculpt_loop_destroy(transport) }
        let source = (0..<10).map { Float($0 + 1) }
        var left = [Float](repeating: 0, count: 10)
        var right = left
        source.withUnsafeBufferPointer { pcm in
            XCTAssertTrue(sculpt_loop_voice(transport, 0, pcm.baseAddress, nil, 10))
            sculpt_loop_arm(transport, 0, 0)
            sculpt_loop_render_frames(transport, 0, 0, 10, &left, &right)
        }
        XCTAssertEqual(left, source)
    }
    func testStoppedPausedWaitingAndMissingConditionStates() throws {
        for phase: Int32 in [0, 2, 3] {
            let condition = try XCTUnwrap(sculpt_signal_create())
            defer { sculpt_signal_destroy(condition) }
            sculpt_signal_set(condition, phase, 0, UInt64.max)
            let transport = try XCTUnwrap(sculpt_loop_create(48000, 2, 6, 10, condition, phase, nil))
            defer { sculpt_loop_destroy(transport) }
            let source = (0..<10).map { Float($0 + 1) }
            var left = [Float](repeating: 0, count: 10)
            var right = left
            source.withUnsafeBufferPointer { pcm in
                XCTAssertTrue(sculpt_loop_voice(transport, 0, pcm.baseAddress, nil, 10))
                sculpt_loop_arm(transport, 0, 0)
                sculpt_loop_render_frames(transport, 0, 0, 10, &left, &right)
            }
            XCTAssertEqual(left, [1,2,3,4,5,6,3,4,5,6])
            // A deleted/nonexistent cue never satisfies Stopped.
            sculpt_signal_exists(condition, false)
            source.withUnsafeBufferPointer { pcm in
                XCTAssertTrue(sculpt_loop_voice(transport, 0, pcm.baseAddress, nil, 10))
                sculpt_loop_arm(transport, 0, 0)
                sculpt_loop_render_frames(transport, 0, 0, 10, &left, &right)
            }
            XCTAssertEqual(left, source)
        }
    }
}
