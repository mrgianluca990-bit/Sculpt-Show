#if canImport(AVFAudio)
import AVFAudio
import XCTest
@testable import SculptShowCore

final class SessionAudioPreparationTests: XCTestCase {
    private func fixture(_ url: URL, rate: Double, channels: AVAudioChannelCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
        pcm.frameLength = pcm.frameCapacity
        let samples = try XCTUnwrap(pcm.floatChannelData)
        for c in 0..<Int(channels) {
            for f in 0..<Int(pcm.frameLength) { samples[c][f] = Float(sin(Double(f) * 2 * .pi * 440 / rate)) * 0.1 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
    }
    func testOfflineConversionPreservesOriginalDurationAndChannels() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for rate in [44100.0, 88200, 96000] {
            for channels: AVAudioChannelCount in [1, 2] {
                let source = dir.appendingPathComponent("source-\(rate)-\(channels).wav")
                let destination = dir.appendingPathComponent("converted-\(rate)-\(channels).wav")
                try fixture(source, rate: rate, channels: channels)
                let original = try Data(contentsOf: source)
                try SessionAudioPreparation.convert(source: source, destination: destination, sampleRate: 48000)
                let file = try AVAudioFile(forReading: destination)
                XCTAssertEqual(file.processingFormat.sampleRate, 48000)
                XCTAssertEqual(file.processingFormat.channelCount, channels)
                XCTAssertEqual(file.length, 4800)
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }
    func testAllSevenStemsArePreparedAndNextRateChangeUsesOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var cue = Cue(name: "Seven")
        for i in 0..<7 {
            let source = dir.appendingPathComponent("stem-\(i).wav")
            try fixture(source, rate: i % 2 == 0 ? 44100 : 88200, channels: 1)
            cue.elements.append(.audio(source))
        }
        let root = dir.appendingPathComponent("project")
        let original = Show(cueLists: [CueList(name: "List", cues: [cue])])
        let first = try SessionAudioPreparation.preparing(original, projectRoot: root)
        for stem in first.cueLists[0].cues[0].audioElements {
            XCTAssertEqual(try AVAudioFile(forReading: URL(fileURLWithPath: stem.sourcePath)).processingFormat.sampleRate, 48000)
            XCTAssertNotNil(stem.originalSourcePath)
        }
        var next = first
        next.sampleRate = 96000
        let second = try SessionAudioPreparation.preparing(next, projectRoot: root)
        XCTAssertEqual(second.cueLists[0].cues[0].audioElements.map(\.originalSourcePath), first.cueLists[0].cues[0].audioElements.map(\.originalSourcePath))
        for stem in second.cueLists[0].cues[0].audioElements {
            XCTAssertEqual(try AVAudioFile(forReading: URL(fileURLWithPath: stem.sourcePath)).length, 9600)
        }
        let saved = try ShowProjectPackage.create(second, requestedDocumentURL: dir.appendingPathComponent("Portable.scshow"))
        let document = try ShowCodec.decode(contentsOf: saved.documentURL)
        XCTAssertEqual(document.sampleRate, 96000)
        for stem in document.cueLists[0].cues[0].audioElements {
            XCTAssertFalse(try XCTUnwrap(stem.originalSourcePath).hasPrefix("/"))
        }
        let reopened = try ShowProjectPackage.resolve(document, documentURL: saved.documentURL)
        for stem in reopened.cueLists[0].cues[0].audioElements {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stem.originalSourcePath)))
        }
    }
    func testFailedBatchDoesNotReplaceAnyModelReferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("valid.wav")
        try fixture(source, rate: 44100, channels: 1)
        var cue = Cue(name: "Batch", mediaPath: source.path)
        cue.elements.append(.audio(dir.appendingPathComponent("missing.wav")))
        let show = Show(cueLists: [CueList(name: "List", cues: [cue])])
        XCTAssertThrowsError(try SessionAudioPreparation.preparing(show, projectRoot: dir.appendingPathComponent("project")))
        XCTAssertEqual(show.cueLists[0].cues[0].mediaPath, source.path)
        XCTAssertNil(show.cueLists[0].cues[0].audioElements[0].originalSourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testLegacyProjectsDefaultTo48kAndInvalidRatesAreRejected() throws {
        let bytes = try ShowCodec.encode(Show())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json.removeValue(forKey: "sampleRate")
        XCTAssertEqual(try ShowCodec.decode(JSONSerialization.data(withJSONObject: json)).sampleRate, 48000)
        json["sampleRate"] = 0
        XCTAssertThrowsError(try ShowCodec.decode(JSONSerialization.data(withJSONObject: json)))
    }
}
#endif
