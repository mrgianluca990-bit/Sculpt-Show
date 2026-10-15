import CoreMIDI
import Foundation
import SwiftUI
import SculptShowCore

/// Owns only the MTC output timer, never the Core Audio playback graph.
/// On a dedicated serial queue: avoids 96-120 callbacks per second on SwiftUI.
private final class MTCQuarterFrameWorker {
    private let queue = DispatchQueue(label: "com.sculptshow.mtc-output", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func start(port: MIDIPortRef, endpoint: MIDIEndpointRef,
               rate: MTCGeneratorRate, from position: Double) {
        stop()
        let frequency = rate.actualFPS * 4.0
        let interval = Int((1_000_000_000.0 / frequency).rounded())
        let started = DispatchTime.now().uptimeNanoseconds
        var sequence = 0
        var groupedFrame = MTCGeneratorModel.frame(at: position, rate: rate)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .microseconds(500))
        source.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - started) / 1_000_000_000
            // The eight QF pieces represent two consecutive video frames.
            // Publish time 2 frames ahead so receivers reconstruct current time.
            if sequence == 0 {
                groupedFrame = MTCGeneratorModel.frame(
                    at: position + elapsed + 2.0 / rate.actualFPS, rate: rate)
            }
            // The eight nibbles of a cycle must describe a single frame;
            // mixing frames would corrupt seconds/frame boundaries.
            let data = MTCGeneratorModel.quarterFrameData(groupedFrame, rate: rate, phase: sequence)
            _ = Self.send([0xF1, data], port: port, endpoint: endpoint)
            sequence = (sequence + 1) % 8
        }
        timer = source
        source.resume()
    }

    /// One MIDI packet. Allocate extra space explicitly instead of assuming
    /// the initial MIDIPacketList struct has room for every SysEx payload.
    @discardableResult
    static func send(_ bytes: [UInt8], port: MIDIPortRef, endpoint: MIDIEndpointRef) -> OSStatus {
        guard port != 0, endpoint != 0, !bytes.isEmpty else { return -1 }
        let capacity = MemoryLayout<MIDIPacketList>.size + 256
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIPacketList.self)
        let initialPacket = MIDIPacketListInit(list)
        let appended = bytes.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<MIDIPacket>? in
            guard let base = buffer.baseAddress else { return nil }
            return MIDIPacketListAdd(list, capacity, initialPacket, 0, bytes.count, base)
        }
        guard appended != nil else { return -1 }
        return MIDISend(port, endpoint, list)
    }
}

/// First functional Sculpt Show MTC generator (MIDI quarter frame + full-frame locate).
/// Standalone manual clock, NOT sample-locked LTC or timecode chase yet.
@MainActor
final class TimecodeGenerator: ObservableObject {
    struct Destination: Identifiable, Hashable {
        let id: MIDIUniqueID
        let endpoint: MIDIEndpointRef
        let name: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published private(set) var destinations: [Destination] = []
    @Published var selectedID: MIDIUniqueID = 0
    @Published var rate: MTCGeneratorRate = .fps25
    @Published var startPosition: String = "01:00:00:00"
    @Published private(set) var displayedPosition = "01:00:00:00"
    @Published private(set) var running = false
    @Published var errorMessage: String?

    private var client: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private let worker = MTCQuarterFrameWorker()
    private var displayTimer: Timer?
    private var startUptime: TimeInterval = 0
    private var startSeconds: Double = 0
    private let selectedKey = "SculptShow.mtcDestination.v1"

    init() {
        MIDIClientCreate("Sculpt Show MTC Generator" as CFString, nil, nil, &client)
        if client != 0 {
            let status = MIDIOutputPortCreate(client, "Sculpt Show MTC Out" as CFString, &outputPort)
            if status != noErr { errorMessage = "Cannot create MTC output (\(status))." }
        } else { errorMessage = "Cannot create CoreMIDI client for MTC generator." }
        refresh()
    }

