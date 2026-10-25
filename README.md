# Sculpt Show v0.24.0 RC1 — Cue IN/OUT, inspector e guida italiana

## Guida italiana e versione corrente

SHOW 0.24.0 RC1 include la [guida utente italiana completa](docs/SCULPT_SHOW_GUIDA_UTENTE_IT.md), disponibile offline dal menu Help dell’app. La [versione HTML](docs/SCULPT_SHOW_GUIDA_UTENTE_IT.html) è consultabile/stampabile; il [rapporto sorgenti](docs/SCULPT_SHOW_VERIFICA_GUIDA_IT.json) registra gli hash del codice verificato. La guida distingue funzioni operative, MTC storico escluso, backup non implementato e collaudi hardware ancora necessari. IN/OUT in HH:MM:SS:MMM, con fade automatici opzionali; si digitano in General o nella waveform e si trascinano sul grafico; i parametri video si confermano con Invio.


## Note storiche fino alla 0.18.2

Le note seguenti sono conservate come storico; per comportamento e limiti correnti usare la guida 0.24.0 RC1 sopra.

## Layout
- Inspector and its Timecode monitor share a permanent right-hand rail, outside the mixer/waveform `VSplitView`. Opening or resizing the mixer cannot cover the right rail.
- Timecode occupies the bottom of the Inspector (approximately 46% of the available right-rail height); Inspector sections remain scrollable above it. Timecode inherits the Inspector's width and can be shown/hidden independently.
- All Inspector sections remain collapsed by default, as in v0.18.1.

