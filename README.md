# Sculpt Show 0.8.0 — Global Live Transport and MIDI Control

Native macOS application, Intel and Apple Silicon. Functional reimplementation for Sculpt Show; not Merging Ovation.

## Changes from 0.7

- **Exactly one selected cue across the entire show.** Selection is represented by a single selectedCueID and selectedListID, not a separate selection stored for every cue list.
- **Global transport:** GO, Pause All / Resume All, Stop All, Fade All, Previous Cue, Next Cue, Next Cue List. Previous and Next skip disabled cues and stop at list boundaries; Next List cycles across lists, selecting the first enabled cue there. Existing per-list PLAY LIST / STOP / FIRE remain available.
- **USB MIDI controller:** CoreMIDI source picker and MIDI Learn for the seven global commands. Supports MIDI Note On and CC (rising across 64); mapping stored in local UserDefaults, not in the show. Select the controller and press each hardware key once in Learn mode. Supports multiple MIDI sources being shown, but connects only the selected one.
- **Cue drag:** drag the highlighted three-line grip on the left side of each cue; drop in the top or bottom half of a cue to place before or after, or in empty space in a list to append. Implemented with native `NSItemProvider` text payload tagged with `sculpt-cue:` instead of SwiftUI `Transferable` custom UTI, which failed in 0.7 on the user's Mac. Audio-file drops remain separate. Context menu **Move to Cue List** is also retained.
- **Safety:** Stop All cancels pending Rules and cue starts; Fade All cancels pending Rules and suppresses STOP-triggered rule cascades. Pause All is toggled by a second press to Resume All.
- **Existing cue name and HH:MM:SS:MMM time editor retained.** Original .scshow format is unchanged; source audio and Rules survive moving a cue.

## Operator test (macOS)

1. Select cue in list 1; select cue in list 2; verify **only one** row is highlighted and inspector follows selection.
2. Use PREVIOUS, NEXT, NEXT LIST; verify NEXT LIST selects its first enabled cue.
3. GO multiple overlapping audio cues and test PAUSE ALL twice (pause/resume), FADE ALL, STOP ALL.
4. In each cue list, **drag only the three-line grip** to reorder and to transfer to another list; after moving, open the cue RULES and check settings. The old custom UTI is no longer used. Test both populated lists and an empty destination list.
5. Click MIDI SETUP, choose a CoreMIDI USB source, click Learn next to GO, press one controller button, verify the mapping appears; repeat for navigation and safety controls. CC button should transmit low value on release so it can trigger again on next press.
6. Save and reopen a .scshow file; check that Rules, content, duration, name and cue order persist. MIDI preferences are stored on the Mac, not in the .scshow.

## Limitations

The full macOS UI and MIDI callback must be compiled and exercised on a Mac through GitHub Actions and real hardware before this version can be considered verified. Current automated tests exercise the portable core model only. MIDI input does not send timecode; the independent MTC reader remains separate. Routing is still default audio output, not a channel matrix. Audio timing is not sample accurate. The build is ad-hoc signed, not notarized and must not be used as a sole live-show playback system before rehearsal / redundancy testing.

## Build and download

Push the changed files to `main`: [GitHub Actions](https://github.com/mrgianluca990-bit/Sculpt-Show/actions) will compile on macOS, run tests, build universal app and publish `Sculpt-Show-macOS` artifact. Unzip the artifact then `Sculpt-Show-macOS.zip` for the `.app`.
