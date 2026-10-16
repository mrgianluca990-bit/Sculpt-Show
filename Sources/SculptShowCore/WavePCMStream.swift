import Foundation

/// Streamed mono/stereo PCM WAV I/O used only for offline normalization.
/// No AVAudioFile/Objective-C file writer; all conversions are explicit.
public enum WavePCMFailure: Error, LocalizedError {
    case unsupported(String)
    case invalid(String)
    case truncated
    case oversized
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported WAV: \(s)"
        case .invalid(let s): return "Invalid WAV: \(s)"
        case .truncated: return "WAV audio data is incomplete or truncated"
        case .oversized: return "Normalized WAV would exceed the RIFF 4 GB limit"
        case .io(let s): return "WAV read/write failed: \(s)"
        }
    }
}

private func readLE16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
}
private func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}
private func appendLE16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}
private func appendLE32(_ value: UInt32, to data: inout Data) {
    for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
}
private func fourCC(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Reads PCM 8/16/24/32-bit integer, 32/64-bit float and extensible PCM WAV.
/// Handles arbitrary 'fmt ' and 'data' chunk ordering and metadata chunks.
public final class WavePCMReader {
    private let handle: FileHandle
    private let dataOffset: UInt64
    private let dataLength: UInt64
    private let sampleEncoding: UInt16
    private let bitDepth: Int
    private let bytesPerFrame: Int
    private var position: UInt64 = 0
    public let channels: Int
    public let sampleRate: Double
    public let frameCount: Int64

    public init(url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        do {
            let header = Array(try fh.read(upToCount: 12) ?? Data())
            guard header.count == 12, header[0..<4].elementsEqual(fourCC("RIFF")),
                  header[8..<12].elementsEqual(fourCC("WAVE")) else {
                throw WavePCMFailure.unsupported("not a little-endian RIFF/WAVE file")
            }
            let fileSize = try fh.seekToEnd()
            var offset: UInt64 = 12
            var format: (UInt16, Int, Double, Int, Int)?
            var audioData: (UInt64, UInt64)?
            while offset + 8 <= fileSize {
                try fh.seek(toOffset: offset)
                let tag = Array(try fh.read(upToCount: 8) ?? Data())
                guard tag.count == 8 else { throw WavePCMFailure.truncated }
                let len = UInt64(readLE32(tag, 4))
                let start = offset + 8
                guard start <= fileSize, len <= fileSize - start else { throw WavePCMFailure.truncated }
                if tag[0..<4].elementsEqual(fourCC("fmt ")) {
                    guard len >= 16 && len <= 65536 else { throw WavePCMFailure.invalid("invalid fmt chunk") }
                    let fmt = Array(try fh.read(upToCount: Int(len)) ?? Data())
                    guard fmt.count == len else { throw WavePCMFailure.truncated }
                    var encoding = readLE16(fmt, 0)
                    let n = Int(readLE16(fmt, 2))
                    let sampleRate = Double(readLE32(fmt, 4))
                    let blockAlign = Int(readLE16(fmt, 12))
                    let bits = Int(readLE16(fmt, 14))
                    if encoding == 0xFFFE { // WAVE_FORMAT_EXTENSIBLE
                        guard fmt.count >= 40 else { throw WavePCMFailure.invalid("short WAVE_FORMAT_EXTENSIBLE") }
                        encoding = readLE16(fmt, 24)
                    }
                    guard (1...2).contains(n), (8000...384000).contains(sampleRate),
                          (encoding == 1 || encoding == 3),
                          (encoding == 1 && [8, 16, 24, 32].contains(bits)) || (encoding == 3 && [32, 64].contains(bits)),
                          blockAlign == n * (bits / 8) else {
                        throw WavePCMFailure.unsupported("requires mono/stereo PCM or IEEE float audio")
                    }
                    format = (encoding, n, sampleRate, bits, blockAlign)
                } else if tag[0..<4].elementsEqual(fourCC("data")) {
                    audioData = (start, len)
                }
                offset = start + len + (len & 1)
            }
            guard let fmt = format, let data = audioData else {
                throw WavePCMFailure.invalid("missing fmt or data chunk")
            }
            guard data.1 % UInt64(fmt.4) == 0 else { throw WavePCMFailure.truncated }
            let length = data.1 / UInt64(fmt.4)
            guard length <= UInt64(Int64.max) else { throw WavePCMFailure.oversized }
            sampleEncoding = fmt.0
            channels = fmt.1
            sampleRate = fmt.2
            bitDepth = fmt.3
            bytesPerFrame = fmt.4
            dataOffset = data.0
            dataLength = data.1
            frameCount = Int64(length)
            handle = fh
        } catch {
            try? fh.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    /// Returns one Float32 array per channel, no clipping, bounded by `maxFrames`.
    public func readFrames(maxFrames: Int = 8192) throws -> [[Float]] {
        guard maxFrames > 0 else { throw WavePCMFailure.invalid("frame request must be positive") }
        let remaining = UInt64(frameCount) - position
        let count = Int(min(remaining, UInt64(maxFrames)))
        if count == 0 { return Array(repeating: [], count: channels) }
        let byteCount = count * bytesPerFrame
        guard byteCount <= 2_097_152 else { throw WavePCMFailure.invalid("chunk exceeds maximum buffer") }
        try handle.seek(toOffset: dataOffset + position * UInt64(bytesPerFrame))
        let d = try handle.read(upToCount: byteCount) ?? Data()
        guard d.count == byteCount else { throw WavePCMFailure.truncated }
        var planar = Array(repeating: [Float](repeating: 0, count: count), count: channels)
        d.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let size = bitDepth / 8
            for f in 0..<count {
                for ch in 0..<channels {
                    let i = f * bytesPerFrame + ch * size
                    let x: Float
                    if sampleEncoding == 3 && bitDepth == 32 {
                        let bits = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                        x = Float(bitPattern: bits)
                    } else if sampleEncoding == 3 {
                        var bits: UInt64 = 0
                        for k in 0..<8 { bits |= UInt64(b[i + k]) << (8 * k) }
                        x = Float(Double(bitPattern: bits))
                    } else if bitDepth == 8 {
                        x = (Float(b[i]) - 128) / 128
                    } else if bitDepth == 16 {
                        let bits = UInt16(b[i]) | UInt16(b[i + 1]) << 8
                        x = Float(Int16(bitPattern: bits)) / 32768
                    } else if bitDepth == 24 {
                        let bits = Int32(b[i]) | Int32(b[i + 1]) << 8 | Int32(b[i + 2]) << 16
                        let signed = (bits << 8) >> 8
                        x = Float(signed) / 8_388_608
                    } else {
                        let bits = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                        x = Float(Int32(bitPattern: bits)) / 2_147_483_648
                    }
                    planar[ch][f] = x.isFinite ? x : 0
                }
            }
        }
        position += UInt64(count)
        return planar
    }
}

/// Standards-compliant little-endian IEEE float WAV writer. Streams 8192-frame
/// chunks; closes the file before verification or relinking. Fails instead of
/// truncating if the output cannot fit in an ordinary RIFF container.
public final class WaveFloat32Writer {
    private let handle: FileHandle
    public let sampleRate: Double
    public let channels: Int
    public private(set) var frameCount: Int64 = 0
    private var finalized = false
    private let factFrameOffset: UInt64 = 46
    private let dataBytesOffset: UInt64 = 54

    public init(url: URL, sampleRate: Double, channels: Int) throws {
        guard (1...2).contains(channels), (8000...384000).contains(sampleRate),
              sampleRate.rounded() == sampleRate else {
            throw WavePCMFailure.unsupported("invalid sample rate or channel count")
        }
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw WavePCMFailure.io("cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate
        self.channels = channels
        // RIFF + WAVE + fmt (WAVEFORMATEX, 18 bytes) + fact (4 bytes) + data.
        var h = Data()
        h.append(contentsOf: fourCC("RIFF")); appendLE32(0, to: &h)
        h.append(contentsOf: fourCC("WAVE"))
        h.append(contentsOf: fourCC("fmt ")); appendLE32(18, to: &h)
        appendLE16(3, to: &h) // WAVE_FORMAT_IEEE_FLOAT
        appendLE16(UInt16(channels), to: &h)
        appendLE32(UInt32(sampleRate), to: &h)
        appendLE32(UInt32(sampleRate) * UInt32(channels) * 4, to: &h)
        appendLE16(UInt16(channels * 4), to: &h)
        appendLE16(32, to: &h)
        appendLE16(0, to: &h) // WAVEFORMATEX cbSize
        h.append(contentsOf: fourCC("fact")); appendLE32(4, to: &h)
        appendLE32(0, to: &h) // decoded frames, patched on finalize
        h.append(contentsOf: fourCC("data")); appendLE32(0, to: &h)
        assert(h.count == 58)
        try handle.write(contentsOf: h)
    }

    deinit { try? handle.close() }

    public func append(planar: [[Float]], gain: Float, peakCeiling: Float? = nil) throws {
        guard !finalized else { throw WavePCMFailure.invalid("writer already closed") }
        guard planar.count == channels, let n = planar.first?.count,
              planar.allSatisfy({ $0.count == n }), n <= 262_144 else {
            throw WavePCMFailure.invalid("invalid channel buffers")
        }
        let after = frameCount + Int64(n)
        guard after <= Int64((UInt32.max - 50) / UInt32(channels * 4)) else {
            throw WavePCMFailure.oversized
        }
        var bytes = Data(count: n * channels * 4)
        bytes.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for f in 0..<n {
                for ch in 0..<channels {
                    let s = planar[ch][f] * gain
                    let value: Float
                    if !s.isFinite { value = 0 }
                    else if let cap = peakCeiling { value = min(max(s, -cap), cap) }
                    else { value = s }
                    let bits = value.bitPattern
                    let i = (f * channels + ch) * 4
                    b[i] = UInt8(truncatingIfNeeded: bits)
                    b[i + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                    b[i + 2] = UInt8(truncatingIfNeeded: bits >> 16)
                    b[i + 3] = UInt8(truncatingIfNeeded: bits >> 24)
                }
            }
        }
        try handle.write(contentsOf: bytes)
        frameCount = after
    }

    public func finalize() throws {
        guard !finalized else { return }
        let audioBytes = UInt32(frameCount) * UInt32(channels * 4)
        try handle.seek(toOffset: 4)
        var riffSize = Data(); appendLE32(50 + audioBytes, to: &riffSize)
        try handle.write(contentsOf: riffSize)
        try handle.seek(toOffset: factFrameOffset)
        var fact = Data(); appendLE32(UInt32(frameCount), to: &fact)
        try handle.write(contentsOf: fact)
        try handle.seek(toOffset: dataBytesOffset)
        var size = Data(); appendLE32(audioBytes, to: &size)
        try handle.write(contentsOf: size)
        try handle.close()
        finalized = true
    }
}
