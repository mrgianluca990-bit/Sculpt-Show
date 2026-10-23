import Foundation
import Darwin
import SwiftUI
import SculptShowCore

/// UDP control is handled on the operator queue, never the audio render thread.
@MainActor final class OSCControl: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var port = 53000
    @Published private(set) var allowLAN = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var lastMessage = "No OSC command"
    @Published private(set) var rejected = 0
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var generation = UUID()
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var windowCount = 0
    private var commandCount = 0
    var handle: ((OSCControlPacket.Command) -> String?)?
    init() {
        let prefs = UserDefaults.standard
        let savedPort = prefs.integer(forKey: "sculpt.osc.port")
        if (1024...65535).contains(savedPort) { port = savedPort }
        allowLAN = prefs.bool(forKey: "sculpt.osc.lan")
        if prefs.bool(forKey: "sculpt.osc.enabled") { configure(enabled: true, port: port, allowLAN: allowLAN) }
    }
    func configure(enabled: Bool, port: Int, allowLAN: Bool) {
        guard (1024...65535).contains(port) else { status = "Port must be 1024–65535"; return }
        generation = UUID()
        source?.cancel(); source = nil
        if descriptor >= 0 { Darwin.close(descriptor) }; descriptor = -1; self.enabled = false
        UserDefaults.standard.set(false, forKey: "sculpt.osc.enabled")
        if enabled {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { status = "Cannot create UDP socket"; return }
            var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = UInt16(port).bigEndian
            endpoint.sin_addr.s_addr = inet_addr(allowLAN ? "0.0.0.0" : "127.0.0.1")
            let bound = withUnsafePointer(to: &endpoint) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                let reason = String(cString: strerror(errno)); Darwin.close(fd); status = "OSC unavailable: \(reason)"; return
            }
            descriptor = fd
            let token = generation
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            reader.setEventHandler { [weak self] in guard let self, self.generation == token else { return }; self.receive(fd) }
            // All socket access is serialized on main; close synchronously on reconfigure.
            source = reader; reader.resume(); self.enabled = true
        }
        self.port = port; self.allowLAN = allowLAN
        status = enabled ? "Listening · \(allowLAN ? "LAN" : "127.0.0.1"):\(port) UDP" : "Disabled"
        let prefs = UserDefaults.standard
        prefs.set(enabled, forKey: "sculpt.osc.enabled"); prefs.set(port, forKey: "sculpt.osc.port"); prefs.set(allowLAN, forKey: "sculpt.osc.lan")
    }
    private func receive(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 65536)
        // Bound the work in each dispatch and reject bursts before parsing.
        for _ in 0..<32 {
            var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &bytes, bytes.count, 0, $0, &size)
            } }
            if count < 0 { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - windowStart >= 1 { windowStart = now; windowCount = 0; commandCount = 0 }
            windowCount += 1
            guard windowCount <= 200 else { rejected += 1; continue }
            do {
                let commands = try OSCControlPacket.decode(Data(bytes.prefix(count)))
                guard commandCount + commands.count <= 200 else { rejected += 1; continue }
                commandCount += commands.count
                for command in commands {
                    if let reply = handle?(command) {
                        let packet = OSCControlPacket.stringMessage(address: command == .status ? "/sculpt/status" : "/sculpt/error", value: reply)
                        packet.withUnsafeBytes { data in
                            withUnsafePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                _ = sendto(fd, data.baseAddress, data.count, 0, $0, size)
                            } }
                        }
                    }
                }
                lastMessage = commands.isEmpty ? "Button release ignored" : String(describing: commands.last!)
            } catch { rejected += 1; lastMessage = "Rejected OSC packet" }
        }
    }
}

