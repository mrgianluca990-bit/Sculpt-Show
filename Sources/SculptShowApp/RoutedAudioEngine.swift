import Foundation
import AVFAudio
import AudioToolbox
import CoreAudio
import SculptShowCore

/// Optional multi-output engine. The proven AVAudioPlayer backend remains the
/// default until the user explicitly enables routing from the panel.
/// 16 stereo input buses -> a physical output device with up to 64 channels.
/// A single host timestamp starts all AVAudioPlayerNodes for a multitrack cue.
@MainActor
final class RoutedAudioEngine {
    struct OutputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let channels: Int
    }

    enum RoutingError: LocalizedError {
        case deviceNotFound
        case noDeviceOutput
        case cannotConfigure(String, OSStatus)
        case unsupportedSource(String, Int)
        case noVoices(Int)
        case invalidChannel(String, Int)
        case engineNotReady

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: return "The selected output device is no longer connected. Refresh the device list."
            case .noDeviceOutput: return "The output device has no usable audio channels."
            case .cannotConfigure(let operation, let code): return "Core Audio routing failed (\(operation), OSStatus \(code))."
            case .unsupportedSource(let name, let count): return "\(name) has \(count) channels. Routed playback currently accepts mono/stereo WAV/AIFF stems only."
            case .noVoices(let count): return "This show requires \(count) voices. The current routed engine supports 16 simultaneous mono/stereo files."
            case .invalidChannel(let name, let index): return "Invalid output \(index) for ‘\(name)’ on the selected device."
            case .engineNotReady: return "Routing engine not initialized. Open OUTPUT ROUTING and enable it first."
            }
        }
    }

    private struct Voice {
        let node: AVAudioPlayerNode
        let gainNode: AVAudioMixerNode
        var owner: UUID?
        var elementID: UUID?
        var file: AVAudioFile?
        var fileChannels = 2
        var firstOutput = 1
    }

    static let maximumVoices = 16
    private var engine: AVAudioEngine?
    private var matrix: AVAudioUnit?
    private var voices: [Voice] = []
    private(set) var selectedDevice: OutputDevice?
    private var cueToVoices: [UUID: [Int]] = [:]

    var isReady: Bool { engine?.isRunning == true && selectedDevice != nil }

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
            return OutputDevice(id: device, name: label, channels: channels)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Changing hardware graph while audio is running is intentionally disallowed.
    func configure(device: OutputDevice) async throws {
        guard cueToVoices.isEmpty else { throw RoutingError.cannotConfigure("active cues", -1) }
        teardown()
        guard device.channels > 0, device.channels <= 64 else { throw RoutingError.noDeviceOutput }
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

        var inputCount = UInt32(Self.maximumVoices)
        var outputBusCount: UInt32 = 1
        status = AudioUnitSetProperty(mixerUnit.audioUnit, kAudioUnitProperty_ElementCount,
            kAudioUnitScope_Input, 0, &inputCount, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw RoutingError.cannotConfigure("matrix inputs", status) }
        status = AudioUnitSetProperty(mixerUnit.audioUnit, kAudioUnitProperty_ElementCount,
            kAudioUnitScope_Output, 0, &outputBusCount, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw RoutingError.cannotConfigure("matrix output", status) }
        graph.attach(mixerUnit)
        let current = graph.outputNode.outputFormat(forBus: 0)
        let rate = current.sampleRate > 0 ? current.sampleRate : 48000
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
        for index in 0..<Self.maximumVoices {
            let player = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            graph.attach(player)
            graph.attach(gain)
            graph.connect(player, to: gain, format: nil)
            graph.connect(gain, to: mixerUnit, fromBus: 0, toBus: index, format: stereo)
            gain.outputVolume = 0
            newVoices.append(Voice(node: player, gainNode: gain))
        }
        graph.prepare()
        try graph.start()
        let au = mixerUnit.audioUnit
        // The matrix defaults to silence. Configure input/output/master volumes;
        // *crosspoints stay zero* until a cue is assigned to the appropriate bus.
        try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Global, 0xFFFFFFFF, 1, 0), "master")
        for index in 0..<Self.maximumVoices * 2 {
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Input, UInt32(index), 1, 0), "input channel")
        }
        for channel in 0..<device.channels {
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                kAudioUnitScope_Output, UInt32(channel), 1, 0), "output channel")
        }
        // Explicit all-zero crosspoints ensures disconnected tracks cannot leak.
        for input in 0..<(Self.maximumVoices * 2) {
            for output in 0..<device.channels {
                try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                   kAudioUnitScope_Global, (UInt32(input) << 16) | UInt32(output), 0, 0), "clear matrix")
            }
        }
        engine = graph
        matrix = mixerUnit
        voices = newVoices
        selectedDevice = device
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

    private func require(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else { throw RoutingError.cannotConfigure(label, status) }
    }

    func teardown() {
        for voice in voices { voice.node.stop() }
        engine?.stop()
        voices = []
        cueToVoices.removeAll()
        matrix = nil
        engine = nil
        selectedDevice = nil
    }

    func start(_ cue: Cue, from elapsed: Double, fade: Float, hostLead: Double = 0.22) throws -> Double {
        guard isReady, let matrix, let device = selectedDevice else { throw RoutingError.engineNotReady }
        // Remove and re-arm on seek/resume, keeping free-voice occupancy atomic.
        stop(cue.id)
        var files: [(CueElement, AVAudioFile)] = []
        for stem in cue.alignedAudioElements {
            let f = try AVAudioFile(forReading: URL(fileURLWithPath: stem.sourcePath))
            let count = Int(f.processingFormat.channelCount)
            guard count == 1 || count == 2 else { throw RoutingError.unsupportedSource(stem.name, count) }
            guard AudioRoutePlan.crosspoints(firstOutput: stem.outputStartChannel,
                 sourceChannels: count, deviceChannels: device.channels) != nil else {
                throw RoutingError.invalidChannel(stem.name, stem.outputStartChannel)
            }
            files.append((stem, f))
        }
        let free = voices.indices.filter { voices[$0].owner == nil }
        guard free.count >= files.count else { throw RoutingError.noVoices(files.count) }
        let assigned = Array(free.prefix(files.count))
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
                let offsetFrames = AVAudioFramePosition(max(0, elapsed) * sampleRate)
                let remaining = max(0, entry.1.length - offsetFrames)
                if remaining > 0 {
                    voices[index].node.scheduleSegment(entry.1, startingFrame: offsetFrames,
                        frameCount: AVAudioFrameCount(min(Int64(UInt32.max), remaining)), at: nil, completionHandler: nil)
                }
                voices[index].gainNode.outputVolume = fade * Float(cue.gain * entry.0.gain) * (entry.0.muted ? 0 : 1)
            }
            let deadline = AudioGetCurrentHostTime() + AVAudioTime.hostTime(forSeconds: hostLead)
            for index in assigned {
                let f = voices[index].file!
                let offsetFrames = AVAudioFramePosition(max(0, elapsed) * f.processingFormat.sampleRate)
                if offsetFrames < f.length {
                    voices[index].node.play(at: AVAudioTime(hostTime: deadline))
                }
            }
            return hostLead
        } catch {
            stop(cue.id)
            throw error
        }
    }

    private func route(index: Int, fileChannels: Int, firstOutput: Int, on matrix: AVAudioUnit) throws {
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
        guard let mappings = AudioRoutePlan.crosspoints(firstOutput: firstOutput,
              sourceChannels: fileChannels, deviceChannels: outputs) else { throw RoutingError.invalidChannel("Audio", firstOutput) }
        for map in mappings {
            let input = inputStart + map.sourceChannel
            try require(AudioUnitSetParameter(au, kMatrixMixerParam_Volume,
                 kAudioUnitScope_Global, (UInt32(input) << 16) | UInt32(map.deviceChannel), 1, 0), "assign stem")
        }
    }

    func updateMix(_ cue: Cue, fadeFactor: Float, dimFactor: Float) {
        for index in cueToVoices[cue.id] ?? [] {
            guard let elementID = voices[index].elementID,
                  let element = cue.elements.first(where: { $0.id == elementID }) else { continue }
            voices[index].gainNode.outputVolume = max(0, min(1, fadeFactor * dimFactor * Float(cue.gain * element.gain) * (element.muted ? 0 : 1)))
        }
    }

    func stop(_ cueID: UUID) {
        guard let assigned = cueToVoices.removeValue(forKey: cueID) else { return }
        for index in assigned {
            voices[index].gainNode.outputVolume = 0
            voices[index].node.stop()
            voices[index].owner = nil
            voices[index].file = nil
            voices[index].elementID = nil
        }
    }
}
