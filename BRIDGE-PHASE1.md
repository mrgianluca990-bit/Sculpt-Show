# Sculpt Show ⇄ Sculpt DAW Bridge — Phase 1

### What works now
From Show, select a cue containing mono/stereo audio and choose **SEND CUE TO DAW…** in the Inspector. A user-selected folder receives:

- `<name>-bridge.json`: stable cue/element UUIDs, stem absolute paths, output channels, levels, cue duration, marker positions and LTC metadata. `format=com.sculpt.bridge.cue`, `version=1`.
- `<name>-bridge-DAW.txt`: validated `soundcraft-cli` script using commands from the current SculptDAW repository (`session.new`, `file.import_audio`, `session.save`). Paths are escaped JSON. All stems are placed at timeline zero.

A DAW CLI is required to execute the generated script, for example:

```bash
/path/to/soundcraft-cli script "/path/to/Cue-bridge-DAW.txt"
```

This generates a native DAW session (`.scdaw`) that can be opened in Sculpt DAW if its installed version accepts the session format. It does NOT automatically launch the DAW, nor does Show parse proprietary DAW sessions.

After editing in DAW, export a **mono or stereo bounce** from its timeline origin. In Show, select the corresponding audio element and click **RECEIVE DAW BOUNCE…** to choose the newly rendered file. The original file is untouched. Routing, cue ID, markers, LTC and Rules remain with the cue; the new audio is used at its next GO. Avoid changing a cue's media during live playback.

### Limits and next milestone
This is a deterministic, file-based bridge, **not yet a live round-trip**: sample-accurate alignment over shared media, DAW session change notifications, full marker mapping, incremental media diffing, and IPC are planned. DAW script import uses the CLI exposed by the `SculptDAW` repository and still requires verification on the actual DAW build. Absolute source paths require the original files to remain accessible. The manifest does not embed/copy media. Show's cue-specific gain/pan/routing are metadata, not duplicated as DAW mixing controls.

### Duration editor regression
The duration text field owns a single cue ID; only Return saves. An unfinished text draft is discarded on blur/selection change, and a newly selected cue has its own editor state. There is no implicit save during opening a project.
