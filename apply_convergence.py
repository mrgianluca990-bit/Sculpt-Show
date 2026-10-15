#!/usr/bin/env python3
"""Apply Sculpt Cue Native mixer phase 1 to an EXACT compatible Sculpt Show 0.9.0 checkout.
Fail closed on changed baseline files. Never patches a Show project silently.
"""
from __future__ import annotations
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BLOBS = {
    'Sources/SculptShowApp/RoutedAudioEngine.swift': 'ad2bb2455befef7e8186c678ddbc92421914aff2',
    'Sources/SculptShowApp/PlaybackEngine.swift': 'c9d6ed2ecdf90a787bad98d9d30c5d2bb669d2b9',
    'Sources/SculptShowApp/WorkspaceView.swift': '195765f6436c3a78a7487dbdd50dc9cb8eb78fb8',
}
ADDITIONS = [
    'Sources/SculptShowCore/OutputMuteSoloState.swift',
    'Sources/SculptShowApp/ShowOutputMixerView.swift',
    'Tests/SculptShowCoreTests/OutputMuteSoloTests.swift',
]

def once(text: str, target: str, replacement: str, name: str) -> str:
    count = text.count(target)
    if count != 1:
        raise ValueError(f'{name}: attesa 1 occorrenza, trovate {count}. Versione Show non compatibile.')
    return text.replace(target, replacement, 1)


def patch_engine(s: str) -> str:
    s = once(s, '    private var cueToVoices: [UUID: [Int]] = [:]\n',
        '    private var cueToVoices: [UUID: [Int]] = [:]\n'
        '    private(set) var outputControls = OutputMuteSoloState(channelCount: 0)\n', 'RoutedAudioEngine state')
    s = once(s, '        selectedDevice = device\n',
        '        selectedDevice = device\n'
        '        // Live output control is deliberately reset on hardware activation.\n'
        '        outputControls = OutputMuteSoloState(channelCount: device.channels)\n', 'RoutedAudioEngine configure')
    s = once(s, '        selectedDevice = nil\n',
        '        selectedDevice = nil\n'
        '        outputControls = OutputMuteSoloState(channelCount: 0)\n', 'RoutedAudioEngine teardown')
    marker = '    private func require(_ status: OSStatus, _ label: String) throws {\n'
    method = '''    /// MUTE/SOLO copied from the verified Sculpt Cue Native 0.5.2 behavior.
    /// Only OUTPUT gains change: never stem crosspoints, voice scheduling or transport.
    /// The previous output state is restored if CoreAudio rejects any channel.
    func applyOutputControls(_ next: OutputMuteSoloState) throws {
        guard isReady, let matrix, let device = selectedDevice else {
            throw RoutingError.engineNotReady
        }
        guard next.channelCount == device.channels else {
            throw RoutingError.noDeviceOutput
        }
        let previous = outputControls
        var changed: [Int] = []
        for channel in 1...device.channels {
            let target = next.outputGain(channel)
            guard previous.outputGain(channel) != target else { continue }
            let status = AudioUnitSetParameter(matrix.audioUnit, kMatrixMixerParam_Volume,
                kAudioUnitScope_Output, UInt32(channel - 1), target, 0)
            if status != noErr {
                for undo in (changed + [channel]).reversed() {
                    _ = AudioUnitSetParameter(matrix.audioUnit, kMatrixMixerParam_Volume,
                        kAudioUnitScope_Output, UInt32(undo - 1), previous.outputGain(undo), 0)
                }
                throw RoutingError.cannotConfigure("MUTE/SOLO OUT \\(channel)", status)
            }
            changed.append(channel)
        }
        outputControls = next
    }

'''
    return once(s, marker, method+marker, 'RoutedAudioEngine applyOutputControls')


