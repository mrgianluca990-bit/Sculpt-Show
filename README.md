# Sculpt Show 0.8.2 — Cue Duration Enter + Element Mixer

Incremental update based on working 0.8.1 macOS build. All existing cue-list, rules, MIDI, synchronized playback, drag-and-drop and global transport functionality is preserved.

## Changes

- **Cue duration**: press **Return / Enter** in the `HH:MM:SS:MMM` field to confirm and leave editing; no `Set` button. Invalid values show validation text and remain editable.
- **New: per-element mixer**: every **audio element** inside a cue has a level fader (0–100%, 100% = unity) and a Mute switch. The cue's own gain control and fade/dim behavior remain independent, stacking with these controls.
- You can adjust audio-element level/mute while the cue is playing, without stopping or rescheduling audio.
- The independent audio-element settings persist in `.scshow` projects and survive duplicate, drag-and-drop, save/reopen.
- Older `.scshow` projects load with each element at unity (100%) and not muted by default.
- **MIDI remains unchanged**, awaiting hardware testing.

## Validation

- `swift test --disable-sandbox --jobs 2`: 60 tests passed (including five new ElementMix tests).
- `swiftc -frontend -parse`: all application, core and test Swift files passed syntax check.
- **macOS build not yet verified**. Run the existing GitHub Actions workflow after uploading.

## Known audio engine limitations

Sculpt Show currently uses multiple synchronized AVAudioPlayer instances, not a single sample-accurate multichannel AVAudioEngine graph. Per-element faders and mute work on the existing synchronized player objects; this patch does not add audio-output routing, truly gapless loops or sample-accurate trim points.
