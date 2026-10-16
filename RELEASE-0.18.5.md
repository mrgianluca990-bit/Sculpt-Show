# Sculpt Show 0.18.5

Updated sources: `Sources/SculptShowCore/ShowProjectPackage.swift`, `Sources/SculptShowApp/CueOfflineNormalizer.swift`, `Sources/SculptShowApp/ShowStore.swift`, `Scripts/Info.plist`. Added two `ShowProjectPackageTests`, plus README.

* Normalize Audio output written inside the current portable show, within `Audio Files/<cue-list>/`.
* Output folder reuses stable cue list UUID after rename.
* WAV direct-read failures fall back to Core Audio decoder, returning both errors when needed.
* Requires an already saved portable project. Copy of old source files is not overwritten.
* Important: this does not prove the user's specific failing stereo file will decode. Send full error and file extension if it still fails.
* Do not upload this release note into Scripts or Sources; it is documentation.