def patch_playback(s: str) -> str:
    anchor='    @Published private(set) var routingDeviceID: AudioDeviceID?\n'
    s=once(s, anchor, anchor+'    @Published private(set) var outputControls = OutputMuteSoloState(channelCount: 0)\n', 'PlaybackEngine state')
    marker='    /// Reconfigure only while silent, and never silently route to the wrong device.\n'
    funcs = '''    /// Apply hardware output controls without changing any cue/Rules/show data.
    private func updateOutputControls(_ newState: OutputMuteSoloState) {
        guard routingEnabled else { return }
        do {
            try routedAudio.applyOutputControls(newState)
            outputControls = newState
        } catch {
            errorMessage = "Cannot update output MUTE/SOLO: \\(error.localizedDescription)"
        }
    }

    func toggleOutputMute(_ channel: Int) {
        guard outputControls.isValid(channel) else { return }
        var next = outputControls
        next.toggleMute(channel)
        updateOutputControls(next)
    }

    func toggleOutputSolo(_ channel: Int) {
        guard outputControls.isValid(channel) else { return }
        var next = outputControls
        next.toggleSolo(channel)
        updateOutputControls(next)
    }

    func resetOutputMuteSolo() {
        guard routingEnabled else { return }
        var next = outputControls
        next.clear()
        updateOutputControls(next)
    }

'''
    s=once(s,marker,funcs+marker,'PlaybackEngine functions')
    s=once(s,'        routingDeviceID = nil\n',
        '        routingDeviceID = nil\n'
        '        outputControls = OutputMuteSoloState(channelCount: 0)\n', 'PlaybackEngine teardown')
    s=once(s,'            routingDeviceID = device.id\n',
        '            routingDeviceID = device.id\n'
        '            outputControls = routedAudio.outputControls\n', 'PlaybackEngine hardware configure')
    return s


def patch_workspace(s: str) -> str:
    s=once(s,'    @State private var showingRouting = false\n',
        '    @State private var showingRouting = false\n'
        '    @State private var showingOutputMixer = false\n', 'WorkspaceView state')
    routing_sheet = '''        .sheet(isPresented: $showingRouting) {
            OutputRoutingView().environmentObject(playback)
        }
'''
    s=once(s,routing_sheet,routing_sheet+
        '''        .sheet(isPresented: $showingOutputMixer) {
            ShowOutputMixerView().environmentObject(playback)
        }
''', 'WorkspaceView sheet')
    anchor='                .help("Choose Core Audio device and enable per-file physical channel routing")\n'
    s=once(s,anchor,anchor+
        '''                Button { showingOutputMixer = true } label: {
                    Label("OUTPUT MIXER", systemImage: "slider.vertical.3")
                }
                .disabled(!playback.routingEnabled)
                .help("Sculpt Cue Native mixer · 64 output MUTE/SOLO controls")
''', 'WorkspaceView toolbar')
    return s


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit('Uso: python3 apply_convergence.py /percorso/Sculpt-Show')
    show = Path(sys.argv[1]).resolve()
    if not (show/'Package.swift').is_file():
        sys.exit(f'Non è una cartella Sculpt-Show: {show}')
    if any((show/p).exists() for p in ADDITIONS):
        sys.exit('Integrazione già presente: nessun file modificato.')
    original = {}
    for path, expected in BLOBS.items():
        file = show/path
        if not file.exists(): sys.exit(f'Manca {file}')
        actual = subprocess.run(['git', 'hash-object', str(file)], capture_output=True, text=True, check=True).stdout.strip()
        if actual != expected:
            sys.exit(f'File differente da Sculpt Show 0.9.0 verificato: {path}\n'
                     f'atteso {expected}, trovato {actual}. Nessun file modificato.')
        original[path] = file.read_text(encoding='utf-8')
    try:
        modifications = {
            'Sources/SculptShowApp/RoutedAudioEngine.swift': patch_engine(original['Sources/SculptShowApp/RoutedAudioEngine.swift']),
            'Sources/SculptShowApp/PlaybackEngine.swift': patch_playback(original['Sources/SculptShowApp/PlaybackEngine.swift']),
            'Sources/SculptShowApp/WorkspaceView.swift': patch_workspace(original['Sources/SculptShowApp/WorkspaceView.swift']),
        }
    except ValueError as error:
        sys.exit(str(error))
    for p in ADDITIONS:
        if not (ROOT/p).is_file(): sys.exit(f'Manca sorgente di integrazione: {p}')
    # All validation above is completed before changing files.
    for p, content in modifications.items():
        (show/p).write_text(content, encoding='utf-8')
    for p in ADDITIONS:
        (show/p).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/p, show/p)
    print('OK: Sculpt Cue Native -> Sculpt Show: output MUTE/SOLO 64ch, banchi, nomi, test.')
    print('Inalterati: Cue/Rules/trasporto/.scshow, routing stem e MatrixMixer crosspoints.')

if __name__ == '__main__': main()
