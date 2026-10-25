#!/usr/bin/env python3
"""Run after swift build --scratch-path <build>; requires tone.mp4/still.png fixtures."""
import pathlib, subprocess, sys, json, uuid
fixtures = pathlib.Path(sys.argv[2])
cues = []
for index in range(4):
    cue = dict(id=str(uuid.uuid4()), name=f"Inspector test {index+1}", gain=1, fadeOutSeconds=0, enabled=True, durationMode="fixed", durationSeconds=2, loop=index==0, elements=[])
    if index == 0:
        cue["elements"] = [dict(id=str(uuid.uuid4()), kind="audio", name=f"Stem {j+1}", sourcePath=str(fixtures/"quiet.wav"), outputStartChannel=1) for j in range(7)]
    cues.append(cue)
show = dict(name="Inspector RC2 QA", formatVersion=1, sampleRate=48000, cueLists=[dict(id=str(uuid.uuid4()), name="Cue List 1", cues=cues)])
(fixtures/"visual-release.scshow").write_text(json.dumps(show))
build = pathlib.Path(sys.argv[1]) / 'arm64-apple-macosx/debug'
source = pathlib.Path(__file__).with_name('VisualReleaseProbe.swift')
objects = list((build / 'SculptShowCore.build').glob('*.swift.o'))
objects += [p for p in (build / 'SculptShowApp.build').glob('*.swift.o') if p.name != 'SculptShowApp.swift.o']
objects += list((build / 'SculptLTCCore.build').rglob('*.c.o'))
output = pathlib.Path(sys.argv[2]) / 'visual-release-probe'
subprocess.run(['swiftc', '-parse-as-library', '-I', str(build / 'Modules'), '-I', str(build / 'SculptLTCCore.build'), str(source), *map(str, objects), '-o', str(output)], check=True)
subprocess.run([str(output), *sys.argv[2:]], check=True)
