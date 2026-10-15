# Sculpt Show 0.9.0 — Multichannel Output Routing (opt-in preview)

Baseline: Sculpt Show 0.8.3 (tested and approved on user's Mac).

## Change
* The PROVEN 0.8.3 stereo playback backend remains the default on every launch.
* OUTPUT ROUTING opens a macOS Core Audio output device chooser. Enabling hardware routing reconfigures an independent AVAudioEngine / Apple MatrixMixer graph.
* Every individual mono or stereo file in a cue has a persistent one-based OUT assignment (mono: one output; stereo: consecutive outputs).
* The routed engine supports up to 64 device channels and 16 simultaneous audio files. 64 physical outputs are possible only if the selected device exposes them.
* The routed engine schedules all tracks of a cue from a shared Core Audio host timestamp. No per-stem IN/OUT/offset are reintroduced.
* Failure to enable routing is reported explicitly; the engine does not silently claim that a route was applied.
* Safety: when any audio file has an output assignment other than 1, GO is blocked in stereo mode, to prevent unintended audio on the default stereo outputs.
* On a new launch routed output is disabled and must be enabled deliberately with the desired device. Project output assignments persist; physical device selection is not permanently stored.
* Cue timing, single selection, midi controls, Rules, save/load, aligned stem transport and mute/level stay unchanged in standard mode.

## Limitations and verification
* **PREVIEW, NOT HARDWARE VERIFIED.** The Apple MatrixMixer graph has to be compiled through GitHub Actions then tested with the user's actual macOS interface.
* Multi-device Aggregate Devices can be selected when Core Audio exposes them as one output device; independently clocked unrelated interfaces aren't combined here.
* Supported routed source formats: mono and stereo audio decoded by AVAudioFile. A 3+ channel source is rejected with an error.
* 16 simultaneous stems is the initial pool limit; additional stems fail loudly instead of being silently dropped.
* The outputs are not auto-reassigned on device changes, and a stereo source cannot be placed in the final channel alone.
* Channel level/mute in routed mode are handled by per-stem AVAudioMixerNode; outputs by MatrixMixer crosspoints.
* Routed gain and loop controls use the existing cue timing updates, not yet gapless or sample-accurate for loop boundaries. This remains a preview pending hardware test.
* Timecode reader, MIDI learn and control bindings are unmodified.

## Hardware acceptance test
1. Compile in GitHub Actions, install app, verify previous show runs in **SYSTEM STEREO** mode as 0.8.3.
2. Stop all audio. Open OUTPUT ROUTING > choose a multichannel device e.g. Pro Tools Audio Bridge 16 > Enable routing.
3. Load a cue with TWO mono WAVs, set one stem OUT 1 and another OUT 3, GO. Verify ONLY corresponding channels signal, independently.
4. Change assignments to OUT 5/OUT 7; GO and confirm routing changes only as assigned.
5. Test Pause/Resume, Seek, Mute, Fade All, overlapping cues, saving and reopening .scshow.
6. Disable routing: if show contains OUT > 1, GO must show an error rather than play to stereo outputs.
7. If enabling hardware route fails, report the exact error message and device channel count. Disable routing to return to proven 0.8.3 mode.

72 automatic Linux core tests passed; macOS compilation/runtime audio routing pending.