    deinit {
        worker.stop()
        displayTimer?.invalidate()
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func refresh() {
        destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
            var property: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &property)
            let name = status == noErr && property != nil
                ? property!.takeRetainedValue() as String : "Destination \(index + 1)"
            return Destination(id: id, endpoint: endpoint, name: name)
        }
        if selectedID == 0, let saved = UserDefaults.standard.object(forKey: selectedKey) as? NSNumber {
            let id = MIDIUniqueID(saved.int32Value)
            if destinations.contains(where: { $0.id == id }) { selectedID = id }
        }
        if selectedID != 0 && !destinations.contains(where: { $0.id == selectedID }) {
            stop()
            selectedID = 0
            errorMessage = "MTC destination disconnected. Select a connected output."
        }
    }

    func selectDestination(_ id: MIDIUniqueID) {
        if running { stop() }
        selectedID = id
        UserDefaults.standard.set(NSNumber(value: id), forKey: selectedKey)
    }

    func locate() {
        guard let destination = destinations.first(where: { $0.id == selectedID }), outputPort != 0 else {
            errorMessage = "Choose a CoreMIDI output destination first."
            return
        }
        guard let position = MTCGeneratorModel.parsePosition(startPosition, rate: rate) else {
            errorMessage = "Invalid timecode. Use HH:MM:SS:FF with a valid frame number."
            return
        }
        let frame = MTCGeneratorModel.frame(at: position, rate: rate)
        let status = MTCQuarterFrameWorker.send(
            MTCGeneratorModel.fullFrameLocate(frame, rate: rate),
            port: outputPort, endpoint: destination.endpoint)
        if status != noErr { errorMessage = "CoreMIDI locate failed (\(status))." }
        else { displayedPosition = frame.display; errorMessage = nil }
    }

    func start() {
        guard !running else { return }
        guard let destination = destinations.first(where: { $0.id == selectedID }), outputPort != 0 else {
            errorMessage = "Choose a CoreMIDI output destination before START."
            return
        }
        guard let seconds = MTCGeneratorModel.parsePosition(startPosition, rate: rate) else {
            errorMessage = "Invalid start timecode (HH:MM:SS:FF)."
            return
        }
        locate()
        guard errorMessage == nil else { return }
        startSeconds = seconds
        startUptime = ProcessInfo.processInfo.systemUptime
        worker.start(port: outputPort, endpoint: destination.endpoint, rate: rate, from: seconds)
        running = true
        let clock = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplay() }
        }
        displayTimer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    private func refreshDisplay() {
        guard running else { return }
        displayedPosition = MTCGeneratorModel.frame(
            at: startSeconds + ProcessInfo.processInfo.systemUptime - startUptime,
            rate: rate).display
    }

    func stop() {
        guard running else { return }
        refreshDisplay()
        worker.stop()
        displayTimer?.invalidate()
        displayTimer = nil
        running = false
    }
}

struct TimecodeGeneratorView: View {
    @EnvironmentObject private var generator: TimecodeGenerator

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("MTC GENERATOR", systemImage: "arrow.up.right.video")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                Circle().fill(generator.running ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(generator.running ? "SENDING" : "STOPPED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            Text(generator.displayedPosition)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundColor(generator.running ? .green : .secondary)
            HStack {
                Picker("MIDI OUT", selection: Binding(
                    get: { generator.selectedID },
                    set: { generator.selectDestination($0) }
                )) {
                    Text("Choose destination").tag(MIDIUniqueID(0))
                    ForEach(generator.destinations) { destination in
                        Text(destination.name).tag(destination.id)
                    }
                }
                Button { generator.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh MIDI outputs")
            }
            Picker("FPS", selection: $generator.rate) {
                ForEach(MTCGeneratorRate.allCases, id: \.rawValue) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .disabled(generator.running)
            .pickerStyle(.segmented)
            TextField("HH:MM:SS:FF", text: $generator.startPosition)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disabled(generator.running)
                .onSubmit { generator.locate() }
            HStack {
                Button("LOCATE") { generator.locate() }
                    .disabled(generator.running)
                Button("START") { generator.start() }
                    .disabled(generator.running)
                Button("STOP") { generator.stop() }
                    .disabled(!generator.running)
            }
            .controlSize(.small)
            if let error = generator.errorMessage {
                Text(error).foregroundColor(.orange).font(.caption)
            }
            Spacer(minLength: 0)
            Text("Sends CoreMIDI MTC quarter frames and Full Frame Locate. Generator uses a dedicated timer (not audio-locked); NOT LTC and NOT cue chase. Use a MIDI destination such as IAC for testing.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
