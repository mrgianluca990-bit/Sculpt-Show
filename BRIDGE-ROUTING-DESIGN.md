# Sculpt Show ⇄ Sculpt DAW: hardware routing specification (design only)

## Source of truth
The Show cue remains authoritative for `cueID`, each `elementID`, original source, `outputStartChannel`, mute, gain, markers and LTC. The bridge manifest already contains the output channel, but the current script only does `session.new`, `file.import_audio`, `session.save` and does not route the DAW track.

## Recommended mapping
1. **One mono source**: one mono DAW track, physical OUT `n`.
2. **One stereo source**: one stereo DAW track, physical OUT `n/n+1`, no collapsed mono or fold-down.
3. **Multiple mono sources**: separate mono tracks aligned to session sample zero; route each track to its own Show output (allow intentional shared outputs).
4. **Mixed mono/stereo cue**: preserve the source format for each track. Optional “split stereo to dual mono” for offline sound design; never the silent default.
5. **LTC**: retain as cue metadata and reserve its physical output; never import it as ordinary audio or send musical tracks onto that output accidentally.
6. **No source mutation**: import/copy to isolated DAW session, keep original UUID mapping for eventual return. Confirm if the same device is used before enabling physical routing.

## Grounded DAW implementation details
SculptDAW already has `setup.io {action:create_output,name,format,first_channel}` where `first_channel` is zero-based and `format` accepts `mono` or `stereo`, and `track.output {tracks:[name|id],output,create_bus:false}`. The current CLI importer creates track format matching each decoded audio file. `track.output` must use `create_bus:false`, otherwise an unknown output name is interpreted as a new internal bus. A safe bridge must create output paths first and assign verified stable track IDs, rather than assuming all filenames are unique. The existing `soundcraft-cli script` command cannot refer to `file.import_audio`'s returned track IDs, so robust duplicate-name-safe assignment requires a DAW-side bridge import command that owns the entire transaction. Do not silently assert physical routing before verifying it against the chosen DAW hardware device.

## Phase 3 acceptance tests
- Mono source on Show OUT 5 -> DAW mono track on OUT 5.
- Stereo source on Show OUT 5/6 -> DAW stereo track on OUT 5/6.
- Four mono stems -> four mono tracks, each with its corresponding physical output.
- Duplicate filenames from different directories -> all imports have correct independently routable IDs.
- Same output intentionally shared by two stems -> preserved without remapping.
- LTC OUT collision -> preflight blocks unsafe audio routing.
- DAW with fewer hardware channels -> explicit warning and safe unassigned output; never silent fall-through to Main 1/2.
- DAW save / reopen -> channel widths, regions and outputs persist.
