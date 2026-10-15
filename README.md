# Sculpt Show

Independent macOS audio cue player and show-control workbench inspired by professional cue-list workflows. **Not a Merging Technologies product**; no Ovation source code or assets are included.

## Version 0.2.0 — cue control update

Added in 0.2:

- **Auto Next** switch: pressing GO or list FIRE starts the selected cue, then selects the following enabled cue (never wraps automatically).
- **Auto-follow** per cue: when its file finishes naturally, starts the next enabled cue in the same list. Loop takes priority over auto-follow.
- **Loop** per cue: repeats indefinitely until STOP or FADE. Can toggle during playback.
- **Fade-in** per cue (0 to 30 seconds) in addition to the existing fade-out.
- **Seek**: click/drag each active cue's progress slider; works when paused, disabled during fade-out.
- **Time remaining** shown in each playing row and the inspector.
- **Move cue Up/Down** in the inspector. Keeps the cue's identity and saved settings.
- Compatibility with `.scshow` files created in 0.1: missing new keys default to disabled/zero. Existing formatVersion remains 1.

The 0.2 UI and playback engine must be compiled and tested on macOS through GitHub Actions before being considered a verified build. The Core model passes tests on Linux.

## Previous 0.1.0 foundation

- Native **SwiftUI** interface for macOS 13+ (universal arm64 + x86_64 build on a Mac).
- Multiple cue lists visible side by side.
- Import multiple audio files into a cue list using **Add Audio**, or drag file URLs into the list.
- Concurrent cue playback via **AVAudioPlayer** (Apple's default audio output).
- GO, per-cue pause/resume, stop, configurable fade-out, and global Stop All.
- Separate cue selection, enabled switch, gain and fade setting.
- Save/Open a `.scshow` JSON show file.
- Keyboard shortcuts: **Space** for GO, **⌘↓** for next selection, **⌘.** stop all, **⌘S** save, **⌘O** open.
- Unit tests for the portable project-model layer.
- GitHub Actions macOS build produces a downloadable `.app` ZIP as an Actions artifact.

## Run from Xcode

1. On a Mac with Xcode 15 or newer, clone/download this repository.
2. Open `Package.swift` with Xcode.
3. Select executable scheme `SculptShow`, target **My Mac**, and Run.

To create the `.app` locally in Terminal:

```bash
bash Scripts/build-macos.sh
```

Then open `dist/Sculpt Show.app`. The app is ad-hoc signed **for development**, not notarized. macOS may block downloads from other Macs without additional security handling. Never disable system-wide Gatekeeper.

## Get a build without Xcode

After pushing to `main`, open **GitHub > Actions > Build Sculpt Show for macOS > latest successful run > Artifacts** and download `Sculpt-Show-macOS`. It contains `Sculpt-Show-macOS.zip` with the macOS application. **A Mac is required to run it.** The prototype does not yet have a notarized release.

## First smoke test

1. Run Sculpt Show, click **ADD AUDIO**, and select both files from `Samples/`.
2. Press **Space** to GO the selected cue, then select the second cue and GO again: both should play simultaneously.
3. Try Pause, Fade and Stop. Adjust cue gain and fade time in the inspector.
4. Set Fade In on a cue, enable Loop on another, and check that GO uses the new values.
5. With AUTO NEXT on, GO should advance the selection without interrupting audio already playing.
6. Enable Auto-follow on a short cue, then verify it starts the following enabled cue only when it ends normally.
7. Seek and pause using the progress slider; use the Up/Down buttons to reorder the selected cue.
8. Use **Save** to create a `.scshow` file, reopen it, and check that settings survive.
9. Open an older 0.1 `.scshow`; the three new cue options should safely default to off/0.
10. Disconnect one referenced audio file: the inspector warns that the media is missing.

The included WAV tones are synthetic test signals, not third-party content.

## File storage warning

`.scshow` contains **absolute paths to your media**, not the audio itself. Moving the audio files, changing computers, or deleting their source folders breaks the link. At this stage shows are not portable; use stable media folders and keep a separate copy of source assets. Future work: relative paths, media relinking, portable show package and project consolidation.

## What this is not yet

- No professional deterministic playback guarantees, hot backup, or cue scheduler.
- **No arbitrary hardware-channel routing**: all cues go to the system-default output.
- No OSC, MIDI, LTC/MTC, GPI, networking, timecode, video or Merging `.ovs`/`.ovl` import.
- No multichannel matrix, sample-accurate cue synchronization or redundant show engine.
- No compatibility claim with Ovation binary files; this is **functional reimplementation** based on public descriptions.
- A CI build is not proof of show-critical reliability. Do not deploy as the sole playback system for paid shows until tested.

## Structure

- `Sources/SculptShowCore/Show.swift`: Codable show model, legacy compatibility, cue reordering, and next-cue selection.
- `Sources/SculptShowApp/`: SwiftUI main window, show store, AVFAudio playback engine.
- `Tests/SculptShowCoreTests/`: model round-trip and editing tests.
- `.github/workflows/macos-build.yml`: builds/tests on a macOS runner and uploads an app ZIP.

## Near-term roadmap

1. CI verification of 0.2 on macOS and real playback tests; introduce UI tests.
2. Cue delay and automatic start triggers, cue group actions and per-list STOP commands.
3. Audio engine redesign around `AVAudioEngine` and Core Audio with per-cue routing, metering, and buffering.
4. Portable projects, media relinking and validation.
5. MIDI/OSC commands and external GO, with emergency stop.
6. More advanced Ovation-inspired show modes, cue rules, and show-control protocols.

## Legal and attribution

Sculpt Show is a new independently authored project. Ovation and Merging Technologies are trademarks of their respective owners. No reverse-engineered proprietary binaries, third-party source, or official UI assets are distributed here.

No open-source license is granted yet while the private initial prototype is being evaluated. Choose and add a `LICENSE` before a public release or contributor onboarding.
