# RC2 — dock height and header icon

User-authorized changes after the graphical freeze: replace the header wordmark with the bundled SculptShow.icns; restore Mixer/Waveform height drag.

The dock now has an explicit 8-point drag handle between the cue-list area and the dock. Global gesture coordinates avoid moving local origins. Local state changes during drag; UserDefaults are saved only on release. Mixer/Waveform share the same height and clamp to available window height; Inspector remains outside the split. No playback/model/Bridge change.

Native UI preview checks executed: icon visible in header; Mixer drag changed saved height 340→440, reverse drag 440→312, switch to Waveform retained 312, Waveform drag changed it to 387. Inspector and transport remained visible. Full project/audio/hardware regression remains in the existing manual plan. B01 is not changed.

The scope baseline now records this explicit layout authorization and the exact expected geometry calls. Other geometry/typography and protected sources remain checked. Prior RC1 restyling audit and benchmark remain historical; no new absolute performance claim.
