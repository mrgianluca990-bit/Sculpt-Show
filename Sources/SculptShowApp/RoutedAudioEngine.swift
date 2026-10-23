import Foundation
@preconcurrency import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate
import SculptShowCore
import SculptLTCCore

/// Optional multi-output engine. The proven AVAudioPlayer backend remains the
/// default until the user explicitly enables routing from the panel.
/// Up to 64 stereo input buses -> a physical output device with up to 64 channels.
/// A single host timestamp starts all AVAudioPlayerNodes for a multitrack cue.
@MainActor
final class RoutedAudioEngine {
    struct OutputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let channels: Int
        let uid: String
    }

    enum RoutingError: LocalizedError {
        case deviceNotFound
        case noDeviceOutput
        case cannotConfigure(String, OSStatus)
        case unsupportedSource(String, Int)
        case noVoices(Int)
        case invalidChannel(String, Int)
        case engineNotReady
        case ltcConflict(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: return "The selected output device is no longer connected. Refresh the device list."
            case .noDeviceOutput: return "The output device has no usable audio channels."
            case .cannotConfigure(let operation, let code): return "Core Audio routing failed (\(operation), OSStatus \(code))."
            case .unsupportedSource(let name, let count): return "\(name) has \(count) channels. Routed playback currently accepts mono/stereo WAV/AIFF stems only."
            case .noVoices(let count): return "This show requires \(count) voices. The routed engine supports up to 64 simultaneous mono/stereo files, subject to hardware."
            case .invalidChannel(let name, let index): return "Invalid output \(index) for ‘\(name)’ on the selected device."
            case .engineNotReady: return "Routing engine not initialized. Open Audio/MIDI Setup and select the output."
            case .ltcConflict(let text): return text
            }
        }
    }

    private struct Voice {
        let node: AVAudioPlayerNode
        let gainNode: AVAudioMixerNode
        let loopSource: AVAudioSourceNode
        let loopSlot: LoopVoiceSlot
        var owner: UUID?
        var elementID: UUID?
        var file: AVAudioFile?
        var fileChannels = 2
        var mix: CueElement?
        var matrixGains: [MonitorMixPlan.Gain] = []
        var firstOutput = 1
    }

    static let maximumVoices = 64
    private var activeVoiceLimit = 64
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    var onSampleRateInvalidated: ((Double) -> Void)?
    private func hardwareSampleRate() -> Double {
        guard let device = selectedDevice else { return 0 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
    private var matrix: AVAudioUnit?
    private var voices: [Voice] = []
    /// Cache open AVAudioFile descriptors by stem identity to avoid 64 file
    /// opens on every marker seek (and to preserve native resampling metadata).
    private var fileCache: [UUID: (path: String, modified: Date?, size: UInt64, file: AVAudioFile)] = [:]

    private func preparedFile(for stem: CueElement) throws -> AVAudioFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: stem.sourcePath)
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let entry = fileCache[stem.id], entry.path == stem.sourcePath,
           entry.modified == modified, entry.size == size,
           abs(entry.file.processingFormat.sampleRate - sampleRate) < 0.5 { return entry.file }
        // Keep prepared descriptors bounded. Active voices retain their own files,
        // so evicting an idle cache entry never interrupts playback or loop queues.
        if fileCache.count >= Self.maximumVoices {
            let activeElements = Set(voices.compactMap { $0.elementID })
            fileCache = fileCache.filter { activeElements.contains($0.key) }
        }
        let opened = try AVAudioFile(forReading: URL(fileURLWithPath: stem.sourcePath))
        guard abs(opened.processingFormat.sampleRate - sampleRate) < 0.5 else {
            throw SessionAudioPreparation.Failure.invalid("Prepare project audio before GO: \(stem.name) has a different sample rate. Live SRC is disabled.")
        }
        fileCache[stem.id] = (stem.sourcePath, modified, size, opened)
        return opened
    }
    var outputPatch = ShowOutputPatch()
    var monitor = ShowMonitorSettings()
    var soloedInputs: Set<UUID> = []
    private(set) var selectedDevice: OutputDevice?
    private var cueToVoices: [UUID: [Int]] = [:]

    private struct ActiveMarkerLoop {
        let plan: NativeMarkerLoop
        let token: UUID
        let buffers: [AVAudioPCMBuffer]
    }
    private var activeMarkerLoops: [UUID: ActiveMarkerLoop] = [:]
    private var conditionalLoops: [UUID: ConditionalLoopRealtime] = [:]
    private var retiredLoops: [ConditionalLoopRealtime] = []
    var preparedConditionalFiles: [String: PreparedConditionalPCM] = [:]
    private var signals: [UUID: CueRealtimeSignal] = [:]
    private var knownCueIDs: Set<UUID> = []
    var actualSampleRate: Double { sampleRate }

    func setKnownCueIDs(_ ids: Set<UUID>) {
        knownCueIDs = ids
        for (id, signal) in signals { sculpt_signal_exists(signal.pointer, ids.contains(id)) }
    }
    private func signal(for id: UUID) throws -> CueRealtimeSignal {
        if let existing = signals[id] { return existing }
        let created = try CueRealtimeSignal()
        sculpt_signal_exists(created.pointer, knownCueIDs.contains(id))
        signals[id] = created
        return created
    }
    func conditionPhases(_ phases: [UUID: Int32]) {
        for id in knownCueIDs {
            if let signal = try? signal(for: id) { sculpt_signal_phase(signal.pointer, phases[id] ?? 0) }
        }
        retiredLoops.removeAll { $0.quiescent }
    }
    func setSilentCueTimeline(_ id: UUID, duration: Double, loops: Bool) {
        guard let signal = try? signal(for: id) else { return }
        let start = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let end = loops ? UInt64.max : start + UInt64(max(0, duration) * 1e9)
        sculpt_signal_set(signal.pointer, 1, start, end)
    }
    func extendCueTimeline(_ id: UUID, duration: Double) {
        guard let signal = signals[id] else { return }
        sculpt_signal_end(signal.pointer,
            AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) + UInt64(max(0, duration) * 1e9))
    }
    func failedConditionalCue() -> UUID? {
        conditionalLoops.first(where: { sculpt_loop_failure($0.value.pointer) != 0 })?.key
    }

    func conditionalPosition(for id: UUID) -> Double? {
        guard let loop = conditionalLoops[id] else { return nil }
        return sculpt_loop_position_at(loop.pointer, AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
    }


    func nativeLoop(for cueID: UUID) -> NativeMarkerLoop? { activeMarkerLoops[cueID]?.plan }

    func nativeLoopProgress(for id: UUID, linear: Double) -> (token: UUID, count: UInt64)? {
        guard let state = activeMarkerLoops[id], state.plan.triggerMarkerID != nil else { return nil }
        if let loop = conditionalLoops[id] {
            return (state.token, sculpt_loop_boundary_count(loop.pointer))
        }
        let length = state.plan.outSeconds - state.plan.inSeconds
        let count = linear < state.plan.outSeconds ? 0 : floor((linear - state.plan.outSeconds) / length) + 1
        return (state.token, UInt64(max(0, count)))
    }

    /// The callback is fired AFTER playback of one queued segment, leaving
    /// three segments already queued. It never restarts a node or its routing.
    private func appendLoopSegment(cueID: UUID, voice: Int, token: UUID) {
        guard let state = activeMarkerLoops[cueID], state.token == token,
              voices.indices.contains(voice), voices[voice].owner == cueID,
              let file = voices[voice].file else { return }
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition((state.plan.inSeconds * rate).rounded())
        let end = AVAudioFramePosition((state.plan.outSeconds * rate).rounded())
        guard end > start, end <= file.length,
              end - start <= Int64(UInt32.max) else { return }
        voices[voice].node.scheduleSegment(file, startingFrame: start,
            frameCount: AVAudioFrameCount(end - start), at: nil,
            completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appendLoopSegment(cueID: cueID, voice: voice, token: token)
            }
        }
    }
    /// Exactly one SMPTE LTC transport can own the dedicated matrix input.
    private var ltcSource: AVAudioSourceNode?
    private var ltcRealtime: LTCRealtimeState?
    private(set) var ltcOwner: UUID?
    private(set) var ltcElement: CueElement?
    private var ltcOutput: Int?
    private var sampleRate: Double = 48000
    private var ltcInputIndex: Int { activeVoiceLimit }

    // Test tone reuses one FREE voice only when the transport is idle.
    // No extra mixer bus, AVAudioEngine node or graph rebuild is needed.
    private var testBuffer: AVAudioPCMBuffer?
    private(set) var testToneOutput: Int?
    private var testToneVoice: Int?

    /// Called on the main queue with actual PCM values tapped after the matrix.
    var onMeterSample: (([Float], [Float]) -> Void)?

    static func defaultOutputID() -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &id) == noErr, id != 0 else { return nil }
        return id
    }

    var isReady: Bool {
        engine?.isRunning == true && selectedDevice != nil && abs(hardwareSampleRate() - sampleRate) < 0.5
    }

    /// Enumerate actual Core Audio output devices (not MIDI ports or input-only devices).
    static func availableOutputs() -> [OutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr,
                  bytes >= UInt32(MemoryLayout<AudioBufferList>.size) else { return nil }
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { ptr.deallocate() }
            guard AudioObjectGetPropertyData(device, &streams, 0, nil, &bytes, ptr) == noErr else { return nil }
            let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
            let channels = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name)
            let label: String
            if status == noErr, let result = name {
                label = result.takeRetainedValue() as String
            } else {
                label = "Audio Device"
            }
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidValue: Unmanaged<CFString>?
            var uidBytes = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidBytes, &uidValue)
            let uid: String
            if uidStatus == noErr, let uidValue { uid = uidValue.takeRetainedValue() as String }
            else { uid = "" }
            return OutputDevice(id: device, name: label, channels: channels, uid: uid)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Changing hardware graph while audio is running is intentionally disallowed.
    func configure(device: OutputDevice, requestedRate: Int) async throws {
        guard cueToVoices.isEmpty else { throw RoutingError.cannotConfigure("active cues", -1) }
        teardown()
        guard device.channels > 0, device.channels <= 64 else { throw RoutingError.noDeviceOutput }
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var hardwareRate = Double(requestedRate)
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var actualRate: Double = 0
        let gotRate = AudioObjectGetPropertyData(device.id, &rateAddress, 0, nil, &rateSize, &actualRate)
        if gotRate != noErr || abs(actualRate - hardwareRate) > 0.5 {
            let status = AudioObjectSetPropertyData(device.id, &rateAddress, 0, nil, rateSize, &hardwareRate)
            guard status == noErr else { throw RoutingError.cannotConfigure("device does not accept project sample rate", status) }
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 50_000_000)
                rateSize = UInt32(MemoryLayout<Double>.size)
                _ = AudioObjectGetPropertyData(device.id, &rateAddress, 0, nil, &rateSize, &actualRate)
                if abs(actualRate - hardwareRate) < 0.5 { break }
            }
        }
        guard abs(actualRate - hardwareRate) < 0.5 else {
            throw SessionAudioPreparation.Failure.invalid("Device sample rate does not match the project. Live SRC is disabled.")
        }
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_MatrixMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let mixerUnit = try await AVAudioUnit.instantiate(with: desc)
        let graph = AVAudioEngine()
        guard let outputUnit = graph.outputNode.audioUnit else { throw RoutingError.engineNotReady }
        var deviceID = device.id
        var status = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw RoutingError.cannotConfigure("select device", status) }

        // Some host AU implementations reject very wide MatrixMixer input
        // configurations. Negotiate capacity without breaking working setups.
        var inputCount: UInt32 = 0
        var outputBusCount: UInt32 = 1
        for voices in [64, 32, 16] {
            inputCount = UInt32(voices + 1) // reserve a bus for LTC
            status = AudioUnitSetProperty(mixerUnit.audioUnit, kAudioUnitProperty_ElementCount,
                kAudioUnitScope_Input, 0, &inputCount, UInt32(MemoryLayout<UInt32>.size))
            if status == noErr {
                activeVoiceLimit = voices
                break
            }
        }
        guard status == noErr else { throw RoutingError.cannotConfigure("matrix inputs", status) }
        status = AudioUnitSetProperty(mixerUnit.audioUnit, kAudioUnitProperty_ElementCount,
            kAudioUnitScope_Output, 0, &outputBusCount, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw RoutingError.cannotConfigure("matrix output", status) }
        graph.attach(mixerUnit)
        let current = graph.outputNode.outputFormat(forBus: 0)
        let rate = current.sampleRate
        guard abs(rate - Double(requestedRate)) < 0.5 else {
            throw SessionAudioPreparation.Failure.invalid("Core Audio output format differs from the project sample rate")
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | UInt32(device.channels)),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw RoutingError.noDeviceOutput
        }
        // This AVAudioFormat initializer is non-optional on macOS; it must not
        // participate in a `guard let` optional-binding clause.
        let multichannel = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         interleaved: false,
                                         channelLayout: layout)
        graph.connect(mixerUnit, to: graph.outputNode, format: multichannel)
        var newVoices: [Voice] = []
        for index in 0..<activeVoiceLimit {
            let player = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            graph.attach(player)
            graph.attach(gain)
            // A nil format leaves player nodes at their 44.1 kHz default even
            // on a 48 kHz device. Pin the player clock to the matrix clock.
            graph.connect(player, to: gain, fromBus: 0, toBus: 0, format: stereo)
            let slot = try LoopVoiceSlot(index: index)
            let loopSource = AVAudioSourceNode(format: stereo) { _, timestamp, frames, data in
                slot.render(timestamp: timestamp, frames: frames, data: data)
                return noErr
            }
            graph.attach(loopSource)
            graph.connect(loopSource, to: gain, fromBus: 0, toBus: 1, format: stereo)
            graph.connect(gain, to: mixerUnit, fromBus: 0, toBus: index, format: stereo)
            gain.outputVolume = 0
            newVoices.append(Voice(node: player, gainNode: gain, loopSource: loopSource, loopSlot: slot))
        }
        guard let realtime = LTCRealtimeState() else { throw RoutingError.engineNotReady }
        let ltcNode = AVAudioSourceNode(format: stereo) { isSilence, timestamp, frameCount, data in
            isSilence.pointee = ObjCBool(false)
            realtime.render(timestamp: timestamp, frameCount: frameCount,
                            outputData: data, sampleRate: Float(rate))
            return noErr
        }
        graph.attach(ltcNode)
        graph.connect(ltcNode, to: mixerUnit, fromBus: 0,
                      toBus: ltcInputIndex, format: stereo)
        sampleRate = rate
        ltcSource = ltcNode
        ltcRealtime = realtime
        let frameCount = AVAudioFrameCount(max(1024, Int(rate / 2)))
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let tone = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frameCount),
              let samples = tone.floatChannelData else { throw RoutingError.noDeviceOutput }
        tone.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            // −30 dBFS peak, 440 Hz. The right input is silent for mono output.
            samples[0][i] = 0.03162278 * Float(sin(Double(i) * 2 * Double.pi * 440 / rate))
            samples[1][i] = 0
        }
        graph.prepare()
        try graph.start()
        let au = mixerUnit.audioUnit
        // The matrix defaults to silence. Configure input/output/master volumes;
        // *crosspoints stay zero* until a cue is assigned to the appropriate bus.
        try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Global, 0xFFFFFFFF, 1, 0), "master")
        for index in 0..<(activeVoiceLimit + 1) * 2 {
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Input, UInt32(index), 1, 0), "input channel")
        }
        for channel in 0..<device.channels {
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Output, UInt32(channel), 1, 0), "output channel")
        }
        // Explicit all-zero crosspoints ensures disconnected tracks cannot leak.
        for input in 0..<((activeVoiceLimit + 1) * 2) {
            for output in 0..<device.channels {
                try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                   kAudioUnitScope_Global, (UInt32(input) << 16) | UInt32(output), 0, 0), "clear matrix")
            }
        }
        // Real peak/RMS of each physical output, after per-stem matrix routing
        // and output-scope mute/solo. No fake signal-presence meters.
        // Use a 2048-frame tap to keep SwiftUI updates around 20–25 Hz.
        let meterSink = onMeterSample
        mixerUnit.installTap(onBus: 0, bufferSize: 2048, format: multichannel) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let count = min(Int(buffer.format.channelCount), device.channels)
            let frames = Int(buffer.frameLength)
            guard count > 0 else { return }
            var peaks = [Float](repeating: 0, count: count)
            var rms = [Float](repeating: 0, count: count)
            for ch in 0..<count {
                // Accelerate runs the 64-channel RMS/peak reductions in vectorized DSP.
                // Never execute per-sample Swift loops inside an audio tap.
                var peak: Float = 0
                var rootMeanSquare: Float = 0
                vDSP_maxmgv(data[ch], 1, &peak, vDSP_Length(frames))
                vDSP_rmsqv(data[ch], 1, &rootMeanSquare, vDSP_Length(frames))
                peaks[ch] = peak.isFinite ? peak : 0
                rms[ch] = rootMeanSquare.isFinite ? rootMeanSquare : 0
            }
            DispatchQueue.main.async { meterSink?(peaks, rms) }
        }
        engine = graph
        matrix = mixerUnit
        voices = newVoices
        testBuffer = tone
        testToneOutput = nil
        testToneVoice = nil
        selectedDevice = device
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main) { [weak self, weak graph] _ in
                Task { @MainActor in
                    guard let self, let graph, self.engine === graph else { return }
                    let rate = self.hardwareSampleRate()
                    if abs(rate - self.sampleRate) > 0.5 { self.onSampleRateInvalidated?(rate) }
                }
            }
    }

    /// Apply audible/inaudible states at the physical MatrixMixer output scope.
    /// This preserves all per-stem crosspoints and never touches the cue transport.
    func applyOutputControls(_ controls: OutputMuteSoloState) throws {
        guard isReady, let matrix, let device = selectedDevice,
              controls.channelCount == device.channels else {
            throw RoutingError.engineNotReady
        }
        for channel in 1...device.channels {
            try require(AudioUnitSetParameter(matrix.audioUnit,
                        kMatrixMixerParam_Volume,
                        kAudioUnitScope_Output,
                        UInt32(channel - 1),
                        controls.outputGain(channel), 0),
                        "output \(channel) mute/solo")
        }
    }

    /// Safe, operator-armed 440 Hz −30 dBFS test tone through an existing
    /// free MatrixMixer input. Disabled while cues are running by the caller.
    func startTestTone(output channel: Int) throws {
        guard isReady, let matrix, let testBuffer,
              let device = selectedDevice, channel >= 1, channel <= device.channels,
              cueToVoices.isEmpty,
              let index = voices.indices.last(where: { voices[$0].owner == nil }) else {
            throw RoutingError.engineNotReady
        }
        stopTestTone()
        try route(index: index, fileChannels: 1, firstOutput: channel, on: matrix, physical: true)
        voices[index].gainNode.outputVolume = 1
        voices[index].node.scheduleBuffer(testBuffer, at: nil, options: .loops, completionHandler: nil)
        voices[index].node.play()
        testToneOutput = channel
        testToneVoice = index
    }

    func stopTestTone() {
        if let index = testToneVoice, voices.indices.contains(index) {
            voices[index].node.stop()
            voices[index].gainNode.outputVolume = 0
            if let matrix, let device = selectedDevice {
                for output in 0..<device.channels {
                    for input in (index * 2)..<(index * 2 + 2) {
                        let crosspoint = (UInt32(input) << 16) | UInt32(output)
                        _ = AudioUnitSetParameter(matrix.audioUnit, kMatrixMixerParam_Volume,
                             kAudioUnitScope_Global, crosspoint, 0, 0)
                    }
                }
            }
        }
        testToneOutput = nil
        testToneVoice = nil
    }

    private func require(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else { throw RoutingError.cannotConfigure(label, status) }
    }

    func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        for id in Array(conditionalLoops.keys) { stop(id) }
        stopLTC()
        // Disconnect the tap before destroying its host graph.
        if let matrix { matrix.removeTap(onBus: 0) }
        stopTestTone()
        testBuffer = nil
        for voice in voices { voice.node.stop() }
        engine?.stop()
        voices = []
        fileCache.removeAll()
        cueToVoices.removeAll()
        activeMarkerLoops.removeAll()
        matrix = nil
        engine = nil
        ltcSource = nil
        ltcRealtime = nil
        selectedDevice = nil
    }

    func start(_ cue: Cue, from elapsed: Double, fade: Float, hostLead: Double = 0.22) throws -> Double {
        stopTestTone()
        guard isReady, let matrix, let device = selectedDevice else { throw RoutingError.engineNotReady }
        if cue.hasAudio && monitor.enabled && !monitor.isAvailable(deviceUID: device.uid, channels: device.channels) {
            throw ShowMonitorSettings.Failure.unavailable
        }
        // Validate LTC BEFORE changing any running cue, to prevent live
        // output collisions and accidental SMPTE audio on an audio stem.
        let timecodes = cue.elements.filter { $0.kind == .timecode && !$0.muted }
        guard timecodes.count <= 1 else {
            throw RoutingError.ltcConflict("Only one active LTC element is supported per cue.")
        }
        let timecode = timecodes.first
        if let timecode {
            guard let channel = timecode.ltcOutputChannel,
                  (1...device.channels).contains(channel) else {
                throw RoutingError.ltcConflict("Configure a dedicated LTC OUT on ‘\(cue.name)’ before GO.")
            }
            guard !monitor.reservedOutputs(deviceUID: device.uid, channels: device.channels).contains(channel) else {
                throw RoutingError.ltcConflict("OUT \(channel) is reserved for Monitor.")
            }
            let rate = LTCFrameRate(fps: timecode.frameRate, drop: timecode.timecodeDropFrame)
            guard LTCTimecode(text: timecode.timecodeStart, rate: rate) != nil,
                  LTCFrameTrim(text: timecode.ltcTrim, rate: rate) != nil else {
                throw RoutingError.ltcConflict("Invalid SMPTE start address in ‘\(cue.name)’.")
            }
            if let owner = ltcOwner, owner != cue.id {
                throw RoutingError.ltcConflict("LTC is already being generated by another cue. Stop it before starting a second LTC cue.")
            }
            for voice in voices where voice.owner != nil && voice.owner != cue.id {
                if try mappedOutputs(first: voice.firstOutput, channels: voice.fileChannels).contains(where: { $0.deviceChannel + 1 == channel }) {
                    throw RoutingError.ltcConflict("LTC OUT \(channel) is already carrying an active audio stem.")
                }
            }
        }
        if let output = ltcOutput, ltcOwner != cue.id {
            for stem in cue.alignedAudioElements {
                let f = try preparedFile(for: stem)
                if try mappedOutputs(first: stem.outputStartChannel, channels: Int(f.processingFormat.channelCount)).contains(where: { $0.deviceChannel + 1 == output }) {
                    throw RoutingError.ltcConflict("OUT \(output) is reserved for active LTC. Choose another audio output.")
                }
            }
        }
        var files: [(CueElement, AVAudioFile)] = []
        for stem in cue.alignedAudioElements {
            let f = try preparedFile(for: stem)
            let count = Int(f.processingFormat.channelCount)
            guard count == 1 || count == 2 else { throw RoutingError.unsupportedSource(stem.name, count) }
            let points = try mappedOutputs(first: stem.outputStartChannel, channels: count)
            if let tcChannel = timecode?.ltcOutputChannel,
               points.contains(where: { $0.deviceChannel + 1 == tcChannel }) {
                throw RoutingError.ltcConflict("LTC OUT \(tcChannel) overlaps with a stem in ‘\(cue.name)’.")
            }
            files.append((stem, f))
        }
        let available = voices.filter { $0.owner == nil || $0.owner == cue.id }.count
        guard available >= files.count else { throw RoutingError.noVoices(files.count) }
        // All file/routing/capacity checks passed; now release the previous instance.
        stop(cue.id, updateSignal: false)
        let free = voices.indices.filter { voices[$0].owner == nil }
        let assigned = Array(free.prefix(files.count))
        // Native file segment queues require one identical render sample rate
        // and complete source coverage across all stems. Otherwise fall back
        // to the original (timer-driven) loop, never a partial mixed loop.
        let cueLength = cue.timelineLength(audioEnds: files.map {
            Double($0.1.length) / $0.1.processingFormat.sampleRate
        })
        let candidate = NativeMarkerLoopPlanner.plan(for: cue) ??
            (cue.loop && !cue.hasTimecode && cueLength >= 0.4 && cueLength <= 600
                ? NativeMarkerLoop(triggerMarkerID: nil, inSeconds: 0, outSeconds: cueLength) : nil)
        var conditional: ConditionalLoopRealtime?
        if let plan = candidate, let conditionID = plan.conditionCueID, elapsed < plan.outSeconds {
            let pcm = try files.map { stem, _ -> PreparedConditionalPCM in
                guard let prepared = preparedConditionalFiles[stem.sourcePath],
                      prepared.matches(path: stem.sourcePath, sampleRate: Int(sampleRate)) else {
                    throw SessionAudioPreparation.Failure.invalid("Prepare conditional-loop media before GO")
                }
                return prepared
            }
            let loop = try ConditionalLoopRealtime(plan: plan, sampleRate: sampleRate, end: cueLength,
                files: pcm, from: elapsed, indices: assigned, slots: assigned.map { voices[$0].loopSlot },
                condition: signal(for: conditionID), own: signal(for: cue.id))
            conditional = loop
            conditionalLoops[cue.id] = loop
            activeMarkerLoops[cue.id] = ActiveMarkerLoop(plan: plan, token: UUID(), buffers: [])
        }
        // Short loops repeat inside the audio renderer, with no main-queue
        // replenishment that another cue's preparation could delay.
        var loopBuffers: [AVAudioPCMBuffer] = []
        let nativePlan = candidate.flatMap { plan -> NativeMarkerLoop? in
            guard plan.conditionCueID == nil else { return nil }
            guard files.allSatisfy({ abs($0.1.processingFormat.sampleRate - sampleRate) < 0.5 }),
                  elapsed < plan.outSeconds else { return nil }
            let occupied = activeMarkerLoops.values.flatMap(\.buffers).reduce(0) {
                $0 + Int($1.frameLength) * Int($1.format.channelCount) * 4
            }
            let bytes = files.reduce(0.0) { total, entry in
                total + (plan.outSeconds - plan.inSeconds) * sampleRate *
                    2 * 4
            }
            if bytes <= Double(max(0, 128 * 1024 * 1024 - occupied)),
               files.allSatisfy({ Double($0.1.length) / $0.1.processingFormat.sampleRate >= plan.outSeconds }),
               assigned.allSatisfy({ abs(voices[$0].node.outputFormat(forBus: 0).sampleRate - sampleRate) < 0.5 }) {
                do {
                    loopBuffers = try files.enumerated().map { number, entry in
                        try NativeLoopBuffer.prepare(file: entry.1, start: plan.inSeconds, end: plan.outSeconds,
                            outputChannels: voices[assigned[number]].node.outputFormat(forBus: 0).channelCount)
                    }
                    return plan
                } catch { loopBuffers = [] }
            }
            // Long loops retain bounded file queues; four long cycles provide
            // a large replenishment window without allocating minutes of PCM.
            return files.allSatisfy {
                Double($0.1.length) / $0.1.processingFormat.sampleRate >= plan.outSeconds
            } ? plan : nil
        }
        if let nativePlan {
            activeMarkerLoops[cue.id] = ActiveMarkerLoop(plan: nativePlan, token: UUID(), buffers: loopBuffers)
        }
        // Mark all occupied before scheduling. If a step throws, stop() releases all.
        cueToVoices[cue.id] = assigned
        do {
            for (number, entry) in files.enumerated() {
                let index = assigned[number]
                voices[index].owner = cue.id
                voices[index].elementID = entry.0.id
                voices[index].file = entry.1
                voices[index].fileChannels = Int(entry.1.processingFormat.channelCount)
                voices[index].firstOutput = entry.0.outputStartChannel
                voices[index].node.stop()
                try route(index: index, fileChannels: voices[index].fileChannels,
                          firstOutput: entry.0.outputStartChannel, on: matrix)
                let sampleRate = entry.1.processingFormat.sampleRate
                let offsetFrames = AudioFramePlan.position(seconds: elapsed, sampleRate: sampleRate, fileLength: entry.1.length)
                let cueEndFrame = AVAudioFramePosition(min(Double(entry.1.length), (cueLength * sampleRate).rounded()))
                let remaining = max(0, cueEndFrame - offsetFrames)
                if conditional != nil {
                    // This voice is rendered by its preconnected source node.
                } else if let plan = nativePlan, let state = activeMarkerLoops[cue.id] {
                    let stopFrame = min(entry.1.length,
                        AVAudioFramePosition((plan.outSeconds * sampleRate).rounded()))
                    if stopFrame > offsetFrames {
                        voices[index].node.scheduleSegment(entry.1, startingFrame: offsetFrames,
                            frameCount: AVAudioFrameCount(stopFrame - offsetFrames), at: nil, completionHandler: nil)
                    }
                    // Prefill four future cycles before audio begins. Replenish
                    // each from playback callbacks without stopping the player.
                    if state.buffers.indices.contains(number) {
                        voices[index].node.scheduleBuffer(state.buffers[number], at: nil,
                            options: .loops, completionHandler: nil)
                    } else {
                        for _ in 0..<4 {
                            appendLoopSegment(cueID: cue.id, voice: index, token: state.token)
                        }
                    }
                } else if remaining > 0 {
                    voices[index].node.scheduleSegment(entry.1, startingFrame: offsetFrames,
                        frameCount: AVAudioFrameCount(min(Int64(UInt32.max), remaining)), at: nil, completionHandler: nil)
                }
                try applyVoiceRouting(index: index, element: entry.0)
                voices[index].gainNode.outputVolume = fade * Float(cue.gain * entry.0.gain) *
                    ((entry.0.muted || (!soloedInputs.isEmpty && !soloedInputs.contains(entry.0.id))) ? 0 : 1)
            }
            let synchronizedLead = hostLead <= 0.01 ? hostLead :
                max(hostLead, files.count >= 48 ? 0.45 : (files.count >= 24 ? 0.32 : hostLead))
            let deadline = AudioGetCurrentHostTime() + AVAudioTime.hostTime(forSeconds: synchronizedLead)
            if let conditional {
                sculpt_loop_arm(conditional.pointer, AudioConvertHostTimeToNanos(deadline),
                    Int64((elapsed * sampleRate).rounded()))
                for index in assigned { sculpt_loop_slot_bind(voices[index].loopSlot.pointer, conditional.pointer) }
            } else {
                let own = try signal(for: cue.id)
                let end: UInt64 = nativePlan != nil ? UInt64.max :
                    AudioConvertHostTimeToNanos(deadline) + UInt64(max(0, cueLength - elapsed) * 1e9)
                sculpt_signal_set(own.pointer, 1, AudioConvertHostTimeToNanos(deadline), end)
            }
            if let timecode {
                try startLTC(timecode, owner: cue.id, hostDeadline: deadline,
                             from: elapsed, duration: cue.timelineLength(audioEnds: files.map {
                                  Double($0.1.length) / $0.1.processingFormat.sampleRate
                             }))
            }
            for index in assigned {
                guard let f = voices[index].file else { continue }
                let offsetFrames = AudioFramePlan.position(seconds: elapsed, sampleRate: f.processingFormat.sampleRate, fileLength: f.length)
                if conditional == nil && offsetFrames < f.length {
                    voices[index].node.play(at: AVAudioTime(hostTime: deadline))
                }
            }
            return synchronizedLead
        } catch {
            stop(cue.id)
            throw error
        }
    }

    /// Seek while keeping file handles, player nodes and physical routing.
    /// Still uses a shared future deadline for inter-stem synchronization.
    func jump(_ cue: Cue, from elapsed: Double, fade: Float, hostLead: Double) throws -> Double {
        guard isReady, let assigned = cueToVoices[cue.id],
              assigned.count == cue.alignedAudioElements.count else {
            return try start(cue, from: elapsed, fade: fade, hostLead: hostLead)
        }
        let stems = cue.alignedAudioElements
        for (order, index) in assigned.enumerated() {
            guard voices.indices.contains(index), voices[index].elementID == stems[order].id,
                  voices[index].file != nil,
                  voices[index].firstOutput == stems[order].outputStartChannel else {
                return try start(cue, from: elapsed, fade: fade, hostLead: hostLead)
            }
        }
        // Rebuild loop queues only when the cue actually seeks into its region.
        if activeMarkerLoops[cue.id] != nil {
            return try start(cue, from: elapsed, fade: fade, hostLead: hostLead)
        }
        let cueLength = cue.timelineLength(audioEnds: assigned.compactMap {
            guard let file = voices[$0].file else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        })
        let lead = max(0.10, hostLead)
        for index in assigned { voices[index].node.stop() }
        for (order, index) in assigned.enumerated() {
            guard let file = voices[index].file else { throw RoutingError.engineNotReady }
            let frame = AudioFramePlan.position(seconds: elapsed, sampleRate: file.processingFormat.sampleRate, fileLength: file.length)
            let cueEndFrame = AVAudioFramePosition(min(Double(file.length), (cueLength * file.processingFormat.sampleRate).rounded()))
            let remaining = max(0, cueEndFrame - frame)
            if remaining > 0 {
                voices[index].node.scheduleSegment(file, startingFrame: frame,
                    frameCount: AVAudioFrameCount(min(Int64(UInt32.max), remaining)),
                    at: nil, completionHandler: nil)
            }
            voices[index].gainNode.outputVolume = fade * Float(cue.gain * stems[order].gain)
                * ((stems[order].muted || (!soloedInputs.isEmpty && !soloedInputs.contains(stems[order].id))) ? 0 : 1)
        }
        let deadline = AudioGetCurrentHostTime() + AVAudioTime.hostTime(forSeconds: lead)
        if let timecode = cue.elements.first(where: { $0.kind == .timecode && !$0.muted }) {
            try startLTC(timecode, owner: cue.id, hostDeadline: deadline,
                from: elapsed, duration: cue.timelineLength(audioEnds: assigned.compactMap {
                    guard let f = voices[$0].file else { return nil }
                    return Double(f.length) / f.processingFormat.sampleRate
                }))
        }
        for index in assigned {
            guard let file = voices[index].file else { continue }
            if AudioFramePlan.position(seconds: elapsed, sampleRate: file.processingFormat.sampleRate, fileLength: file.length) < file.length {
                voices[index].node.play(at: AVAudioTime(hostTime: deadline))
            }
        }
        return lead
    }

    private func startLTC(_ element: CueElement, owner: UUID, hostDeadline: UInt64,
                          from elapsed: Double, duration: Double) throws {
        guard let matrix, let realtime = ltcRealtime,
              let channel = element.ltcOutputChannel,
              let address = LTCTimecode(text: element.timecodeStart,
                   rate: LTCFrameRate(fps: element.frameRate,
                                      drop: element.timecodeDropFrame)),
              let trim = LTCFrameTrim(text: element.ltcTrim, rate: address.rate) else {
            throw RoutingError.ltcConflict("Missing or invalid LTC configuration.")
        }
        stopLTC()
        let input = UInt32(ltcInputIndex * 2)
        let crosspoint = (input << 16) | UInt32(channel - 1)
        // Keep the physical crosspoint at unity: positive LTC gain is handled
        // inside the dedicated DSP renderer, never by an out-of-range AU value.
        try require(AudioUnitSetParameter(matrix.audioUnit,
                    kMatrixMixerParam_Volume, kAudioUnitScope_Global,
                    crosspoint, 1, 0), "LTC physical route")
        sculpt_ltc_set_level_db(realtime.pointer, element.ltcLevelTrimDB)
        sculpt_ltc_start(realtime.pointer, AudioConvertHostTimeToNanos(hostDeadline),
                         address.absoluteFrames + trim.frames, Int32(address.rate.rawValue),
                         element.startSeconds, elapsed, duration)
        ltcOwner = owner
        ltcElement = element
        ltcOutput = channel
    }

    /// Live, lock-free LTC gain trim; no matrix repatch or voice rescheduling.
    func setLTCLevel(for owner: UUID, trimDB: Double) {
        guard ltcOwner == owner, let realtime = ltcRealtime else { return }
        let db = trimDB.isFinite ? min(12, max(-36, trimDB)) : 0
        sculpt_ltc_set_level_db(realtime.pointer, db)
        ltcElement?.ltcLevelTrimDB = db
    }

    private func stopLTC() {
        ltcRealtime.map { sculpt_ltc_stop($0.pointer) }
        if let matrix, let output = ltcOutput {
            let crosspoint = (UInt32(ltcInputIndex * 2) << 16) | UInt32(output - 1)
            _ = AudioUnitSetParameter(matrix.audioUnit,
                kMatrixMixerParam_Volume, kAudioUnitScope_Global, crosspoint, 0, 0)
        }
        ltcOwner = nil
        ltcElement = nil
        ltcOutput = nil
    }

    private func mappedOutputs(first: Int, channels: Int) throws -> [AudioRoutePlan.Crosspoint] {
        guard let device = selectedDevice else { throw RoutingError.engineNotReady }
        return try outputPatch.crosspoints(firstOutput: first, sourceChannels: channels,
            deviceUID: device.uid, deviceChannels: device.channels,
            excluding: monitor.reservedOutputs(deviceUID: device.uid, channels: device.channels))
    }

    private func route(index: Int, fileChannels: Int, firstOutput: Int, on matrix: AVAudioUnit, physical: Bool = false) throws {
        let au = matrix.audioUnit
        let inputStart = index * 2
        guard let outputs = selectedDevice?.channels else { throw RoutingError.engineNotReady }
        // Clear previous assignment whenever a voice is reused for a different cue.
        for input in inputStart..<(inputStart + 2) {
            for output in 0..<outputs {
                try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                  kAudioUnitScope_Global, (UInt32(input) << 16) | UInt32(output), 0, 0), "clear stem")
            }
        }
        let mappings: [AudioRoutePlan.Crosspoint]
        if physical {
            guard let points = AudioRoutePlan.crosspoints(firstOutput: firstOutput,
                sourceChannels: fileChannels, deviceChannels: outputs) else { throw RoutingError.invalidChannel("Audio", firstOutput) }
            mappings = points
        } else { mappings = try mappedOutputs(first: firstOutput, channels: fileChannels) }
        voices[index].matrixGains = mappings.map { .init(source: $0.sourceChannel, output: $0.deviceChannel, value: 1) }
        for map in mappings {
            let input = inputStart + map.sourceChannel
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                 kAudioUnitScope_Global, (UInt32(input) << 16) | UInt32(map.deviceChannel), 1, 0), "assign stem")
        }
    }

    /// Live output crosspoint patch. Does NOT stop/schedule the player node.
    /// A paused cue has no allocated voices, but will honor the stored route on resume.
    func changeOutput(cueID: UUID, elementID: UUID, firstOutput: Int,
                      sourceChannels: Int) throws {
        guard selectedDevice != nil, matrix != nil else { throw RoutingError.engineNotReady }
        let next = try mappedOutputs(first: firstOutput, channels: sourceChannels)
        if let output = ltcOutput, next.contains(where: { $0.deviceChannel + 1 == output }) {
            throw RoutingError.ltcConflict("OUT \(output) is reserved for active LTC.")
        }
        guard let index = (cueToVoices[cueID] ?? []).first(where: { voices[$0].elementID == elementID }) else {
            return // Paused/stopped cue: next GO uses the stored route.
        }
        // Include monitor weights in the next diff, never accidentally erase its send.
        let previous = voices[index].firstOutput
        voices[index].firstOutput = firstOutput
        do {
            if var mix = voices[index].mix { mix.outputStartChannel = firstOutput; try applyVoiceRouting(index: index, element: mix) }
        } catch { voices[index].firstOutput = previous; throw error }
    }

    private func applyVoiceRouting(index: Int, element: CueElement) throws {
        guard let matrix else { throw RoutingError.engineNotReady }
        let program = try mappedOutputs(first: voices[index].firstOutput, channels: voices[index].fileChannels)
        let next = MonitorMixPlan.gains(channels: voices[index].fileChannels, program: program,
            pan: element.pan, send: element.sendToMonitor, monitor: monitor)
        let old = voices[index].matrixGains
        voices[index].mix = element
        guard next != old else { return }
        for prior in old where !next.contains(where: { $0.source == prior.source && $0.output == prior.output }) {
            let key = (UInt32(index * 2 + prior.source) << 16) | UInt32(prior.output)
            try require(AudioUnitSetParameter(matrix.audioUnit, kMatrixMixerParam_Volume,
                kAudioUnitScope_Global, key, 0, 0), "disconnect mix route")
        }
        for point in next where !old.contains(point) {
            let key = (UInt32(index * 2 + point.source) << 16) | UInt32(point.output)
            try require(AudioUnitSetParameter(matrix.audioUnit, kMatrixMixerParam_Volume,
                kAudioUnitScope_Global, key, point.value, 0), "apply program/Monitor mix")
        }
        voices[index].matrixGains = next
    }

    func updateMix(_ cue: Cue, fadeFactor: Float, dimFactor: Float) throws {
        for index in cueToVoices[cue.id] ?? [] {
            guard let elementID = voices[index].elementID,
                  let element = cue.elements.first(where: { $0.id == elementID }) else { continue }
            try applyVoiceRouting(index: index, element: element)
            voices[index].gainNode.outputVolume = AudioGainPlan.linear(cue: cue.gain, element: element.gain,
                fade: fadeFactor, trim: dimFactor, muted: element.muted || (!soloedInputs.isEmpty && !soloedInputs.contains(elementID)))
        }
    }

    func stop(_ cueID: UUID, updateSignal: Bool = true) {
        if updateSignal, let signal = signals[cueID] { sculpt_signal_phase(signal.pointer, 0) }
        if let loop = conditionalLoops.removeValue(forKey: cueID) {
            loop.unbind()
            retiredLoops.append(loop)
        }
        retiredLoops.removeAll { $0.quiescent }
        activeMarkerLoops.removeValue(forKey: cueID)
        if ltcOwner == cueID { stopLTC() }
        guard let assigned = cueToVoices.removeValue(forKey: cueID) else { return }
        for index in assigned {
            voices[index].gainNode.outputVolume = 0
            voices[index].node.stop()
            voices[index].owner = nil
            voices[index].file = nil
            if let elementID = voices[index].elementID { fileCache.removeValue(forKey: elementID) }
            voices[index].elementID = nil
        }
    }
}
