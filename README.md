# Sculpt Show

Independent macOS audio cue player and show-control workbench inspired by professional cue-list workflows. **Not a Merging Technologies product**; no Ovation source code or assets are included.

## Version 0.1.0 — technical prototype

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
4. Use **Save** to create a `.scshow` file, reopen it, and check that settings survive.
5. Disconnect one referenced audio file: the inspector warns that the media is missing.

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

- `Sources/SculptShowCore/Show.swift`: versioned Codable show model and format validation.
- `Sources/SculptShowApp/`: SwiftUI main window, show store, AVFAudio playback engine.
- `Tests/SculptShowCoreTests/`: model round-trip and editing tests.
- `.github/workflows/macos-build.yml`: builds/tests on a macOS runner and uploads an app ZIP.

## Near-term roadmap

1. CI verification on macOS; fix any Xcode 15+ compile/runtime issues; introduce UI tests.
2. Non-destructive cue ordering, auto-follow and timing controls.
3. Audio engine redesign around `AVAudioEngine` and Core Audio with per-cue routing, metering, and buffering.
4. Portable projects, media relinking and validation.
5. MIDI/OSC commands and external GO, with emergency stop.
6. More advanced Ovation-inspired show modes, cue rules, and show-control protocols.

## Legal and attribution

Sculpt Show is a new independently authored project. Ovation and Merging Technologies are trademarks of their respective owners. No reverse-engineered proprietary binaries, third-party source, or official UI assets are distributed here.

No open-source license is granted yet while the private initial prototype is being evaluated. Choose and add a `LICENSE` before a public release or contributor onboarding.
