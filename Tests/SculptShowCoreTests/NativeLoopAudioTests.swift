#if canImport(AVFAudio)
import AVFAudio
import XCTest
@testable import SculptShowCore

final class NativeLoopAudioTests: XCTestCase {
    func testWholeWAVReadsAccumulatePartialBlocksAndKeepLastSample() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
            pcm.frameLength = 96000
            let samples = try XCTUnwrap(pcm.floatChannelData)
            for channel in 0..<Int(channels) {
                for frame in 0..<96000 { samples[channel][frame] = Float(frame % 97) / 128 }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            let read = try NativeLoopBuffer.readFrames(file: AVAudioFile(forReading: url), count: 96000)
            XCTAssertEqual(read.frameLength, 96000)
            let result = try XCTUnwrap(read.floatChannelData)
            for channel in 0..<Int(channels) {
                for frame in 0..<96000 { XCTAssertEqual(result[channel][frame], samples[channel][frame]) }
            }
        }
    }

    func testMonoLoopBufferMatchesStereoMatrixVoiceWithoutChangingLevel() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        source.frameLength = 256
        let input = try XCTUnwrap(source.floatChannelData)
        for frame in 0..<256 { input[0][frame] = Float(frame) / 512 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: source)
        }
        let loop = try NativeLoopBuffer.prepare(file: AVAudioFile(forReading: url),
            start: 32.0 / 48000, end: 128.0 / 48000, outputChannels: 2)
        XCTAssertEqual(loop.format.channelCount, 2)
        XCTAssertEqual(loop.frameLength, 96)
        let samples = try XCTUnwrap(loop.floatChannelData)
        for frame in 0..<96 {
            XCTAssertEqual(samples[0][frame], Float(frame + 32) / 512, accuracy: 0.00001)
            XCTAssertEqual(samples[1][frame], 0)
        }
    }

    func testFileSegmentsStillResampleWhenPlayerClockMatchesDevice() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 441))
        source.frameLength = 441
        let input = try XCTUnwrap(source.floatChannelData)
        for channel in 0..<2 { for frame in 0..<441 { input[channel][frame] = 0.25 } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: sourceFormat.settings)
            try file.write(from: source)
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 1024)
        node.scheduleSegment(try AVAudioFile(forReading: url), startingFrame: 0, frameCount: 441,
            at: nil, completionHandler: nil)
        try engine.start()
        defer { engine.stop() }
        node.play()
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024))
        XCTAssertEqual(try engine.renderOffline(1024, to: rendered), .success)
        let output = try XCTUnwrap(rendered.floatChannelData)
        // Ten milliseconds at 44.1 kHz must remain ten milliseconds at 48 kHz.
        XCTAssertEqual((0..<1024).filter { output[0][$0] > 0.1 }.count, 480)
    }

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
