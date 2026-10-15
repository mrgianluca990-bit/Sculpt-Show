# Sculpt Show 0.10.4 — Docked Cue-style Output Mixer

- MIXER docked full-width at the bottom of the main show window. Visible by default; transport MIXER button collapses/expands it. No floating window, and no engine reconfiguration when toggling.
- Initial mixer bank is **All (0)**. Up to 64 physical channels in a horizontal-scroll strip; optional 16-channel banks 1–16 / 17–32 / 33–48 / 49–64.
- Mute/Solo buttons are now illuminated, latched state controls: M = red; S = yellow; dark = off. They operate the same live MatrixMixer output controls as 0.10.3.
- Additional Cue mixer convergence: global sampled Peak Hold and CLIP indicator per physical output, persistent while switching banks; CLEAR PEAK resets hold for every channel. Post-matrix live Peak/RMS metering unchanged.
- Previous label editing, mute/solo reset, automatic hardware routing, live crosspoint reassignment, MIDI, markers, Rules, show files and macOS app icon unchanged.

### Safety
- Opening, hiding, scrolling, switching bank, changing labels, clearing holds or toggling M/S never stops/reschedules a cue.
- Hardware device changes during active cues remain blocked as in 0.10.3.
- Peak Hold is sampled peak of PCM buffers (not intersample true peak). CLIP lights at ≥ 1.0 full scale; CLEAR PEAK is display-only.
- Up to 64 devices channels supported (actual count depends on the interface). The All bank is horizontally scrollable, not 64 channels squeezed into the visible width.
- macOS SwiftUI app still requires compilation in GitHub Actions and real-device testing. Linux tests cover the pure Swift Core model only.
