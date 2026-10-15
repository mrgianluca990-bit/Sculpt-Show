# Sculpt Show 0.13.0 — Named Waveform Markers, Local Cue Playback, MTC Generator

**Built on the user's hardware-tested 0.12.0 show engine.** Routing, cue marker Rules, mixer, preflight, MIDI Learn, cue storage, and audio devices are intentionally untouched.

## Changes

### Marker labels
- Each marker is displayed by name on the waveform marker ruler **and** at its position on the audio lanes.
- Marker click also sets the non-destructive local audition cursor. Marker rename, precise HH:MM:SS:MMM, and Interaction Rules remain in the Inspector.
- Existing draggable waveform marker positions retain the 0.12.0 single-commit-on-release behavior.

### Local PLAY vs Global GO
- Click in the audio waveform to set the **blue audition cursor**, even before a cue is running. If the cue is active, a click also seeks as before.
- The cue row's ▶ PLAY and the waveform's PLAY CUE launch the corresponding cue at the blue cursor.
- ZERO resets the local audition position, which is displayed as HH:MM:SS:MMM and lives only in memory.
- **Global GO, list playback, next-cue Rules and triggers explicitly continue using position ZERO**, independent of the blue audition cursor.
- Audio timeline and stored media are never trimmed; no additional stem offsets are added to the .scshow schema.

### MTC GENERATOR — Phase 1
- The lower **TIMECODE** dock contains separate READER and GENERATOR tabs. They don't replace the Mixer or Waveform docking controls.
- Manual generator sends MIDI Time Code quarter-frame messages through a chosen CoreMIDI destination at 24, 25, 29.97 drop-frame, or 30 fps.
- User enters HH:MM:SS:FF (frames, not milliseconds); LOCATE transmits universal real-time MIDI Full Frame SysEx.
- START first sends Full Frame Locate, then streams 8 QF pieces per two video frames on a dedicated queue. STOP cancels the output timer; preferred MIDI destination is remembered locally.
- A coherent 8-nibble frame is kept throughout each group, avoiding mixed fields at second/minute transitions. Pure Swift encoder tests validate QF, DF and Full Frame data.
- **Not LTC, not sample-accurate, not audio-clock-locked and not yet tied to individual cue timecode elements.** This is a functional first-stage MIDI output generator. Synchronization/chase will follow subsequent hardware tests.

## macOS acceptance checklist
1. Open a cue containing stereo audio; select WAVEFORMS; marker names should appear on waveform/ruler, remain draggable, and still have Rules in Inspector.
2. With that cue STOPPED, click at e.g. 00:00:10.000. Confirm cyan cursor and PLAY FROM. Press its row ▶ PLAY: audio should start at 10 s. Stop; press GLOBAL GO: audio should start from zero.
3. Test clicking an existing marker, then ▶ PLAY. Check previous/next and ZERO.
4. Open TIMECODE, choose GENERATOR, select an actual CoreMIDI destination (IAC is useful for testing). LOCATE should send Full Frame; START should stream QF at selected fps; STOP must cease transmission.
5. Check audio playback, routing changes, marker Rules and mixer continue uninterrupted while MTC generator is operating.

## Verification status
- Linux `swift test`: 103 pure Core tests passed, including four MTC encoder tests.
- `swiftc -frontend -parse` completed on the Swift sources.
- **The new 0.13.0 app target has not yet been compiled on macOS.** GitHub Actions and subsequent Mac hardware validation are required.
