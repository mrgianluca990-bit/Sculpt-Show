#if os(macOS)
import XCTest
import AVFAudio
import AudioToolbox
@testable import SculptShowCore

private final class MonitorRenderSignal { var left: Float = 0.25; var right: Float = 0.5 }
private let monitorRenderInput: AURenderCallback = { context, _, _, _, frames, data in
    guard let data else { return kAudio_ParamError }
    let signal = Unmanaged<MonitorRenderSignal>.fromOpaque(context).takeUnretainedValue()
    for (index, buffer) in UnsafeMutableAudioBufferListPointer(data).enumerated() {
        buffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: index == 0 ? signal.left : signal.right, count: Int(frames))
    }
    return noErr
}

final class MonitorMatrixRenderTests: XCTestCase {
    func testRenderedProgramAndPostFaderMonitorRemainIndependent() async throws {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_MatrixMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let host = try await AVAudioUnit.instantiate(with: desc)
        let unit = host.audioUnit
        defer { AudioUnitUninitialize(unit) }
        var count: UInt32 = 1
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &count, 4), noErr)
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Output, 0, &count, 4), noErr)
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 8))
        let wide = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        var inputFormat = stereo.streamDescription.pointee
        var outputFormat = wide.streamDescription.pointee
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), noErr)
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), noErr)
        let signal = MonitorRenderSignal()
        var callback = AURenderCallbackStruct(inputProc: monitorRenderInput, inputProcRefCon: Unmanaged.passUnretained(signal).toOpaque())
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), noErr)
        XCTAssertEqual(AudioUnitInitialize(unit), noErr)
        func parameter(_ scope: AudioUnitScope, _ element: UInt32, _ value: Float) {
            XCTAssertEqual(AudioUnitSetParameter(unit, kMatrixMixerParam_Volume, scope, element, value, 0), noErr)
        }
        parameter(kAudioUnitScope_Global, 0xFFFFFFFF, 1)
        for output in 0..<8 { parameter(kAudioUnitScope_Output, UInt32(output), 1) }
        let program = try XCTUnwrap(AudioRoutePlan.crosspoints(firstOutput: 2, sourceChannels: 2, deviceChannels: 8))
        var monitor = ShowMonitorSettings(); monitor.enabled = true; monitor.deviceUID = "test"; monitor.leftOutput = 7; monitor.rightOutput = 8; monitor.gain = 0.5
        func patch(pan: Double = 0, send: Bool = true, channels: Int = 2) {
            for input in 0..<2 { for output in 0..<8 { parameter(kAudioUnitScope_Global, UInt32(input << 16 | output), 0) } }
            for point in MonitorMixPlan.gains(channels: channels, program: program, pan: pan, send: send, monitor: monitor) {
                parameter(kAudioUnitScope_Global, UInt32(point.source << 16 | point.output), point.value)
            }
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wide, frameCapacity: 512))
        var clock: Double = 0
        func render() -> [Float] {
            // Apple MatrixMixer smooths parameter changes; inspect the settled signal.
            for _ in 0..<8 {
            buffer.frameLength = 512
            var timestamp = AudioTimeStamp(); timestamp.mFlags = .sampleTimeValid; timestamp.mSampleTime = clock
            var flags = AudioUnitRenderActionFlags(rawValue: 0)
            XCTAssertEqual(AudioUnitRender(unit, &flags, &timestamp, 0, 512, buffer.mutableAudioBufferList), noErr)
            clock += 512
            }
            return (0..<8).map { buffer.floatChannelData![$0][511] }
        }
        // Upstream fader/trim/fade applies before both program and send.
        parameter(kAudioUnitScope_Input, 0, 0.5); parameter(kAudioUnitScope_Input, 1, 0.5)
        patch()
        XCTAssertEqual(render(), [0, 0.125, 0.25, 0, 0, 0, 0.0625, 0.125])
        monitor.muted = true; patch()
        XCTAssertEqual(render(), [0, 0.125, 0.25, 0, 0, 0, 0, 0])
        monitor.muted = false; patch(send: false)
        XCTAssertEqual(render(), [0, 0.125, 0.25, 0, 0, 0, 0, 0])
        patch()
        var controls = OutputMuteSoloState(channelCount: 8)
        controls.setAllMuted(true, excluding: [7, 8])
        for output in 0..<8 { parameter(kAudioUnitScope_Output, UInt32(output), controls.outputGain(output + 1)) }
        XCTAssertEqual(render(), [0, 0, 0, 0, 0, 0, 0.0625, 0.125])
        controls.setAllMuted(true, excluding: [])
        for output in 0..<8 { parameter(kAudioUnitScope_Output, UInt32(output), controls.outputGain(output + 1)) }
        XCTAssertEqual(render(), Array(repeating: Float(0), count: 8))
        controls.clear()
        for output in 0..<8 { parameter(kAudioUnitScope_Output, UInt32(output), controls.outputGain(output + 1)) }
        patch(pan: 1)
        XCTAssertEqual(render(), [0, 0, 0.25, 0, 0, 0, 0, 0.125])
        parameter(kAudioUnitScope_Input, 0, 0); parameter(kAudioUnitScope_Input, 1, 0)
        XCTAssertEqual(render(), Array(repeating: Float(0), count: 8))
    }
}
#endif
