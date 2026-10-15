# Sculpt Show 0.14.1 — LTC HOLD, trims, Delete cue

Release cumulative based on **0.14.0**, verified working on macOS by the operator.

- **Pause/HOLD:** the GENERATED LTC display freezes at the paused cue position; audio LTC goes silent during pause (safer for external LTC chase devices) and restarts at the held address when playback resumes. A seek while paused updates the held display without outputting LTC. STOP clears it.
- **TC OFFSET:** signed `±HH:MM:SS:FF` frame address correction per timecode element (does not change musical audio or cue timeline), saved in `.scshow`. Default `+00:00:00:00` on legacy shows.
- **LTC LEVEL TRIM:** `−36…+12 dB` relative to nominal −12 dBFS generated PCM. Adjustable live. Gain is applied with an atomic control **inside the LTC DSP** (no device reconfigure, no music routing changes). A +12 dB trim reaches approximately 0 dBFS and should be used carefully.
- **Delete cue:** select a cue in the list and use the macOS Delete/Backspace command; text editing in the Inspector must remain unaffected. A "Delete Cue" option is also available on the cue context menu. Deletes stop active playback without firing stop rules.
- All new values have safe defaults when opening older shows. Mac-specific key handling and live Core Audio behavior require testing on a Mac.

**Tests on Linux:** 119 Swift/C tests passed; Swift syntax parsing passed. **A GitHub Actions macOS build is still required.**

**Safety:** LTC must be sent only to a dedicated technical output, not to speakers. A paused LTC signal is silent, not an endlessly repeated frame; external readers may lose LOCK but generated timecode holds its last address in Show.

---

# Sculpt Show 0.14.0 — Native LTC audio generation and reception

**Based on Sculpt Show 0.13.0, hardware-tested by the operator.** This is a cumulative native audio/timecode update; the existing multitrack MatrixMixer, live routing, mixer, Rules, marker editing, playback and MTC-controlled transport commands are not rewritten.

## What's new

### PLAY FROM is a real text field
- Enter an exact `HH:MM:SS:MMM` address and press Return or PLAY CUE. Clicking the waveform still sets the local preview cursor.
- Per-cue PLAY begins at that location. **Global GO always starts at zero, including when the selected cue had been paused.**
- The audition cursor is not a destructive trim and isn't persisted to `.scshow`.

### SMPTE LTC audio **per cue**, not CoreMIDI MTC
- Attach **Timecode +** to any cue. In the Inspector configure SMPTE start `HH:MM:SS:FF`, `24 / 25 / 29.97 drop-frame / 30 fps`, independent offset and **explicitly assigned physical LTC OUT**.
- No output is assigned by default. A cue with an enabled LTC element and no safe output assignment is blocked before GO.
- A dedicated **AVAudioSourceNode** joins the existing Core Audio `AVAudioEngine` through an extra bus of the **same** matrix; ordinary audio still has all 16 preexisting stem voices and up to 64 hardware outputs.
- SMPTE ST 12-style 80-bit binary-coded time addresses, fixed 16-bit sync, even-zero polarity correction, biphase-mark waveform at ~-12 dBFS. The PCM signal is computed in the audio render callback from the device's host clock, with no timers or UI dependency.
- LTC follows the cue's play/GO, timeline offset, pause/resume, local PLAY FROM, seek, loop and stop. New cue playback schedules audio and LTC against the **same Core Audio host timestamp**.
- **One LTC source at a time**, to avoid collisions on a physical line. More than one unmuted timecode element per cue and simultaneous LTC cues are rejected. Overlapping LTC/program-audio routes are blocked both by Preflight and at playback/repatch time.
- **Audio LTC output is a line-level control signal, not program audio. Never assign it to a loudspeaker or monitor feed.**

### LTC IN and LTC OUT in the same dock
- **Generated LTC** shows the current cue, SMPTE address, frame rate, output and active status.
- **Received LTC** is a real audio LTC decoder, not the previous MIDI/MTC reader. Choose a Core Audio input device/channel and matching frame rate, then start the input **before GO**. The receiver displays the SMPTE address and lock state. The default input is OFF and must be explicitly started; macOS may request microphone/input access.
- The encoder/decoder were validated together against the **actual generated PCM samples**. A 5-second demo file is included: `Samples/LTC_25fps_01h_demo.wav`. Send it to a dedicated virtual/physical input (never a speaker) to verify the reader.
- The **manual MTC generator is removed from the UI and excluded from the app target**. The previous MTC/MIDI input reader is replaced in the timecode dock by the LTC audio receiver. MIDI Learn for cue transport is preserved.

## Compatibility and known limitations
- Existing `.scshow` projects still open: older timecode elements decode with safe defaults (`ltcOutputChannel = nil`, LTC not routed until assigned). New LTC properties are written only when saving the updated show.
- LTC-only cue containers need a fixed duration. Timecode offset is relative to the parent cue, not an audio stem trim.
- 29.97 DF skips labels `;00` and `;01` at the start of each minute except every tenth; the underlying frame clock is 30000/1001 frames per second.
- The **reader** expects a recognizable PCM biphase-mark LTC signal and the matching frame rate. Hardware device permissions, channel layout, line level, audio-loopback setup and actual lock stability **must be tested on macOS**.
- Switching LTC capture devices while cues are playing is disabled. Changing the physical output device during live playback remains disabled as before.
- No sample-accurate **external LTC chase**, automatic jam sync or re-clocking against an external device in this release. Cue loop re-arming continues to have the pre-existing transition latency; gapless loops are not claimed.
- Do **not use this first LTC implementation for an unsupervised live show** before hardware verification.

## macOS test sequence
1. Verify the unchanged 0.13 audio routing, marker Rules, waveform, Mute/Solo and mixer.
2. Open a stopped audio cue, type `00:00:10:000` into **PLAY FROM**; press PLAY CUE, then Stop and GLOBAL GO. PLAY must begin at 10 s; GO at zero.
3. Add a timecode element in the Inspector; choose e.g. **25 fps**, start `01:00:00:00`, **OUT 16** (only if safely isolated). Keep music on other outputs and choose a fixed cue duration.
4. Open TIMECODE to see **GENERATED LTC**. Start the cue, pause, seek, resume and stop. Check the counter and routing meter on the LTC output, with no audio playback interruption.
5. Route LTC OUT 16 to an available Core Audio INPUT or loopback, choose that INPUT and its channel in TIMECODE, match 25 fps, press START INPUT **before GO**. Check **RECEIVED LTC** locks and advances. Alternatively play the included demo WAV to a routed input.
6. Run Preflight with a missing LTC output and with LTC/audio routed to the same output; both should be blocked. Check older shows save and open.

## Verification
- 113 Linux Swift XCTest tests passed including SMPTE drop-frame, serialization, output collision, full 80-bit codeword/parity, generated PCM and PCM-to-LTC decoding at all four rates.
- All Swift files passed `swiftc -frontend -parse`; C files passed syntax checking.
- **macOS compilation and hardware LTC input/output tests remain pending.** Verify GitHub Actions and test on a non-PA line before treating 0.14 as stable.
