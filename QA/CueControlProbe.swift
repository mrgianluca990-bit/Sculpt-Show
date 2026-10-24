import AppKit
import CoreMIDI
import Darwin
import SculptShowCore
@testable import SculptShowApp

final class Packets: @unchecked Sendable {
    let lock = NSLock(); private var storage: [[UInt8]] = []
    func add(_ p: [[UInt8]]) { lock.lock(); storage += p; lock.unlock() }
    var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return storage }
}
@main struct CueControlProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        func require(_ b: Bool, _ m: String) { if !b { fatalError(m) }; print("PASS · \(m)") }
        func wait() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        let midi = MIDIControl(); let store = ShowStore(); let playback = PlaybackEngine()
        var cue = Cue(name: "Incoming LTC", fadeOutSeconds: 0, fadeInSeconds: 0, durationSeconds: 5)
        cue.triggers.timecode = .init(address: "01:00:00:00", rate: .fps25)
        var second = Cue(name: "Incoming MIDI", fadeOutSeconds: 0, fadeInSeconds: 0, durationSeconds: 5)
        second.triggers.midi = .init(channel: 2, status: 0x90, number: 65)
        var third = Cue(name: "Incoming OSC", fadeOutSeconds: 0, fadeInSeconds: 0, durationSeconds: 5)
        third.triggers.oscAlias = "/sculpt/trigger/probe"
        var videoCue = Cue(name:"Transform"); videoCue.video = CueVideo(sourcePath:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("still.png").path,duration:1); videoCue.video?.isImage = true; videoCue.video?.audioPrepared = true
        var model = Show(); model.cueLists[0].cues = [cue,second,third,videoCue]
        let fixture = try ShowProjectPackage.create(model,requestedDocumentURL:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Control-" + UUID().uuidString + ".scshow"))
        require(store.openShow(at:fixture.documentURL),"open cue control fixture")
        for _ in 0..<40 { if !store.isLoadingProject { break }; await wait() }
        let reader = LTCInputReader(); reader.showProvider = { store.show }
        var fired: [UUID] = []
        reader.onCue = { id in fired.append(id); store.fireTriggeredCue(id, using: playback) }
        let before = LTCTimecode(text: "00:59:59:24", rate: .fps25)!, after = LTCTimecode(text: "01:00:00:01", rate: .fps25)!
        reader.accept(before, at: 0); reader.accept(after, at: 0.08)
        require(fired.isEmpty, "LTC unarmed never launches cue")
        reader.triggersArmed = true
        reader.accept(before, at: 1); reader.accept(after, at: 1.08); reader.accept(after, at: 1.1)
        require(fired == [cue.id] && playback.snapshots[cue.id]?.phase == .playing, "LTC crossed address starts actual cue once")
        reader.stop(); require(!reader.triggersArmed, "stop LTC input disarms triggers")
        playback.stopAll()
        var client: MIDIClientRef = 0; var source: MIDIEndpointRef = 0; var destination: MIDIEndpointRef = 0
        require(MIDIClientCreate("Sculpt isolated control QA" as CFString,nil,nil,&client) == noErr, "CoreMIDI QA client")
        defer { MIDIEndpointDispose(source); MIDIEndpointDispose(destination); MIDIClientDispose(client) }
        let packets = Packets()
        require(MIDISourceCreate(client,"Sculpt QA Source" as CFString,&source) == noErr, "virtual MIDI input source")
        require(MIDIDestinationCreateWithBlock(client,"Sculpt QA Destination" as CFString,&destination) { list, _ in packets.add(list.unsafeSequence().map { Array($0.sequence()) }) } == noErr, "virtual MIDI output destination")
        midi.refresh()
        let src = midi.sources.first { $0.endpoint == source }!, dst = midi.destinations.first { $0.endpoint == destination }!
        midi.connect(src.id)
        midi.onCueTrigger = { trigger in guard let id = CueTriggerResolver.matching(in: store.show, midi: trigger) else { return false }; store.fireTriggeredCue(id, using: playback); return true }
        func input(_ bytes: [UInt8]) {
            var list = MIDIPacketList(); withUnsafeMutablePointer(to: &list) { ptr in
                let first = MIDIPacketListInit(ptr); _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(ptr, MemoryLayout<MIDIPacketList>.size, first, 0, bytes.count, $0.baseAddress!) }
                _ = MIDIReceived(source,ptr)
            }
        }
        input([0x92,65,100]); await wait()
        require(playback.snapshots[second.id]?.phase == .playing, "received virtual MIDI Note starts assigned cue")
        let fd = socket(AF_INET,SOCK_DGRAM,0); require(fd >= 0, "UDP output test socket")
        defer { Darwin.close(fd) }
        var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &endpoint) { p in p.withMemoryRebound(to: sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        require(bound == 0, "isolated UDP output capture")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &endpoint) { p in p.withMemoryRebound(to: sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        var oscMessage = CueOSCMessage(); oscMessage.port = Int(UInt16(bigEndian: endpoint.sin_port)); oscMessage.address = "/qa/start"; oscMessage.argument = .string; oscMessage.value = "GO"
        var settings = cue.triggers; settings.midiMessages = [.init(destination: dst.id, status: 0x90, channel: 2, number: 60, value: 100),.init(destination: dst.id,status:0x80,channel:2,number:60,value:0),.init(destination:dst.id,status:0xC0,channel:1,number:8)]; settings.oscMessages = [oscMessage]
        store.setCueTriggers(settings,cueID:cue.id,using:midi)
        playback.onStarted = { id in if let c = store.show.cue(id) { store.sendCueMessages(c,using:midi) } }
        store.fireTriggeredCue(cue.id,using:playback)
        for _ in 0..<20 { if packets.all.flatMap { $0 }.count >= 8 { break }; await wait() }
        require(packets.all.flatMap { $0 } == [0x92,60,100,0x82,60,0,0xc1,8], "cue GO sends Note On/Off and Program Change in order: \(packets.all), \(store.errorMessage ?? "OK")")
        var bytes = [UInt8](repeating:0,count:2048); let n = recv(fd,&bytes,bytes.count,0)
        require(n > 0 && Data(bytes.prefix(n)) == oscMessage.packet, "cue GO sends exact OSC UDP payload")
        playback.pause(cue.id); playback.togglePause(cue.id); await wait()
        require(packets.all.flatMap { $0 }.count == 8 && recv(fd,&bytes,bytes.count,0) < 0, "pause/resume does not resend outputs")
        let osc = OSCControl(); osc.configure(enabled:true,port:53191,allowLAN:false)
        require(osc.enabled, "OSC input receiver starts")
        defer { osc.configure(enabled:false,port:53191,allowLAN:false) }
        osc.handle = { store.performOSC($0,using:playback) }
        var incoming = CueOSCMessage(); incoming.port = 53191; incoming.address = third.triggers.oscAlias
        require(CueOSCOutput.send(incoming) == nil, "OSC incoming test transmitted")
        await wait(); require(playback.snapshots[third.id]?.phase == .playing, "received OSC alias starts assigned cue")
        let unavailable = CueMIDIMessage(destination:Int32.max)
        require(midi.send(unavailable) != nil, "missing MIDI output reports error")
        let list = store.show.cueLists[0].id
        store.setVideoFraming(.stretch,cueID:videoCue.id,in:list); store.setVideoDimensions(width:1.5,height:0.5,cueID:videoCue.id,in:list)
        require(store.show.cue(videoCue.id)?.video?.heightScale == 0.5, "Stretch dimensions independent")
        store.setVideoFraming(.fit,cueID:videoCue.id,in:list); store.setVideoDimensions(width:1.2,cueID:videoCue.id,in:list)
        require(store.show.cue(videoCue.id)?.video?.heightScale == 1.2, "Keep proportions dimensions linked")
        store.setVideoFraming(.fill,cueID:videoCue.id,in:list); store.setVideoDimensions(width:0.5,height:0.7,cueID:videoCue.id,in:list)
        let movie = store.show.cue(videoCue.id)!.video!, frame = movie.contentFrame(source:CGSize(width:1920,height:1080),in:CGRect(x:0,y:0,width:1920,height:1080))
        require(abs(frame.width/frame.height - 16.0/9) < 0.0001 && movie.viewportFrame(in:CGRect(x:0,y:0,width:1920,height:1080)).width == 960, "Crop resizes mask without distorting source")
        store.setVideoPosition(x:0.0001,y:-0.0001,cueID:videoCue.id,in:list)
        require(store.show.cue(videoCue.id)?.video?.offsetX == 0.0001, "0.01 percent positioning precision")
        let saved = try JSONEncoder().encode(store.show), reopened = try JSONDecoder().decode(Show.self,from:saved)
        require(reopened == store.show, "all incoming/outgoing controls and transforms roundtrip")
        playback.stopAll(); midi.disconnect(); print("ALL CUE CONTROL CHECKS PASSED")
    }
}
