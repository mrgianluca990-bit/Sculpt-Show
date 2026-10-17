#!/usr/bin/env python3
"""Sculpt Show Core22: reliable multi-stem + markers handoff, shared CoreAudio UID.
This changes only Show source files. The CLI is INSIDE Sculpt DAW.app.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[1]

def patch(rel,before,after,tag):
    p=root/rel;s=p.read_text(encoding='utf8')
    if tag in s: print('ALREADY',tag);return
    n=s.count(before)
    if n!=1:raise RuntimeError(f'{rel}: {tag}: expected one anchor, found {n}')
    p.write_text(s.replace(before,after,1),encoding='utf8')
    print('PATCH',tag)

bridge='Sources/SculptShowApp/SculptDAWLaunchBridge.swift'
patch(bridge,
'''        var cli = locateCLI(near: app)
        // DAW's standalone audio-arguments mode has no explicit alignment
        // guarantees between consecutive imports. For multi-stem cue editing,
        // insist on the CLI's single import command with `at = 0`.
        if cli == nil && manifest.stems.count > 1 {
            cli = try chooseCLI(required: true)
        }''',
'''        // SCULPT_CORE22_REQUIRE_CLI: NEVER silently open only audio: that loses
        // Cue Markers, physical I/O assignment and sample-aligned multitrack.
        var cli = locateCLI(near: app)
        if cli == nil { cli = try chooseCLI(required: true) }
        guard cli != nil else { throw LaunchError.cliRequired }''',
'SCULPT_CORE22_REQUIRE_CLI')
patch(bridge,
'''        } else {
            // The GUI's main.rs already recognizes audio files as launch args;
            // each is imported to a new track at the session's initial 00:00.
            // No CLI or DAW source patch is necessary to begin editing.
            let paths = preparation.manifest.stems.map(\\.sourcePath)
            openDAW(preparation.dawApplication, arguments: paths) { result in
                switch result {
                case .success:
                    report(.success("Sculpt DAW opened with \\(paths.count) audio stem(s) at project start. Use File > Save Session As in DAW. For marker import and saving the physical I/O mapping, authorize and select soundcraft-cli (included with the DAW download). Actual direct hardware playback routing still requires an update in Sculpt DAW."))
                case .failure(let error): report(.failure(error))
                }
            }
        }''',
'''        } else {
            // SCULPT_CORE22_NO_PARTIAL_TRANSFER: a partial handoff is failure.
            report(.failure(LaunchError.cliRequired))
        }''','SCULPT_CORE22_NO_PARTIAL_TRANSFER')
patch(bridge,
'''            app.deletingLastPathComponent().appendingPathComponent("soundcraft-cli").path,''',
'''            // SCULPT_CORE22_FIND_EMBEDDED_CLI: packaged CLI inside signed .app.
            app.appendingPathComponent("Contents/Helpers/soundcraft-cli").path,
            app.deletingLastPathComponent().appendingPathComponent("soundcraft-cli").path,''',
'SCULPT_CORE22_FIND_EMBEDDED_CLI')
patch(bridge,
'''                  (1...2).contains(Int(file.processingFormat.channelCount)),''',
'''                  (1...2).contains(Int(file.processingFormat.channelCount)),
                  // SCULPT_CORE22_MULTISTEM: each mono/stereo stem is a separate
                  // time-aligned DAW track; arbitrary multichannel files need a
                  // dedicated channel-split exporter before claiming support.''',
'SCULPT_CORE22_MULTISTEM')
patch(bridge,
'''        panel.message = "Select soundcraft-cli from the Sculpt DAW download. It creates and saves a native session before the DAW opens."''',
'''        panel.message = "Select Sculpt DAW.app/Contents/Helpers/soundcraft-cli. Without it no cue audio or markers will be transferred." // SCULPT_CORE22_CLI_HELP''',
'SCULPT_CORE22_CLI_HELP')
patch(bridge,
'''            let workspace = preparation.workspace
            // Never block SwiftUI with a CLI import of long audio files.''',
'''            let workspace = preparation.workspace
            // SCULPT_CORE22_MARKER_EXPECTATIONS: require complete cue payload.
            // soundcraft-cli script fails on a rejected markers.add command;
            // the text manifest still preserves marker UUIDs for round-trips.
            let expectedMarkerCount = preparation.manifest.markers.count
            let expectedStemCount = preparation.manifest.stems.count
            // Never block SwiftUI with a CLI import of long audio files.''',
'SCULPT_CORE22_MARKER_EXPECTATIONS')
patch(bridge,
'''                    try await runImport(executable: cli, script: scriptPath, expectedSession: session)
                    openDAW(application, arguments: [session.path])''',
'''                    try await runImport(executable: cli, script: scriptPath, expectedSession: session)
                    // SCULPT_CORE22_VERIFY_SCRIPT: all stems and markers MUST be
                    // emitted to CLI; a one-file fallback is never used.
                    let generated = try String(contentsOf: preparation.script, encoding: .utf8)
                    let markers = generated.components(separatedBy: "\\n").filter { $0.hasPrefix("markers.add ") }.count
                    let stems = generated.components(separatedBy: "\\n").filter { $0.hasPrefix("file.import_audio ") }.count
                    guard markers == expectedMarkerCount, stems == expectedStemCount else {
                        throw LaunchError.importFailed("Bridge manifest incomplete: \\(stems)/\\(expectedStemCount) stems and \\(markers)/\\(expectedMarkerCount) markers")
                    }
                    openDAW(application, arguments: [session.path])''',
'SCULPT_CORE22_VERIFY_SCRIPT')

# Optional access to the complete bridge manifest: the DAW CLI script includes
# markers.add and view.ruler, so preserve name, ordering and absolute position.
core='Sources/SculptShowCore/SculptBridge.swift'
patch(core,
'''        for marker in manifest.markers.sorted(by: { $0.seconds < $1.seconds }) {''',
'''        // SCULPT_CORE22_MARKER_ROUNDTRIP: original marker names and seconds.
        for marker in manifest.markers.sorted(by: { $0.seconds < $1.seconds }) {''',
'SCULPT_CORE22_MARKER_ROUNDTRIP')

# Persistent shared physical interface. This file is intentionally neither the
# cue/session document nor a replacement for Show's existing preferences.
shared=root/'Sources/SculptShowApp/SculptSharedAudioSettings.swift'
shared.write_text('''import Foundation

/// SCULPT_CORE22_SHARED_AUDIO_PROFILE: shared with Sculpt DAW on this Mac.
/// A UID is stable across restarts; CoreAudio numeric IDs are not.
enum SculptSharedAudioSettings {
    struct Profile {
        var uid: String = ""
        var name: String = ""
        var input: String = ""
        var rate: Int = 0
        var buffer: Int = 0
    }
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sculpt/AudioSettings.conf")
    }
    static func read() -> Profile {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              text.hasPrefix("SCULPT_AUDIO_V1\\n") else { return Profile() }
        var p = Profile()
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1]); switch String(parts[0]) {
            case "uid": p.uid = value
            case "name": p.name = value
            case "input": p.input = value
            case "rate": p.rate = Int(value) ?? 0
            case "buffer": p.buffer = Int(value) ?? 0
            default: break
            }
        }
        return p
    }
    static func write(_ p: Profile) throws {
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\r", with: " ") }
        let contents = "SCULPT_AUDIO_V1\\nuid=\\(clean(p.uid))\\nname=\\(clean(p.name))\\ninput=\\(clean(p.input))\\nrate=\\(p.rate)\\nbuffer=\\(p.buffer)\\n"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}
''',encoding='utf8')
play='Sources/SculptShowApp/PlaybackEngine.swift'
patch(play,
'''        if let uid = UserDefaults.standard.string(forKey: preferredOutputUIDKey), !uid.isEmpty {''',
'''        // SCULPT_CORE22_SHOW_SAME_DEVICE: DAW and Show read the same CoreAudio
        // selection. A missing UID is resolved only through a unique device name.
        let shared = SculptSharedAudioSettings.read()
        if !shared.uid.isEmpty || !shared.name.isEmpty {
            let matches = routingDevices.filter { (!shared.uid.isEmpty && $0.uid == shared.uid) ||
                (shared.uid.isEmpty && $0.name == shared.name) }
            guard matches.count == 1, let chosen = matches.first else {
                errorMessage = "Shared Sculpt audio interface is unavailable or ambiguous. Open Audio/MIDI Setup and select it."
                return
            }
            await configureRouting(deviceID: chosen.id)
            return
        }
        if let uid = UserDefaults.standard.string(forKey: preferredOutputUIDKey), !uid.isEmpty {''',
'SCULPT_CORE22_SHOW_SAME_DEVICE')
patch(play,
'''            if !device.uid.isEmpty {
                UserDefaults.standard.set(device.uid, forKey: preferredOutputUIDKey)
            }''',
'''            if !device.uid.isEmpty {
                UserDefaults.standard.set(device.uid, forKey: preferredOutputUIDKey)
            }
            // SCULPT_CORE22_WRITE_SHARED_DEVICE: persist exactly the selected
            // hardware UID/name. Preserve rate and buffer desired by DAW.
            var shared = SculptSharedAudioSettings.read()
            shared.uid = device.uid
            shared.name = device.name
            do { try SculptSharedAudioSettings.write(shared) }
            catch { errorMessage = "Could not share CoreAudio selection with Sculpt DAW: \\(error.localizedDescription)" }''',
'SCULPT_CORE22_WRITE_SHARED_DEVICE')

# Verify imports without depending on AppKit during unit-only SwiftPM builds.
for f,fragments in {
 bridge:['SCULPT_CORE22_REQUIRE_CLI','SCULPT_CORE22_FIND_EMBEDDED_CLI','SCULPT_CORE22_VERIFY_SCRIPT'],
 play:['SCULPT_CORE22_SHOW_SAME_DEVICE','SCULPT_CORE22_WRITE_SHARED_DEVICE'],
 core:['SCULPT_CORE22_MARKER_ROUNDTRIP']
}.items():
    data=(root/f).read_text(encoding='utf8')
    for fragment in fragments: assert fragment in data,(f,fragment)
print('SCULPT SHOW CORE22: complete CLI-only bridge, embedded CLI, marker checks, same UID profile source guards OK')
