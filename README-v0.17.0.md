# Sculpt Show v0.17.0 — Dock Mixer + Marker handoff + DAW I/O map

Base: Sculpt Show v0.16.2 (macOS GitHub build previously confirmed).

## Modifiche
1. Il mixer non si apre più di default. MIXER / WAVEFORMS / TIMECODE si aprono su richiesta.
2. Meter VU/Peak/RMS a geometria dinamica: crescono e si restringono con l'altezza del dock.
3. `EDIT IN SCULPT DAW` crea una sessione con una traccia per stem, mantenendo mono/stereo originario.
4. Ogni marker della cue viene creato come `markers.add` in Sculpt DAW, con nome e posizione in secondi.
5. La sessione riceve percorsi I/O fisici distinti (`setup.io.create_output`) e commenti di ogni traccia contenenti OUT, larghezza e UUID stem.
6. Gain per-stem e mute della cue sono copiati sui canali DAW. L'LTC non viene importato come file audio.

## Importante: limitazione attuale del motore DAW
L'attuale mixer di Sculpt DAW non esegue il rendering per `Route::Hardware` (il suo match gestisce
solo `Route::Main` e `Route::Bus`). Assegnare l'output fisico al canale ora renderebbe la traccia
muta nella DAW. Questo aggiornamento **non assegna** `track.output = Route::Hardware`.
Preserva dunque il layout delle uscite come I/O paths più metadata per-traccia e lascia l'ascolto
sul percorso Main. Il routing fisico attivo è un aggiornamento successivo da sviluppare nella DAW,
insieme a renderer multi-output, controllo delle uscite sul device, test 1-64 e preflight.
Non dichiarare che l'audio DAW esca già dal canale fisico di Show.

## Test consigliati
- Avvia Show con un progetto: nessun mixer aperto. Apri MIXER, trascina il divisore in altezza,
  controlla che il meter occupi l'altezza utile senza tagliare M/S o il nome uscita.
- Cue con file mono OUT 3, stereo OUT 5/6 e secondo mono OUT 8: premi EDIT IN SCULPT DAW.
  La DAW deve aprire 3 tracce (mono/stereo/mono), tutte a tempo zero.
- Controlla `Setup > I/O`: i percorsi SCULPT HW MONO 03, STEREO 05-06 e MONO 08 sono salvati.
  Attualmente la DAW ascolta le tracce su Main; NON devono risultare fisicamente indirizzate.
- Controlla i marker: nomi, ordine e posizioni identici a quelli della cue.
- Controlla che Show riproduca normalmente file e LTC dopo l'apertura della DAW.

## Stato test
Eseguiti su Linux: 130 test Swift del Core completati senza errori; `swiftc -frontend -parse`
sui file app modificati passa. Una vera compilazione/macOS UI/audio va verificata su GitHub e sul Mac.
Nessuna build macOS viene dichiarata eseguita qui.
