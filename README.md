# Sculpt Show 0.5.0 — Cue vuote, IN/OUT e PLAY LIST

Software macOS nativo (13+, Apple Silicon e Intel) indipendente, ispirato a workflow professionali show-control. Non e' un prodotto Merging Technologies e non apre ancora file Ovation `.ovs`/`.ovl`.

## Novita'

- **EMPTY** in ogni cue list: inserisce una cue silenziosa dopo quella selezionata. Durata iniziale 5 s, modificabile nell'inspector (0–3600 s). Il silenzio e' un vero evento: parte con GO, puo' andare in pausa, essere fermato, andare in loop, usare Auto Follow e attivare Rules Starting/Ending/Stopping.
- Nell'inspector: **Attach Audio** trasforma una cue vuota in cue audio senza perderne ID e Rules; **Clear Audio** esegue l'operazione inversa; **Replace Audio** permette di sostituire il file senza ricreare la cue.
- **IN / OUT / DURATION** delle cue audio: regione di lettura non distruttiva. Per esempio, un file lungo 60 s con IN=10 e OUT=25 suona per 15 s. Modificare DURATION aggiorna automaticamente OUT. Reset IN/OUT riporta alla durata integrale del file.
- Nuovi countdown e cursori di avanzamento fanno riferimento alla **durata effettiva** della regione, non necessariamente alla durata del file.
- **PLAY LIST**: inizia dalla cue selezionata (o dalla prima abilitata) e riproduce automaticamente le successive della **stessa lista**, una dopo l'altra. **FIRE** continua a lanciare soltanto la cue scelta. STOP LIST annulla PLAY LIST e le partenze in attesa.
- **RULES (N)** e' ora un pulsante sempre visibile nella testata della cue list; non serve entrare nel menu `...`.
- Le nuove impostazioni si salvano in `.scshow` e sono compatibili con show salvati nelle versioni 0.1–0.4 (vecchi campi mancanti assumono valori predefiniti).

## Test rapido sul Mac

1. Usa **EMPTY**, imposta 3.0 s e aggiungi una regola `Ending -> Fire -> Next Cue`: dopo tre secondi la cue successiva deve partire.
2. Seleziona un audio di 30 s, imposta IN 5 s e OUT 12 s (durata 7 s). Premendo FIRE deve iniziare a 5 s e terminare a 12 s. Il file originale resta intatto.
3. Sulla medesima cue prova il loop con regione IN/OUT: la ripetizione della regione e' gestita da un timer di circa 100 ms e puo' produrre un piccolo salto; **non e' ancora sample accurate**.
4. Aggiungi almeno tre cue, seleziona la prima, premi **PLAY LIST** e controlla l'avanzamento sequenziale. Premi STOP e verifica che non partano altre cue.
5. Apri **RULES (N)** direttamente nella testata, crea una regola, salva e riapri lo show.
6. Apri uno show `.scshow` creato con Sculpt Show 0.4.0: deve mantenere media, regole e parametri.

## Limitazioni tecniche della 0.5

- Non e' ancora un motore audio per applicazioni show-critical: clip boundaries e sequenze dipendono da refresh a 100 ms e da callback di fine file. Per tagli e loop senza artefatti servira' un motore AVAudioEngine/Core Audio con scheduler.
- Regole Ending e PLAY LIST possono voler avviare la stessa cue: il motore evita una seconda partenza se la cue e' gia' attiva, ma per uno show prevedibile e' meglio scegliere **uno dei due metodi** per la sequenza.
- I fade per file tagliati non sono sample-accurate; il fade audio funziona come nella 0.4.
- L'uscita audio e' sempre il dispositivo predefinito; niente routing per-cue multicanale in questa release.
- `.scshow` mantiene riferimenti a percorsi audio assoluti. Non spostare i media senza aggiornare i percorsi.
- Non ci sono ancora timecode, MIDI/OSC, backup ridondante e importazione di show Ovation.
- La build GitHub e' firmata ad-hoc per sviluppo, non notarizzata. Compilare su GitHub prima del test live.

## Compilazione GitHub

Un push su `main` avvia il workflow `.github/workflows/macos-build.yml`, che esegue `swift test`, compila per arm64 e x86_64, crea il bundle `.app` e produce l'artifact **Sculpt-Show-macOS**.

Gli eseguibili devono essere collaudati realmente su macOS: i test del core superati su Linux e il controllo di sintassi Swift non provano che la GUI macOS compili e si comporti correttamente.

© Sculpt Show — implementazione indipendente. Nessun asset o codice proprietario Merging Technologies incluso.
