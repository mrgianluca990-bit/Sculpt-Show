# Sculpt Show 0.4.0 — Interaction Rules

Independent macOS cue player (macOS 13+, Intel and Apple Silicon). This is an independently authored functional reimplementation, **not** Merging Ovation and **not** compatible with its proprietary project files.

## Novita della 0.4

Un nuovo editor **Interaction Rules** implementa i trigger **Starting**, **Ending** e **Stopping** con azioni sui target seguenti:

- **Fire**, **Stop**, **Pause**, **Fade Out**, **Select**, **Dim**, **Restore Gain**.
- Target **Next Cue**, **Previous Cue**, **Itself**, **Specific Cue**, **Cue List**, **All Cues**.
- Ritardo per regola 0–30 s dall'interfaccia (modello fino a 600 s).
- Condizioni opzionali sullo stato di un'altra cue: Playing, Paused, Waiting, Stopped.
- Override per-rule di Fade In (azione Fire) e Fade Out (azione Fade); Dim in dB.
- Regole definite separatamente a livello **Show**, **Cue List** e **Cue**; flag **Ignore Show and Cue List rules** nelle singole cue.
- Editor Rules: crea, modifica, riordina, rimuovi, attiva/disattiva e salva le regole.
- Le regole vengono incluse nel file `.scshow` e i vecchi show senza regole restano leggibili.
- Protezioni: Anti-runaway a 64 eventi al secondo; STOP ALL annulla cue in attesa e regole temporizzate; STOP LIST annulla regole temporizzate che puntano alla lista.

### Apertura editor

- **Show Rules** nella barra in alto: regole globali.
- Menu `...` nell'intestazione di una Cue List > **Edit List Rules...**.
- Seleziona una cue > Cue Inspector > **Edit Interaction Rules**.

**Importante:** in un editor vuoto, configura la regola e premi **Add Rule**, quindi **Save Rules**. Su una regola esistente modifica i parametri e premi **Update Rule** o direttamente **Save Rules**. Cambiare selezione senza aggiornare scarta solo la bozza.

### Esempi pratici

1. Cue di apertura: `When Ending → Fire Next Cue` (eventuale fade-in dell'altra cue).
2. Cue annuncio: `When Starting → Dim All Cues` a -18 dB; un'altra cue puo' usare `Restore Gain`.
3. Passaggio scena: `When Starting → Fade Out Specific Cue`, fade-out 3 s.
4. Cue lancio: `When Starting → Fire Cue List` (la prima cue abilitata della lista scelta), eventualmente After 2 s.
5. Condizione: `Only if` una cue scelta e' `Paused`, allora `Fire Next Cue`.

### Semantica degli eventi

- **Starting:** nel momento in cui parte davvero l'audio (dopo un eventuale Pre-Wait).
- **Ending:** solo al termine naturale del file non in loop.
- **Stopping:** a seguito dello STOP manuale o all'avvio del Fade Out, **non** durante STOP ALL / STOP LIST di emergenza.
- Le regole globali e di lista vengono valutate insieme alle regole della singola cue; il flag Ignore Parents esclude globali e lista. Non e' un clone 1:1 della precedenza di Ovation.
- Le regole con ritardo vengono eseguite con timer di sistema (`Task.sleep`) e **non sono sample-accurate**. Non sono ancora implementate regole sui marker, riferimenti a timecode, controlli MIDI/OSC, automazione snapshot o routing fisico multicanale.
- L'opzione legacy **Auto-follow next cue** resta operativa; disattivala se usi una regola Ending → Fire Next Cue per evitare configurazioni ridondanti.

## Compilazione

GitHub Actions su push di `main` esegue `bash Scripts/build-macos.sh`, lancia i test e crea l'artifact `Sculpt-Show-macOS` che contiene un'app `.app` ZIP.

Oppure apri `Package.swift` in Xcode 15+ e avvia `SculptShow` su My Mac.

**Build 0.4:** il modello ha superato i test su Linux, e i sorgenti macOS sono stati controllati sintatticamente; il bundle SwiftUI e il playback devono ancora essere validati sulla build GitHub/macOS.

## Stesse limitazioni delle versioni precedenti

- Output del dispositivo audio predefinito (non c'e' routing per-cue sulle uscite Core Audio).
- Gli show `.scshow` salvano percorsi media assoluti; tenere i WAV/AIFF/MP3 in posizioni stabili.
- Prototipo non notarizzato, non raccomandato come unico riproduttore per show critici.
- Gli show Ovation `.ovs`/`.ovl` non sono importabili nella 0.4.

Il codice non include software o asset proprietari di Merging Technologies.
