#if canImport(AVFAudio)
import AVFAudio
import XCTest
@testable import SculptShowCore

final class NativeLoopAudioTests: XCTestCase {
    func testLoopKeepsSampleOrderWhileAnotherCuePlaysWithoutUICallbacks() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        source.frameLength = 1024
        let samples = try XCTUnwrap(source.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<1024 { samples[channel][frame] = Float(frame + 1) / 8192 }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: source)
        }
        let file = try AVAudioFile(forReading: url)
        let loop = try NativeLoopBuffer.prepare(file: file, start: 32.0 / 48000, end: 128.0 / 48000)
        XCTAssertEqual(loop.frameLength, 96)
        let engine = AVAudioEngine()
        let looping = AVAudioPlayerNode()
        let other = AVAudioPlayerNode()
        engine.attach(looping)
        engine.attach(other)
        engine.connect(looping, to: engine.mainMixerNode, format: format)
        engine.connect(other, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 64)
        looping.scheduleSegment(file, startingFrame: 0, frameCount: 128, at: nil, completionHandler: nil)
        looping.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
        let bed = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        bed.frameLength = 64
        let bedSamples = try XCTUnwrap(bed.floatChannelData)
        for channel in 0..<2 { for frame in 0..<64 { bedSamples[channel][frame] = 0.125 } }
        other.scheduleBuffer(bed, at: nil, options: .loops, completionHandler: nil)
        try engine.start()
        defer { engine.stop() }
        looping.play()
        other.play()
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        for block in 0..<64 {
            XCTAssertEqual(try engine.renderOffline(64, to: rendered), .success)
            let data = try XCTUnwrap(rendered.floatChannelData)
            for channel in 0..<2 {
                for index in 0..<64 {
                    let frame = block * 64 + index
                    let sourceFrame = frame < 128 ? frame : 32 + (frame - 128) % 96
                    XCTAssertEqual(data[channel][index], Float(sourceFrame + 1) / 8192 + 0.125,
                        accuracy: 0.00001, "Audio mismatch at frame \(frame), channel \(channel)")
                }
            }
        }
    }
}
#endif
