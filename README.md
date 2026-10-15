# Sculpt Show 0.11.0 — Cue Native convergence bundle

This release consolidates the functional overlap between the tested Sculpt Cue Native
0.5.0/0.5.2 workflow and Sculpt Show 0.10.5. It is **one cumulative update**,
not one build per small UI change.

## Included in 0.11.0

- **Multitrack waveform dock:** one source lane per mono/stereo element, left and right
  separately; decoded off-main-thread from AVAudioFile and cached in memory.
  Zoom 1–12x, live cue playhead, overlay of persistent cue markers, click-to-seek
  for an **already active** cue, Add Marker at Playhead.
- **Dock layout:** Mixer, Waveforms and MTC Reader can be displayed independently,
  or together. Mixer and Waveforms share a resizable vertical split on the left;
  MTC may dock on the right.
- **Show Preflight:** checks media existence/decodability, source channel count,
  routing validity, per-cue voice budget (16), marker reachability. Reports blocking
  and warning conditions and exports a JSON audit to disk.
- **Relink:** per-stem audio file picker; bulk missing-media relink from a selected
  directory, by *exact, unambiguous filename*. Preserves element IDs, output,
  audio levels, cue/marker Rules; no stop/restart of active cues.
- **Output test tone:** explicit 440 Hz sine, −30 dBFS peak, mono to a selectable
  hardware OUT in File > Audio/MIDI Setup. Only when all cue transports are idle;
  GO forcibly stops it. Uses an existing free MatrixMixer player voice, no
  additional AVAudioEngine graph or bus.
- **Existing 0.10.5 features preserved:** routed cue engine 64ch/16 voices,
  live stem repatch, mixer Peak/RMS/Peak Hold, CLIP, mute/solo/labels, MTC input,
  marker Rules, .scshow compatibility, custom macOS icon, and native resizeable dock.

## Deliberately NOT included

- A second cue/audio routing engine. Routing already works in Sculpt Show.
- Per-stem audio IN/OUT and offset (removed from aligned-stem workflow by request).
- The experimental stereo correlation meter rejected during Cue development.
- LTC decode/output and sample-accurate timecode chase (not present in this codebase).
- Undo/DAW editing or Snapshots from another product; not proven native Cue
  features and not safe to claim as already migrated.

## Verification

- 97/97 Swift core regression tests pass on Linux.
- All Swift source files parse successfully with swiftc -frontend -parse.
- macOS SwiftUI, AVFAudio and physical interface behavior must be compiled/tested
  in GitHub Actions and on a real Mac. This package is **not a certified live build**.

## Acceptance test on macOS

1. Confirm Sculpt Show 0.11.0 opens existing .scshow with all markers/Rules.
2. Select multitrack cue > WAVEFORMS. Mono vs stereo lanes render correctly;
   markers and running playhead track, Zoom and seeking work.
3. Show Mixer and Waveforms together; toggle MTC on/off. No transport reset.
4. PRE-FLIGHT: rescan a valid show, break a media path on a duplicate project,
   use Locate/Relink Folder and Export JSON, reopen project and verify cue identity.
5. File > Audio/MIDI Setup: with transport idle, PLAY TEST to OUT 1 or 3,
   check exactly that physical output, STOP TEST. Test muted/soloed outputs.
6. Start a cue: test tone must be off; switch routing live and use M/S without
   interrupting audio or marker Rules. Reopen project.

Do not perform first-time test tone or graph tests during a live performance.
