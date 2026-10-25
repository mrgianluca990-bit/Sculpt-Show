#!/usr/bin/env python3
"""Run after swift build --scratch-path <build>; requires tone.mp4/still.png fixtures."""
import pathlib, subprocess, sys
build = pathlib.Path(sys.argv[1]) / 'arm64-apple-macosx/debug'
source = pathlib.Path(__file__).with_name('CueRangeProbe.swift')
objects = list((build / 'SculptShowCore.build').glob('*.swift.o'))
objects += [p for p in (build / 'SculptShowApp.build').glob('*.swift.o') if p.name != 'SculptShowApp.swift.o']
objects += list((build / 'SculptLTCCore.build').rglob('*.c.o'))
output = pathlib.Path(sys.argv[2]) / 'cue-range-probe'
subprocess.run(['swiftc', '-parse-as-library', '-I', str(build / 'Modules'), '-I', str(build / 'SculptLTCCore.build'), str(source), *map(str, objects), '-o', str(output)], check=True)
subprocess.run([str(output), sys.argv[2]], check=True)
