# Sculpt Show 0.12.0 — Marker Workflow & UI Responsiveness

Uses the tested 0.11.0 CoreAudio engine, cue transport, .scshow schema and marker Rules.

- Ovation-style waveform ruler: **double-click to add a cue-local marker**, drag its handle to change position (preview during drag, single commit on release), click to select.
- Inspector remains the place to enter `HH:MM:SS:MMM`, rename, assign marker Rules and remove markers. Selection is shared between waveform and Inspector.
- Added snap quantization (1 ms / 100 ms / 1 s), FIT zoom, previous/next marker transport controls and an Add Marker button at playhead.
- Only one primary bottom dock is shown at once: Mixer or Waveforms. Timecode Reader independently appears to the right of either or alone.
- **Responsiveness:** expensive 1,800-bin waveforms are drawn by stable Equatable views, separate from the live playhead. Meter telemetry is isolated into OutputMeterMonitor so CoreAudio tap updates no longer publish through PlaybackEngine, with 12 FPS UI refresh (Peak Hold still samples *every* received meter frame).
- No change to physical routing, audio transport timing (50 ms rule timer), live crosspoint updates, MIDI, or saved show format.

## macOS hardware acceptance tests
1. Open an existing show, select an audio cue, choose WAVEFORMS; mixer closes. Choose MIXER; waveforms closes. MTC can be open beside either.
2. Double-click empty marker ruler near an audio transient: marker appears. Drag its handle; check Inspector numeric position updates and Rules remain intact.
3. Change marker snap from 1 ms to 1 s, drag a marker, verify quantization. Change in Inspector, verify position on waveform.
4. With cue playing, perform a seek on waveform, then change output routing/Mute/Solo while playback continues. Marker Rules and 50 ms scheduling remain unchanged.
5. Test 16-channel audio routing and the 64-channel All bank; watch meter responsiveness and Peak Hold.

## Notes
SwiftUI/macOS visual/runtime tests require GitHub Actions and the operator's Mac. Linux `swift test` covers pure Core geometry and current tests but does not compile the macOS app target.
