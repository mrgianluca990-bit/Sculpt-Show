# Sculpt Show 0.7.0 — Cue workflow + MIDI Time Code reader

Independent macOS cue-playback/show-control application. **Not a Merging Technologies product.**

## Changes from 0.6.0

### Drag and drop

- A cue is dragged as its own **native SwiftUI transferable type** (not arbitrary plain text).
- Drag onto the **top half** of a cue to place before it, or the **bottom half** to place after it.
- Drag into a cue list's blank area to append, including moving between lists.
- Cue ID, contained media, settings and **cue-local Interaction Rules** stay intact.
- Drag an **audio file** onto a cue to add it as another element (separate file-drop handling).
- Fallback: right-click a cue > **Move to Cue List**. This uses the same relocation model.
- A cue that is currently playing is stopped before moving to prevent an active Rule from referencing a changed playlist position. Previous/Next Rule targets naturally resolve relative to the *new* list/order. Rules inherited from a source cue list do not move because they belong to that list, not to the cue.

### Cue naming

- Click the Cue name in the Inspector to open a focused Rename window; Save/Return commits once. No model changes during typing.
- Right-click a cue > Rename Cue... also works.

### Duration

- Typed **HH:MM:SS:MMM** in the Cue Inspector, e.g. `00:01:30:250` for 90.25 s.
- Last field is **milliseconds** (3 digits), not timecode frames.
- Explicit duration belongs to the container, independent of attached media.
- Range: `00:00:00:000` to `24:00:00:000`.
- Time input is parsed and formatted without sub-millisecond rounding drift.

### Incoming MTC reader

- Click the **MTC READER** display in the transport to open the reader.
- Refresh connected CoreMIDI sources, select one, and watch incoming MIDI Time Code quarter-frame messages.
- Shows `HH:MM:SS:FF`, nominal FPS (24, 25, 29.97 drop-frame, 30), and signal/lock indication.
- MTC output is the frame count provided by the source; this initial reader does **not** interpolate missing frames, compensate transport latency, chase the cue-playback engine, or trigger Rules.
- **Audio LTC input is not implemented** in 0.7. This will require a separate decoder and input routing UI.

## Build / tests

- On macOS: `bash Scripts/build-macos.sh` or push source updates to GitHub Actions.
- Model tests: 45 passing on Swift/Linux, including cue transfer and timecode decoding.
- macOS app and CoreMIDI input require GitHub Actions build / manual verification; not verified by Linux model tests.
- All prior `.scshow` project data formats remain unchanged (formatVersion 1). Do not delete your existing show files.

## Suggested verification after GitHub build

1. Create 3 cues in List A and 1 in List B. Drag a cue over the top/bottom halves of a row; check the new order.
2. Drag the cue from List A to List B's blank area. Verify contents and cue-local Rules remain present; check Save/Close/Open.
3. Right-click a cue and try **Move to Cue List** if drag-and-drop fails. This distinguishes data relocation from drag handling.
4. Click a cue title in the Inspector and rename to several words. Press Save, then save/reopen the show.
5. Type `01:02:03:004` in the duration field and confirm it survives save/reopen.
6. Open MTC Reader; select an actual CoreMIDI source transmitting MTC. Confirm FPS and HH:MM:SS:FF update and lose lock when the external source stops.

## Existing 0.6 features retained

Cue containers with independently assigned audio elements or timecode *metadata*, cue-level / list-level / show-level Interaction Rules, dual audio playback per cue, play lists, delays, fades, seek and saved shows.

## Limitations

Not tested for production-critical live use. Audio playback still goes to the default system output, not yet a per-element multichannel routing matrix. Timecode reader displays external MIDI Time Code only. No LTC decode, timecode-chased playback, OSC or guaranteed sample-accurate scheduling yet.