## REAPER-inspired offline normalization
- Right-click an audio cue → **Normalize Audio…**, or open Inspector → **LOUDNESS / NORMALIZE**.
- Modes: **Integrated LUFS** (default −18 LUFS-I), **Sample Peak** (default −1 dBFS).
- LUFS analysis: offline K-weighted mono/stereo PCM, 400 ms blocks, 100 ms hops, EBU R128-style absolute/relative gating. Not a certified loudness analyzer and not a true-peak meter.
- Optional sample-peak safety ceiling −1 dBFS (enabled by default). This can prevent achieving the requested LUFS target; the report shows the actual applied gain.
- Every stem is normalized independently, preserving mono/stereo format, timing, routing assignments and marker/LTC data. Relative track balance will change if stems have different loudness.
- 32-bit float WAV output at source sample rate in **~/Music/Sculpt Normalized/<cue-id>/**. Files are copied, not overwritten; old sources remain untouched. Each successful cue action relinks **all** stems to newly rendered files at once; on failure nothing is relinked.
- Cue, element and master faders remain as they were. Positive normalization gain is baked into the new WAV instead of forcing >100% into the playout faders.
- Normalization is disabled while any cue is playing, to avoid heavy file I/O during a show. Save the `.scshow` after normalization to persist references.
- Output may consume significant additional storage for long multitracks. Underlying source audio remains unchanged.

### Verification
- Swift syntax checked for the complete project; 138 Linux Core tests passed including 6 normalization tests. **macOS app compilation/AVAudioFile write and interactive dock behavior must be validated in GitHub Actions and on the operator's Mac**.
- Baseline: v0.18.1 compiled and operator-tested. No intentional changes to routing, timecode DSP or DAW bridge.

---

# Sculpt Show v0.18.0 — Cue colors and flexible workspace

This release builds on the verified v0.17.0 baseline. UI-only changes (plus optional cue display metadata):

- Cue color palette in the Cue Inspector and the Cue row context menu; colors are saved into `.scshow`, copied on cue duplication and default to no color for old shows.
- Individual Cue List panel widths can be dragged at the right edge (355–900 pt) and persist per-list in local app preferences.
- Inspector width can be dragged at the vertical divider (280–650 pt) and persists across launches.
- Inspector sections expand and collapse independently: Color; Level & Wait; Timing; Markers; Fades & Playback; Stems & LTC; Rules & Actions.
- List options display only one ellipsis button (no extra disclosure arrow), with the original rules/remove commands.
- GO, Pause, Stop, Fade, Previous, Next, Next List, Auto, Mixer, Waveforms and Timecode share a compact single transport row. Small buttons include hover tooltips.

The audio engine, LTC, markers, routing, Rules and Show→DAW bridge are unchanged. The native macOS build still needs verification in GitHub Actions. Core tests: 132 passing on Linux; all Swift sources parse.

# Sculpt Show v0.17.0 — Mixer dinamico e import marker nella DAW

- Mixer nascosto al lancio e meter che seguono l'altezza del pannello ridimensionabile.
- Bridge CLI: crea una traccia mono/stereo per stem, importa marker e copia mute/gain.
- Percorsi output di Show memorizzati nella sessione DAW come OutputPath/track comments.
- **Limitazione:** il renderer audio DAW attuale ignora ancora Route::Hardware;
  per prevenire tracce mute, l'ascolto delle tracce importate resta su Main.
  L'attivazione delle uscite fisiche richiede sviluppo e test separati sulla DAW.
- Vedi README-v0.17.0.md e BRIDGE-ROUTING-PHASE3.md.

---

# Sculpt Show 0.16.2 — One-click DAW edit per cue

- `EDIT IN SCULPT DAW` is now a single gold-icon button on each audio cue row, alongside Play/Pause/Fade/Stop.
- The entire `SCULPT BRIDGE · DAW` Inspector section was removed, including `EXPORT MANIFEST` and `LOCATE CLI` buttons.
- The currently working CLI-based handoff stays unchanged. It is not reimplemented in this update.
- Per-stem `RECEIVE DAW BOUNCE` remains temporarily in the contents editor to preserve the current working manual return path.
- The pending DAW operation has one shared busy guard and a spinner **only on the initiating cue**; success status is shown on the global status bar.
- No change to audio, SMPTE LTC, Cue Rules, saved show format, or CLI permissions.

## DAW physical routing evaluation

See `BRIDGE-ROUTING-DESIGN.md`. The currently working SculptBridge v1 JSON already preserves each stem's `outputStartChannel` and UUID but its CLI script **does not configure DAW hardware outputs yet**. A future coordinated DAW update should preserve mono/stereo per source, create matching mono/stereo DAW output paths, assign every track to the destination and validate device channel counts. Mono splitting of stereo sources should be opt-in rather than automatic to preserve return-path identity. No hardware routing is claimed in v0.16.2.

For GitHub upload: copy the three changed files keeping directories (see `ISTRUZIONI.txt`). GitHub Actions builds universal macOS app. Validate on Mac after build.

---

# Sculpt Show 0.16.0 — Direct Edit in Sculpt DAW (Bridge Phase 2)

- **EDIT IN SCULPT DAW** creates an isolated editable DAW session (named `.scraft`) and automatically launches Sculpt DAW with the cue's stems **aligned at zero**, using `soundcraft-cli` from the existing DAW package. For multiple stems the CLI is required to guarantee alignment.
- If the CLI is unavailable, one-stem cues can be opened directly by the DAW GUI; in this fallback case save the session manually.
- On first launch, select Sculpt DAW.app and, if necessary, `soundcraft-cli`. Their paths are remembered.
- Import runs off the SwiftUI thread. No shell invocation; original Show data and audio remain untouched.
- The v1 JSON manifest is kept for future Show ← DAW synchronization. **RECEIVE DAW BOUNCE** continues to work as before.
- Sculpt DAW itself is **not changed** by this phase, so only Sculpt Show needs a new GitHub build.
- Local checks: **129 Core tests passed** and Swift parsing passed; actual GUI launch, editing and plugin operations require Mac testing.

See [BRIDGE-PHASE2.md](BRIDGE-PHASE2.md) and [ISTRUZIONI.txt](ISTRUZIONI.txt).

---

# Sculpt Show 0.15.0 — Duration Editing Fix + Sculpt DAW Bridge (Phase 1)

- Duration editor: **Return commits**, selecting another cue **discards unconfirmed text**, cue-specific identity prevents stale fields overwriting adjacent cues.
- First native Sculpt Bridge handoff: **SEND CUE TO DAW…** exports versioned JSON with stable cue/stem IDs, routing, LTC, markers and a real `soundcraft-cli` import script based on Sculpt DAW engine commands.
- **RECEIVE DAW BOUNCE…** on each stem replaces the media reference only, preserving the rest of the cue.
- **Not yet live inter-app IPC or a fully automated DAW round-trip**. See `BRIDGE-PHASE1.md`.
- 127 passing local Swift Core tests; macOS compilation requires GitHub Actions.

---

# Sculpt Show 0.15.0 — Duration Editing Fix + Sculpt DAW Bridge (Phase 1)

- Duration editor: **Return commits**, selecting another cue **discards unconfirmed text**, cue-specific identity prevents stale fields overwriting adjacent cues.
- First native Sculpt Bridge handoff: **SEND CUE TO DAW…** exports versioned JSON with stable cue/stem IDs, routing, LTC, markers and a real `soundcraft-cli` import script based on Sculpt DAW engine commands.
- **RECEIVE DAW BOUNCE…** on each stem replaces the media reference only, preserving the rest of the cue.
- **Not yet live inter-app IPC or a fully automated DAW round-trip**. See `BRIDGE-PHASE1.md`.
- 127 passing local Swift Core tests; macOS compilation requires GitHub Actions.

---

# Sculpt Show 0.14.2 — Editing & LTC offset workflow

Based on the operator-confirmed, successfully macOS-built **v0.14.1** baseline.

- New or missing LTC frame offset defaults to **-00:00:00:00**. Explicit saved positive non-zero trims are preserved. The UI presents old +zero as negative zero without changing the signal.
- **LTC START** and **TC OFFSET**: no SET buttons; pressing **Return** validates, commits and exits the field. Invalid entries stay focused with a warning.
- **PLAY FROM** and marker name: pressing **Return** finishes editing and drops focus.
- **−1F / +1F / ZERO** quick LTC offset editing with frame-accurate conversions at 24/25/29.97 DF/30 FPS. These controls do not modify cue audio, playback, routing or LTC trim level.
- **⌘D / Cues → Duplicate Selected Cue**: quick duplication of selected cue, including existing per-cue settings, media references, marker positions and Rules with unique IDs.
- LTC engine, Core Audio routing, HOLD and readers remain unchanged.

New or missing values use safe backward-compatible defaults, and 0.14.1 remains the hardware-tested fallback. This source still requires a GitHub Actions macOS build and operator test.
# Sculpt Show 0.14.1 — LTC HOLD, trims, Delete cue

Release cumulative based on **0.14.0**, verified working on macOS by the operator.

- **Pause/HOLD:** the GENERATED LTC display freezes at the paused cue position; audio LTC goes silent during pause (safer for external LTC chase devices) and restarts at the held address when playback resumes. A seek while paused updates the held display without outputting LTC. STOP clears it.
- **TC OFFSET:** signed `±HH:MM:SS:FF` frame address correction per timecode element (does not change musical audio or cue timeline), saved in `.scshow`. Older saved shows can contain `+00:00:00:00`; in 0.14.2 this is displayed as negative zero without changing the audio.
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
