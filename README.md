# Sculpt Show 0.6.0 — Cue containers & drag/drop

Sculpt Show is an independent native macOS show-control prototype, inspired by cue-container workflows in professional media servers, including Merging Ovation. It does **not** contain Ovation source code or proprietary assets.

## The v0.6 architectural change

**A cue is always one container with its own identity, timeline and Rules.** It does not have a permanent “audio cue” versus “empty cue” type. A newly created cue contains no media. Its contents are an ordered collection of elements:

- Zero elements: silent timed cue; Rules still fire at the start and end.
- One audio element: audio starts at its assigned offset within the cue.
- Multiple audio elements: parallel audio, each with its own cue-relative offset and non-destructive IN/OUT region; audio can stop while the cue continues.
- Timecode element: saved timecode start, frame rate and cue-relative offset. **LTC/MTC physical output is not implemented yet**; playback still runs the container timer and its Rules.
- Mixtures of audio and timecode metadata, or a group of audio elements within the same cue.

The cue's LENGTH is separate from individual audio source lengths. When importing audio as new cues, their initial container durations are determined from their files. Previously saved `.scshow` projects that had audio tied to source duration retain that behavior until the user explicitly edits LENGTH. This is controlled by `durationMode`, which preserves backward compatibility.

## Interaction changes

- Click **NEW CUE** to insert a genuinely empty container. Use the new **CONTENTS** panel in the inspector to add multiple audio sources or a timecode element.
- A cue is draggable using the row surface. Drop it **onto another cue** to insert before that cue; drop it **into a list's empty area** to append it. This works in the same list or another list.
- Cue identity (UUID), Rules, properties and element data survive moves. Moving a cue currently playing stops that cue before relocating it, and cancels pending Rules targeted at it. PLAY LIST sequences in affected lists are cleared to avoid ambiguous live behavior.
- All existing global and list FIRE / PLAY LIST / STOP / FADE / RULES controls remain.

## Important limitations and test notes

- The engine remains `AVAudioPlayer` / macOS default output. Multiple elements are started close together but **not sample-accurately**. There is no multichannel output assignment, routing matrix or hot-backup system yet.
- Timecode elements are an extensible data model and UI control, **not an actual LTC/MTC generator** in this version.
- Loop operates on the cue's entire timeline, not on individual files. Fade-in/out and gain affect the cue's audio elements. IN/OUT and cue-relative offsets do not alter source media.
- Legacy `.scshow` import is supported. The new format writes the `elements` array and `durationMode`; older Sculpt Show versions will not recognize these features. Back up existing show files before upgrading. Files are still referenced by **absolute path** and aren't embedded.
- Only the model can be fully tested on Linux. A real macOS build through GitHub Actions and on-device drag/drop and multielement playback smoke tests are required before describing this as a verified build. Not suitable as the sole mission-critical playback system.

### Smoke test checklist (macOS)

1. Create a show, insert three **NEW CUE** containers, name them and set different LENGTH values.
2. Add two audio files into one cue using the inspector **Audio +** button. Change the second file's OFFSET and trim its IN/OUT.
3. Play that cue. Confirm the first audio starts at 0 and the second starts at the specified OFFSET, and that the entire cue ends at the specified LENGTH.
4. Make a Rules-only empty cue. Set `Starting → Fire → Specific Cue` and confirm the target starts.
5. Add a timecode element, set text and FPS, save/reopen and verify settings persist. No LTC/MTC output is expected yet.
6. Drag a cue over a row to insert before it, then drag that cue to a second list. Save/reopen, confirm its UUID-dependent rules and contents survive.
7. Open an old `.scshow`, change a cue's LENGTH and ensure its original media is not modified.
8. Verify STOP LIST, STOP ALL, PLAY LIST and per-cue fade still function as before.

## Build

After uploading the modified sources to `main`, GitHub Actions runs `Scripts/build-macos.sh`, executes model tests, compiles a universal app (Apple Silicon + Intel), ad-hoc signs it and uploads an artifact called `Sculpt-Show-macOS`.

This repo is a functional reimplementation and does not claim file-format or source compatibility with proprietary Merging Ovation show projects.
