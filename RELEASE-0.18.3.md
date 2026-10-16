# Sculpt Show 0.18.3 — Normalization fix and portable show folders

## New default Save / Save As

Selecting **Save As** for a new or legacy show creates a self-contained folder:

```text
My Show/
├── My Show.scshow
└── Audio Files/
    ├── 01 - Cue List 1-<list ID>/
    │   ├── audio A-<stem ID>.wav
    │   └── audio B-<stem ID>.wav
    └── 02 - Cue List 2-<list ID>/
        └── music-<stem ID>.wav
```

- The `.scshow` stores **relative media paths**, resolved against the project folder when opened. Move/copy the entire folder between Macs; do **not** move the `.scshow` alone.
- Source audio stays untouched. In the same cue list, repeated references to the same original file share one packaged copy.
- Save of an already packaged show copies only media newly referenced outside its package and atomically updates the show document. Audio previously packaged is never deleted automatically, even if no longer used.
- Save of an older stand-alone `.scshow` opens **Save As** to create a new portable folder. The older stand-alone document is preserved.
- A new destination folder must not already exist. Missing audio raises an explicit error and prevents initial package creation.
- Initial saving of large shows involves copying potentially many gigabytes and can take time. Avoid saving during a time-critical live performance.

## Offline normalization fix

- Explicit Float32 non-interleaved decoding of stereo/mono inputs.
- Fresh decoder for the rendering pass, canonical 32-bit float WAV file settings from AVAudioFormat.
- Exports are stored in the user's `Application Support/Sculpt Show/Normalized Audio/<cue ID>/` folder, not inside the Music folder.
- Before Show references are changed, the generated WAV is reopened and verified for channel count, sample rate and frame count.
- Failures say which stem and stage (reading, writing or validation) failed. All partial copies of a failed multi-stem normalization are removed. Sources and the loaded cue are not modified on failure.
- Normalized audio becomes part of the portable project on its next Save / Save As.

## Validation

- 143 Foundation/Core tests passed under Swift 6.2 on Linux, including portable folder creation, media deduplication, resaving, legacy compatibility, missing audio, and moving a complete project.
- Swift parser passed on the modified App files.
- **macOS compilation and AVFAudio normalization must still be tested in GitHub Actions and on the target Mac.**

## Mac acceptance tests

1. Normalize a stereo WAV (-18 LUFS-I) and a cue with multiple mono/stereo stems. Verify that copies and a report appear; inspect peak guard and gain.
2. Save As a new Show with two Cue Lists and multiple stem sources. Confirm one project folder and nested Audio Files folders.
3. Move that complete folder to another location; open `.scshow` inside it and play all cue lists.
4. Add a new file from outside the project to an existing cue; Save, close and reopen; check that the new media was packed correctly.
5. Test GO, Pause, LTC, markers, routing, cue colors and Show → DAW bridge for regressions.
