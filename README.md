# Sculpt Show 0.8.3 — Finder Documents + Aligned Audio Stems

Incremental update based on 0.8.2. The cue container model, per-element volume/mute, Rules, routing and MIDI controls remain unchanged.

## Changes

- **Multitrack**: Every audio element begins at the first sample (t=0) and uses its full source duration. No per-track OFFSET / IN / OUT widgets; fixed container duration remains editable. Existing project trim/offset metadata is preserved in the file for compatibility, but deliberately ignored for audio playback. Timecode offset is still configurable.
- **Finder `.scshow` support**: Registered exported UTType and CFBundleDocumentTypes in the actual packaged Info.plist; SwiftUI onOpenURL hands incoming file URLs to the same ShowStore document decoder used by File > Open. Unsaved changes confirmation still applies, and successful loads stop previous playback.
- **No changes** to MIDI controller features; synchronized scheduling and element faders/mute remain.

## Validation

- macOS SwiftUI and LaunchServices integration requires a fresh macOS GitHub Actions build and a Finder double-click test on an installed/registered app.
- Run `swift test` and `swiftc -frontend -parse` to check core tests and syntax.

## Installing file association

Copy the new Sculpt Show.app into /Applications, replacing the old copy. To make it the default for an already saved project: select any `.scshow` in Finder > Get Info > Open with > Sculpt Show > Change All. Then double-click. Note that unzipping successive copies to Downloads may leave macOS launching an older copy of the app.
