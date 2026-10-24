import AVFoundation
import SculptShowCore

/// Decode once, before GO, to a project-rate stereo WAV aligned to video t=0.
enum VideoSoundtrack {
    static func prepare(source: URL, directory: URL, sampleRate: Int) async throws -> URL? {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw VideoPlayback.Failure("Missing video track") }
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let range = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
        guard CMTimeGetSeconds(overlap.duration) > 0 else { return nil }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoPlayback.Failure("Cannot prepare video soundtrack") }
        try track.insertTimeRange(overlap, of: audio, at: CMTimeSubtract(overlap.start, range.start))
        return try await Task.detached(priority: .userInitiated) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 2, interleaved: true)!
            let expected = Int64((CMTimeGetSeconds(range.duration) * Double(sampleRate)).rounded())
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: format.settings)
            guard reader.canAdd(output) else { throw VideoPlayback.Failure("Cannot decode video audio") }
            reader.add(output); reader.timeRange = CMTimeRange(start: .zero, duration: range.duration)
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("Video-audio-\(UUID().uuidString).wav")
            var completed = false
            defer { if !completed { try? fm.removeItem(at: destination) } }
            do {
                let sink = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
                let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384)!
                var written: Int64 = 0
                func pad(to target: Int64) throws {
                    while written < min(expected, target) {
                        try Task.checkCancellation()
                        silence.frameLength = AVAudioFrameCount(min(16384, min(expected, target) - written))
                        memset(silence.mutableAudioBufferList.pointee.mBuffers.mData!, 0, Int(silence.frameLength) * 8)
                        try sink.write(from: silence); written += Int64(silence.frameLength)
                    }
                }
                guard reader.startReading() else { throw reader.error ?? VideoPlayback.Failure("Video audio decoder failed") }
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    guard time.isFinite else { throw VideoPlayback.Failure("Invalid video audio timestamp") }
                    let start = Int64((time * Double(sampleRate)).rounded())
                    try pad(to: max(0, start))
                    let skip = max(0, written - start)
                    let count = min(Int64(CMSampleBufferGetNumSamples(sample)) - skip, expected - written)
                    guard count > 0 else { continue }
                    guard let block = CMSampleBufferGetDataBuffer(sample),
                          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw VideoPlayback.Failure("Invalid decoded audio buffer") }
                    pcm.frameLength = pcm.frameCapacity
                    let status = CMBlockBufferCopyDataBytes(block, atOffset: Int(skip) * 8, dataLength: Int(count) * 8, destination: pcm.mutableAudioBufferList.pointee.mBuffers.mData!)
                    guard status == kCMBlockBufferNoErr else { throw VideoPlayback.Failure("Incomplete video audio decode") }
                    try sink.write(from: pcm); written += count
                }
                guard reader.status == .completed else { throw reader.error ?? VideoPlayback.Failure("Video audio extraction incomplete") }
                try pad(to: expected)
            }
            let verified = try AVAudioFile(forReading: destination)
            guard verified.length == expected, verified.processingFormat.sampleRate == Double(sampleRate) else { throw VideoPlayback.Failure("Video audio verification failed") }
            completed = true; return destination
        }.value
    }
}
