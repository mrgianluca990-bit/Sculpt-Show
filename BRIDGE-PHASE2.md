# Sculpt Bridge Phase 2 — Show → native Sculpt DAW editing

## Goal verified in source

1. Select an audio cue in Sculpt Show and click **EDIT IN SCULPT DAW**.
2. Show writes a separate workspace under `~/Music/Sculpt Bridge/`, with a `sculpt-cue-bridge.json` manifest and `import-into-sculpt-daw.txt`.
3. When `soundcraft-cli` is available, Show executes `soundcraft-cli script ...` **as a subprocess (no shell)**, creates a `.scraft` session at 00:00, and launches `Sculpt DAW.app` with the resulting session path as an argument. This relies on the existing Sculpt DAW 0.4 GUI's startup session-opening code; **Sculpt DAW does not need a new build for this first direct bridge**.
4. The operator can edit clips, faders, audio and plugins in Sculpt DAW and save the session normally. This is the first milestone through **editing inside the DAW**, not automated return of those edits into Show.

## First use

- Install/extract the Sculpt DAW build on your Mac.
- If Show doesn't locate it, select **Sculpt DAW.app** when asked; the path is remembered.
- The DAW artifact includes a separate `soundcraft-cli` executable (usually next to Sculpt DAW.app in the downloaded ZIP). Show finds it automatically if it's adjacent to the app, or at `~/Downloads/soundcraft-cli`, `~/Applications/soundcraft-cli`, `/usr/local/bin`, `/opt/homebrew/bin`.
- Otherwise select **LOCATE CLI…** in the Bridge section and point to `soundcraft-cli`. For multi-stem cues this executable is required: the CLI imports all stems with `at: 0` in one operation and saves a native DAW session.
- For **single-stem cues only**, if the CLI isn't available, Show can start Sculpt DAW with the audio file as an argument. The audio is importable into a new DAW session; use File → Save As manually. A valid CLI is recommended for the complete named-session flow.

## Contract and safety

- Existing v1 `com.sculpt.bridge.cue` JSON is maintained, including stable cue/element UUIDs and marker/LTC routing metadata. The DAW import currently uses the audio paths and cue name; the remaining fields are kept for the later round-trip phase.
- An immutable export per invocation prevents overwriting previous DAW edits or the Show project. A new UUID workspace is generated on each launch.
- The original WAV/AIFF source paths are referenced, not rewritten. CLI copies imported material into the DAW session's `Audio Files` folder according to DAW's existing implementation.
- Existing **SEND CUE TO DAW… / EXPORT MANIFEST…** and **RECEIVE DAW BOUNCE…** workflows are preserved. There is **not yet** automatic Update Show, collaborative edits, DAW realtime synchronization, shared audio engines, or automatic track/plugin state merging.
- Using a fresh DAW application instance prevents a session already being edited from being replaced by an incoming cue. Please avoid launching the DAW against the live hardware interface during a show until this workflow has been tested.

## Mac acceptance tests

1. In Show, select a cue with 2 mono/stereo stems (different source names); click EDIT IN SCULPT DAW.
2. Locate `Sculpt DAW.app` and `soundcraft-cli` only if asked; confirm the app starts with an editable session, both clips begin at 00:00, names are correct, and the sample rate is read from the first source.
3. Move or split a region, change a fader, add a plugin, save the `.scraft` file, close and reopen it. Changes must persist.
4. Verify the workspace contains `sculpt-cue-bridge.json`, the import script, the `.scraft` file and DAW-created `Audio Files/` folder; verify original Show WAVs are unchanged.
5. Repeat with a one-stem cue, then an already-running Sculpt DAW session. The existing DAW session must not be replaced.
6. Confirm Show still plays, routes audio, displays LTC and runs Rules without regressions.

**Build status:** 129 Linux Core tests and syntax check of modified Swift sources passed. macOS compilation, DAW launch behavior and plugin editing require actual Mac verification.