struct OSCControlSettings: View {
    @EnvironmentObject private var osc: OSCControl
    @EnvironmentObject private var store: ShowStore
    @State private var enabled = false
    @State private var lan = false
    @State private var port = "53000"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable OSC control", isOn: $enabled)
            HStack { Text("UDP port"); TextField("53000", text: $port).frame(width: 90); Toggle("Allow LAN controllers", isOn: $lan) }
            Text("Localhost by default. LAN control accepts commands from devices on the connected network.").font(.caption).foregroundStyle(.secondary)
            Button("Apply") { osc.configure(enabled: enabled, port: Int(port) ?? 0, allowLAN: lan) }
            Text(osc.status).foregroundStyle(osc.enabled ? .green : .secondary)
            Text(osc.lastMessage).font(.caption).lineLimit(2)
            Text("Rejected packets: \(osc.rejected)").font(.caption)
            Divider()
            Text("/sculpt/go · /sculpt/stopAll · /sculpt/pauseAll · /sculpt/resumeAll · /sculpt/fadeAll\n/sculpt/next · /sculpt/previous · /sculpt/nextList\n/sculpt/status → JSON reply to sender").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("Cue: /sculpt/cue/UUID/fire | stop | pause | resume | fade | select | loop\nList: /sculpt/list/UUID/play | stop | fade").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if let cue = store.selectedCue { Text("Selected cue: \(cue.id.uuidString)").font(.caption).textSelection(.enabled) }
            if let id = store.selectedListID { Text("Selected list: \(id.uuidString)").font(.caption).textSelection(.enabled) }
            Text("Triggers: no arguments, or 1 (int/float/bool); 0 ignores release. Loop requires 0/1. Literal addresses and immediate bundles only; future timetags and wildcards are rejected. Settings belong to this Mac.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .onAppear { enabled = osc.enabled; lan = osc.allowLAN; port = String(osc.port) }
    }
}

extension ShowStore {
    func performOSC(_ command: OSCControlPacket.Command, using playback: PlaybackEngine) -> String? {
        if command == .status {
            let active: [[String: Any]] = playback.snapshots.map { id, state in
                ["id": id.uuidString, "state": state.phase.rawValue, "elapsed": state.elapsed, "duration": state.duration]
            }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            let state: [String: Any] = ["show": show.name, "selectedCue": selectedCueID?.uuidString ?? "",
                "selectedList": selectedListID?.uuidString ?? "", "active": active, "audioReady": playback.projectAudioReady]
            return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        guard !isLoadingProject else { return "Project is loading" }
        switch command {
        case .status: break
        case .global(let action):
            switch action {
            case "go": fireSelected(using: playback)
            case "stopAll": stopAll(using: playback)
            case "pauseAll":
                for (id, state) in playback.snapshots where state.phase == .playing { playback.pause(id) }
            case "resumeAll":
                for (id, state) in playback.snapshots where state.phase == .paused { playback.togglePause(id) }
            case "fadeAll": fadeAll(using: playback)
            case "next": if let id = selectedListID { selectNext(in: id) }
            case "previous": if let id = selectedListID { selectPrevious(in: id) }
            case "nextList": selectNextList()
            default: break
            }
        case .list(let id, let action):
            guard show.cueLists.contains(where: { $0.id == id }) else { return "Unknown cue list ID" }
            switch action {
            case "play": playList(id, using: playback)
            case "stop": stopList(id, using: playback)
            case "fade": fadeList(id, using: playback)
            default: break
            }
        case .cue(let id, let action, let enabled):
            guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == id }) }), let cue = show.cue(id) else { return "Unknown cue ID" }
            switch action {
            case "fire": if !playback.play(cue, restartPaused: true) { return playback.errorMessage ?? "Cue cannot start" }
            case "stop": playback.stop(id)
            case "pause": playback.pause(id)
            case "resume": if playback.snapshots[id]?.phase == .paused { playback.togglePause(id) }
            case "fade": playback.fadeOut(cue)
            case "select": select(id, in: list.id)
            case "loop": if let enabled { setLoop(id, in: list.id, to: enabled); playback.setLoop(enabled, for: id) }
            default: break
            }
        }
        return nil
    }
}
