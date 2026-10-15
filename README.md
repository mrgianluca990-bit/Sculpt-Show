# Sculpt Show 0.10.3 — Live-safe routing and real output metering

Changes vs successful 0.10.2:
- Never stop active cues to move a stem from OUT X to OUT Y. Modify only matrix crosspoints.
- Reject physical audio *device* switches during any active cue, without touching the current transport.
- Core Audio routing auto-starts on launch using remembered stable device UID or system default output. Audio GO stays blocked if a valid output cannot be initialized.
- One-click **MIXER** button on global transport; **File → Audio/MIDI Setup** contains the output-device chooser and existing MIDI learn. No manual Enable Routing step.
- Actual PCM peak/RMS from a 2048-frame tap on the MatrixMixer output, not activity lights. No claimed sample-accurate peak hold yet.
- The selected audio interface UID is saved as a local user preference. Output routes remain in `.scshow`; MIDI settings unchanged.
- Existing `.icns` and icon packaging preserved.

## Safety / testing
- Live matrix repatching is not a sample scheduler change; clips, rules, marker loop and audio transport remain running. A tiny crosspoint transition/click may still occur: assess on the target interface.
- Changing the *device* / sample rate while cue playback is underway is refused; switching hardware graph cannot be made interruption-free.
- Metering post-matrix uses AVAudioNode.installTap on bus 0. Must verify on real macOS device; the application cannot be fully built or run in the Linux test environment.
- Core Audio output is mandatory for audio GO. If the remembered device is missing, configuration requires explicit operator selection; no silent fallback.
- Output meter is measured pre-hardware-DAC, after MatrixMixer routing and output fader; it is not a measurement of the analog connector.

## Hardware acceptance
1. App starts with ROUTING automatically active. Mixer opens directly (even before show is loaded).
2. Two mono stems playing OUT1 / OUT3: change one to OUT5 **during GO**; original cue stays running, no STOP Rules/markers are fired.
3. Attempt Audio/MIDI Setup device change during GO: change must be denied, cue continues on old device.
4. Meter shows levels on OUT1 and OUT5 only as audio flows. Mute/Solo reflect post-matrix signal levels.
5. Test two simultaneous cues and stereo stems; Save `.scshow`, close and reopen from Finder.
6. Disconnect remembered device before app starts: error, no playback on arbitrary other outputs.

## Notes
Existing audio output routing uses AVAudioEngine / Apple MatrixMixer. Up to 64 output channels and 16 routed voices if the hardware exposes them. Audio buffer tap metering is experimental until live tested.
