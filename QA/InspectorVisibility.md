# Inspector visibility regression — 0.24.1 RC2

User case: entire inspector intermittently blank when selecting other cues during playback.

The inspector now uses an eager VStack (five sections), with a cue identity boundary to discard stale field drafts and a top anchor restored on selection. Workspace section expansion survives selection/AUTO; a new project identity resets it. Saving to a new URL no longer closes it. Audio/video engines and bridge are unchanged.

## Native UI checks executed, isolated preview

- Initial cue: all five groups collapsed.
- General opened, new cue selected: controls remain present.
- First empty cue looped with GO/AUTO, second cue selected automatically: General and IN/OUT present.
- Sixteen alternating cue selections while first cue remains active: all five headers and IN/OUT present after each change.
- Scroll inspector to bottom (AX scroll value 1), select active cue: header and General visible, scroll returns near top; screenshot checked.
- Open General/Marker/Trigger/Stems/Rules, select other cue while loop remains active: all five sections retain expansion and controls, scroll returns near top.

The exact intermittent blank state of the old build was not reproduced. Its automatic section closing was reproduced. This is a targeted layout correction, not proof that every project/window configuration has been covered. Repeat on the user project with real multitrack/video, Mixer/Waveform and Timecode visible.

## Automated regressions

Run existing InspectorEditingProbe (native field Return/invalid/Escape/blur and workspace hosting), PlaybackPublicationProbe (steady playback does not invalidate entire workspace), and UserGuideProbe after building. Core XCTest runs in CI. Record actual results in the delivery checklist.
