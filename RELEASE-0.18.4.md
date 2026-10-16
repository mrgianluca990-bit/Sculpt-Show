# Sculpt Show 0.18.4 — Normalizzazione PCM affidabile

**Base:** versione 0.18.3 (salvataggio portabile, mixer/Timecode e bridge invariati).

## Intervento

- La normalizzazione dei normali WAV mono/stereo PCM 8/16/24/32-bit e IEEE float 32/64-bit usa una **lettura streaming nativa Swift** invece del decoder Objective-C, evitando il generico errore `Foundation._GenericObjCError error 0` su quel percorso.
- L'esportazione dei WAV normalizzati usa **un writer RIFF/WAVE IEEE Float32 nativo Swift**, senza `AVAudioFile(forWriting:)`; `fmt`, `fact`, `data`, dimensione del file, sample rate e numero dei frame vengono verificati.
- Per altri formati audio Core Audio rimane **soltanto il decoder**; la scrittura è sempre la stessa.
- Analisi LUFS/Peak, rendering e successiva **verifica del valore LUFS effettivo sul file** sono eseguiti fuori dal thread audio. Report con livello prima/dopo e gain applicato.
- File originali conservati. Se uno stem fallisce, nessuna traccia viene ricollegata e tutte le copie parziali vengono eliminate.
- Errori più specifici per lettura, analisi, scrittura e verifica, con codice/dominio NSError quando disponibile.
- Non modificati: salvataggio `.scshow` portabile per cue list, marker, Rules, LTC, mixer, trasporto e bridge DAW.

## File da sostituire o aggiungere

- `Sources/SculptShowApp/CueOfflineNormalizer.swift` — sostituzione
- `Sources/SculptShowCore/LoudnessNormalization.swift` — sostituzione (ingest da audio PCM per canale)
- `Sources/SculptShowCore/WavePCMStream.swift` — **nuovo**
- `Tests/SculptShowCoreTests/WavePCMStreamTests.swift` — **nuovo**
- `Scripts/Info.plist` — versione `0.18.4`

## Verifiche effettuate

`swift test --jobs 2` su Linux: **149 test superati**, incluse sei prove sul decoder/writer WAV (lettura PCM 16/24-bit, float32 stereo, WAV con metadati, normalizzazione effettiva a −18 LUFS, WAV troncati, file sample del progetto).

La compilazione dell'app su macOS e il test con i WAV dell'utente devono essere eseguiti con GitHub Actions e sul Mac: il test Linux non copre `AVFAudio`.

## Test richiesti sul Mac

1. Normalizzare **una cue stereo WAV** a −18 LUFS e controllare che compaia il report completo.
2. Normalizzare una cue con **2 file mono + 1 stereo** e verificare tutte le tracce e gli output invariati.
3. Salvare `.scshow`, riaprire e verificare che i WAV normalizzati siano copiati nelle rispettive cartelle `Audio Files`.
4. Controllare che playback, LTC, marker e bridge DAW siano invariati.

*Limiti:* WAV RIFF standard <4 GiB; RF64 o codec WAV non PCM sono delegati al decoder Core Audio, che potrebbe non supportarli.
