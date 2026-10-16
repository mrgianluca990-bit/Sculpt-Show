# Sculpt Show ↔ Sculpt DAW — Routing reale fase 3 (DAW repository)

La DAW dispone di API `setup.io` per creare OutputPath {name, first_channel, format}
e `track.output` per Route::Hardware, ma in `crates/mix/src/lib.rs` la routine
`route_strip` applica solo Route::Main e Route::Bus; qualsiasi route Hardware
finisce nell'else `_ => {}` e perde il segnale. Non è sufficiente un comando CLI.

Intervento DAW richiesto:
1. Renderer multi-output (fino a 64 canali fisici) associato all'IO selezionato.
2. Instradare `Route::Hardware(name)` verso gli esatti canali indicati da OutputPath,
   rispettando la larghezza mono/stereo e le matrici di pan, senza perdere gain/automation.
3. Rendere coerenti monitoring, meter di uscita e file bounce, scegliendo esplicitamente
   tra main mix e hardware sends (no silenzio involontario).
4. Validare device capabilities e collisioni con LTC di Show; salvare UID device e
   canali logici indipendentemente dai device hardware che possono cambiare.
5. Solo DOPO un test multicanale vero (es. Pro Tools Audio Bridge 16), far emettere
   al bridge `track.output {track, output, create_bus:false}` per ogni stem.

Il bridge Show v0.17 crea già output path e commenti con mapping esatto 1-based.
Mantiene inoltre i marker via `markers.add` in posizioni numeriche precise.
