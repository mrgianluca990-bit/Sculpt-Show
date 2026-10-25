# SCULPT SHOW — collaudo candidata v1

Data: 25 ottobre 2026 · versione 1.0.0 RC1. La dicitura RC indica una candidata: la promozione finale dipende dal collaudo reale qui sotto.

Questa lista si esegue sullo ZIP consegnato, usando una copia del progetto reale. Annotare Mac/chip, macOS, interfaccia/driver, sample rate/buffer, uscite Monitor/LTC, display/risoluzione e controller. Non modificare queste condizioni tra confronto prima/dopo.

## Problema aperto rilevato nel debugging

**B01 — PLAY LIST resta occupato se il GO fallisce dopo Pre-wait.** Riprodotto sia prima sia dopo il restyling con cue di durata zero. STOP ALL permette di ripartire. Il codice dei motori non è stato modificato: la specifica grafica esclude correzioni funzionali non causate dal restyling. Verificare la correzione con T60 prima della promozione definitiva.

## Ordine consigliato

1. Giro rapido: avvio/salvataggio, inspector, trasporto, 7 stem, loop condizionale + seconda azione, Monitor, MP4 audio e schermo esterno.
2. Regressione completa: tutti i test P0 applicabili al proprio spettacolo, quindi P1.
3. Prova lunga: T58 e doppio passaggio finale. Se gli ID cambiano, usare i titoli «Prova lunga di spettacolo» e «Doppio passaggio completo».

**P0** = blocca la v1 se fallisce; **P1** = da verificare e risolvere/valutare prima del rilascio. Un test non applicabile va segnato N/A con motivazione; un test non eseguito resta DA FARE, mai PASS. Ogni nuovo difetto riproducibile azzera il risultato dei test correlati dopo la correzione.

**Criterio GO v1:** nessun P0 aperto, salvataggio/riapertura e round-trip riusciti, nessun difetto nella prova lunga, test hardware delle funzioni effettivamente usate conclusi. I probe automatici non sostituiscono ascolto, proiezione e trigger fisici.

## Schede di test da eseguire


### Avvio, progetto e salvataggio

- [ ] **T01 · P0 · Avvio pulito** — Estrarre lo ZIP, avviare l’app e aprire un progetto di prova.
  Atteso: Versione 1.0.0 candidata; finestra e comandi completi, nessun errore inatteso.
  Esito: DA FARE · Note: __________

- [ ] **T02 · P0 · Salva e riapri** — Su una copia del progetto modificare nomi, colori, IN/OUT e routing; salvare, chiudere e riaprire.
  Atteso: Dati conservati e media raggiungibili; nessuna cue o regola persa.
  Esito: DA FARE · Note: __________

- [ ] **T03 · P0 · Progetto portabile** — Copiare l’intera cartella del progetto su altro disco/Mac e aprire da lì.
  Atteso: Audio/video trovati nella copia; nessun riferimento obbligatorio alla vecchia posizione.
  Esito: DA FARE · Note: __________

- [ ] **T04 · P1 · Rinomina Cue List** — Rinominare e salvare, poi controllare cartella media e riaprire.
  Atteso: Cartella rinominata senza duplicazione; media, normalizzati e Bridge ancora validi.
  Esito: DA FARE · Note: __________

- [ ] **T05 · P1 · Undo/Redo e Save As** — Da fermo fare modifiche e Undo/Redo; Save As verso nuova cartella.
  Atteso: Stato ripristinato coerentemente; originale conservato e copia autonoma.
  Esito: DA FARE · Note: __________

- [ ] **T06 · P0 · Media mancante** — In una copia sacrificabile rendere indisponibile un media e tentare GO/Preflight.
  Atteso: Errore leggibile e cue rifiutata; nessuna uscita sbagliata o crash.
  Esito: DA FARE · Note: __________

### Interfaccia, restyling e accessibilità

- [ ] **T07 · P0 · Inspector durante play** — Con 7 stem in loop, aprire tutti i gruppi e selezionare 50 volte cue attive/ferme.
  Atteso: Inspector mai vuoto, cue corretta, selezione diversa dal playback riconoscibile.
  Esito: DA FARE · Note: __________

- [ ] **T08 · P0 · Inspector scroll e resize** — Scorrere fino in fondo; cambiare cue, ridimensionare finestra e inspector. Ripetere con Mixer/Waveform/Timecode aperti.
  Atteso: Titoli e campi raggiungibili; nessuna sovrapposizione o comando scomparso.
  Esito: DA FARE · Note: __________

- [ ] **T09 · P1 · Confronto layout** — Confrontare screenshot prima/dopo a 1280×820 e 1100×680 punti.
  Atteso: Stessi controlli, posizioni, dimensioni, testi e ordine; cambiano solo finiture e colori.
  Esito: DA FARE · Note: __________

- [ ] **T10 · P0 · Leggibilità in regia** — In ambiente scuro distinguere GO, STOP e FADE; cue selezionata, Playing, Paused, Waiting, Fading.
  Atteso: Ruoli riconoscibili tramite testi/icone oltre al colore; nessuna confusione tra stop/fade/play.
  Esito: DA FARE · Note: __________

- [ ] **T11 · P1 · Stati dei controlli** — Provare enabled/disabled, selezione, pressione, hover e focus con tastiera; provare Increase Contrast se usato.
  Atteso: Controlli inattivi distinguibili; focus nativo e nomi accessibili conservati.
  Esito: DA FARE · Note: __________

- [ ] **T12 · P1 · Riordino e pannelli** — Trascinare cue e Cue List, aprire Active Cues, tornare a Inspector; chiudere/riaprire i dock.
  Atteso: Identità/regole preservate, nessun comando perso e nessun audio interrotto.
  Esito: DA FARE · Note: __________

- [ ] **T13 · P0 · Digitazione e conferma** — Digitare valori validi/invalidi in General e Video; Invio, Esc, perdita focus; cambiare cue prima di Invio.
  Atteso: Invio conferma una volta; invalidi non applicati; bozze scartate senza finire su altra cue o far sfarfallare il video.
  Esito: DA FARE · Note: __________

- [ ] **T14 · P1 · Shortcut e testo** — Usare Space/Esc/frecce e shortcut di menu; poi digitare gli stessi tasti in un campo.
  Atteso: Trasporto coerente; durante editing i caratteri non lanciano involontariamente cue.
  Esito: DA FARE · Note: __________

### Trasporto, regioni e playlist

- [ ] **T15 · P0 · GO/Pausa/Stop/Fade** — Provare controlli globali, di riga e Active Cues con più cue attive.
  Atteso: Ambito corretto; STOP ALL termina anche Waiting; FADE rispetta durata senza rilanci inattesi.
  Esito: DA FARE · Note: __________

- [ ] **T16 · P0 · Pre-wait cancellabile** — Impostare Pre-wait, GO e STOP prima della scadenza; attendere oltre il ritardo.
  Atteso: La cue non parte dopo STOP; nessuna partenza residua.
  Esito: DA FARE · Note: __________

- [ ] **T17 · P0 · IN/OUT e fade opzionali** — Impostare IN 00:00:02:500 e OUT 00:00:07:750; provare fade disabilitati, poi abilitati separatamente.
  Atteso: GO parte da IN, fine a OUT; fade solo se attivati e riferiti alla regione.
  Esito: DA FARE · Note: __________

- [ ] **T18 · P1 · IN/OUT waveform** — Digitare e trascinare entrambe le maniglie; provare SNAP e valori oltre durata/IN≥OUT.
  Atteso: General e grafico coerenti; intervalli invalidi rifiutati; nessuna modifica durante cue attiva.
  Esito: DA FARE · Note: __________

- [ ] **T19 · P0 · Seek e ripresa** — Seek durante play e pausa, poi ripresa; verificare marker attraversati solo via seek.
  Atteso: Posizione entro IN/OUT, stem allineati; niente regole da marker saltati. Il seek manuale può riarmare con lead, non è una transizione continua.
  Esito: DA FARE · Note: __________

- [ ] **T20 · P0 · AUTO e Auto-follow** — GO con AUTO on/off; Auto-follow alla fine naturale; stop manuale prima della fine.
  Atteso: AUTO cambia selezione soltanto; Auto-follow avvia dopo fine naturale; STOP non lo simula.
  Esito: DA FARE · Note: __________

- [ ] **T21 · P0 · PLAY LIST / Random / Repeat** — Usare 5 cue brevi: ordine normale; poi Random; poi Repeat All. Disabilitare una cue.
  Atteso: Una cue alla volta automaticamente; nessuna ripetizione nel giro Random; Repeat riavvia il giro; cue disabilitata saltata.
  Esito: DA FARE · Note: __________

- [ ] **T22 · P1 · Cambio brano con Rules** — Su Starting usare Fade Out su Cue List con Exclude this cue; GO su altro brano.
  Atteso: Nuovo brano parte e il precedente sfuma senza auto-sfumare la sorgente.
  Esito: DA FARE · Note: __________

### Audio, loop, routing e Monitor

- [ ] **T23 · P0 · Multitraccia simultaneo** — Usare progetto reale 7 stem e almeno una seconda cue audio.
  Atteso: Nessuna deriva tra stem, silenzio inatteso, click o cambio uscita.
  Esito: DA FARE · Note: __________

- [ ] **T24 · P0 · Loop marker semplice** — Due marker, al secondo Fire Itself → Previous marker; ascoltare almeno 100 giri.
  Atteso: Ripartenza immediata senza coda oltre OUT, vuoti o deriva udibile.
  Esito: DA FARE · Note: __________

- [ ] **T25 · P0 · Loop condizionale Playing/Stopped** — Aggiungere condizione su altra cue; avviare/fermare l’altra vicino al confine OUT.
  Atteso: Loop o prosecuzione seguono lo stato; mai blocco, doppio GO o salto udibile.
  Esito: DA FARE · Note: __________

- [ ] **T26 · P0 · Loop con seconda azione** — Sullo stesso marker aggiungere Fire/Stop di un’altra cue e ripetere con condizione.
  Atteso: Ritorno audio continuo; altra azione eseguita una volta per confine. Le azioni sull’altra cue non sono sample-accurate.
  Esito: DA FARE · Note: __________

- [ ] **T27 · P0 · Toggle loop generale** — Durante 7 stem attivare/disattivare Loop until STOP almeno 20 volte, anche vicino a OUT.
  Atteso: Nessun salto al click; disattivazione conclude giro corrente. Valutare separatamente i fallback con LTC/regole non compatibili.
  Esito: DA FARE · Note: __________

- [ ] **T28 · P0 · Sample rate coerente** — Progetto a 48 kHz, importare file 44,1/96 kHz; verificare copie convertite e dispositivo. Ripetere a frequenza supportata diversa da STOP.
  Atteso: Copie coerenti prima di GO, originali preservati; niente SRC live. Preparazione incompleta blocca GO.
  Esito: DA FARE · Note: __________

- [ ] **T29 · P0 · Routing ciclico** — 4 mono su 2 uscite, poi mono1+stereo2/3 su interfaccia adatta.
  Atteso: Destinazioni 1,2,1,2; stereo usa coppia successiva senza obbligo dispari/pari.
  Esito: DA FARE · Note: __________

- [ ] **T30 · P0 · Patch Custom e UID** — Provare coppia stereo fisica non consecutiva, uscita non patchata e profilo su altra scheda.
  Atteso: Mapping esplicito rispettato; route impossibile rifiutata; nessun fallback silenzioso verso 1/2.
  Esito: DA FARE · Note: __________

- [ ] **T31 · P0 · Controlli stem** — Volume/pan/mute/solo/send, reset pan con doppio clic, tooltip nomi lunghi.
  Atteso: Modifiche sullo stem corretto, pan centrato e nome intero raggiungibile.
  Esito: DA FARE · Note: __________

- [ ] **T32 · P0 · Monitor post-fader** — Riservare coppia Monitor; inviare stem e muovere fader, pan e mute.
  Atteso: Mandata segue post-fader; coppia riservata esclusa da pool Automatic; nessun raddoppio.
  Esito: DA FARE · Note: __________

- [ ] **T33 · P0 · MUTE ALL / Exclude Monitor** — Provare Exclude Monitor on/off, master mute/volume Monitor e solo programma.
  Atteso: MUTE ALL conserva Monitor solo se richiesto; controlli Monitor rispettati.
  Esito: DA FARE · Note: __________

- [ ] **T34 · P1 · Scheda a due sole uscite** — Attivare Monitor su 1/2 e poi disattivarlo.
  Atteso: Monitor only senza somma duplicata; programma ritorna quando Monitor è disattivato.
  Esito: DA FARE · Note: __________

- [ ] **T35 · P0 · Meter e clipping** — Segnale controllato su ogni uscita, mute/solo e CLEAR PEAK.
  Atteso: Meter post-route coerenti, RMS/peak/hold leggibili e clip riconoscibile; niente claim true peak oversampled.
  Esito: DA FARE · Note: __________

- [ ] **T36 · P1 · Normalizzazione** — Da fermo normalizzare Peak e LUFS; annullare se disponibile, poi salvare/riaprire.
  Atteso: Nuove copie, originali e riferimenti preservati; risultato coerente con target e preflight.
  Esito: DA FARE · Note: __________

- [ ] **T37 · P0 · Cambio/disconnessione hardware** — Su progetto di prova togliere/cambiare scheda o sample rate durante play, poi riconfigurare da STOP.
  Atteso: Errore visibile e arresto controllato; nessun instradamento silenzioso su dispositivo diverso.
  Esito: DA FARE · Note: __________

### Rules e trigger

- [ ] **T38 · P0 · Regole cumulative** — Show + Cue List + Cue con azioni distinguibili; poi Ignore Show della lista e Ignore parent della cue.
  Atteso: Regole si sommano; esclusioni agiscono solo sui genitori previsti; marker resta locale.
  Esito: DA FARE · Note: __________

- [ ] **T39 · P0 · Condizioni e ritardi** — Playing/Stopped su altra cue; regola ritardata seguita da STOP ALL.
  Atteso: Condizioni valutate correttamente, nessuna azione ritardata residua dopo stop.
  Esito: DA FARE · Note: __________

- [ ] **T40 · P0 · MIDI in/out** — Note e CC di ricezione e invio; nota On/Off, canale corretto, Program Change in uscita; cue diversa selezionata.
  Atteso: Parte la cue associata; messaggi inviati corretti una volta; rilascio non rilancia la cue.
  Esito: DA FARE · Note: __________

- [ ] **T41 · P0 · OSC in/out** — GO per UUID e alias, pause/resume idempotenti, stopAll, status; invio messaggio cue su porta locale e LAN se usata.
  Atteso: Destinazione e valori corretti; zero release ignorato; niente doppi comandi.
  Esito: DA FARE · Note: __________

- [ ] **T42 · P1 · OSC pacchetto errato** — Inviare pacchetto invalido, bundle invalido o porta occupata; poi un comando valido.
  Atteso: Errore/rifiuto leggibile, nessuna esecuzione parziale; ricevitore continua a funzionare.
  Esito: DA FARE · Note: __________

- [ ] **T43 · P0 · Trigger tastiera** — Associare cue, provare combinazioni consentite e conflitti con tasti riservati.
  Atteso: Cue corretta e shortcut globali conservati; niente GO durante digitazione.
  Esito: DA FARE · Note: __________

- [ ] **T44 · P0 · Ricezione LTC fisico** — Arming esplicito, attraversare orario cue, tenere timecode fermo, perdere segnale e riacquisire.
  Atteso: GO al crossing previsto, non ripetuto sul fermo; stato lock leggibile. Non è chase continuo.
  Esito: DA FARE · Note: __________

- [ ] **T45 · P0 · Invio LTC fisico** — Uscita dedicata, start/trim/frame rate, play/pausa/seek/stop e controllo con ricevitore esterno.
  Atteso: Timecode leggibile e offset corretto; nessuna collisione con programma/Monitor; pausa non emette LTC.
  Esito: DA FARE · Note: __________

### Video, immagini e schermi

- [ ] **T46 · P0 · MP4 con audio** — Importare MP4 AAC, attendere preparazione e GO; provare fader/mute e routing soundtrack.
  Atteso: Video e audio incorporato presenti e coerenti con IN/OUT.
  Esito: DA FARE · Note: __________

- [ ] **T47 · P0 · Singolo schermo** — Senza monitor esterno, GO video e immagine; chiudere/riaprire preview.
  Atteso: Finestrella ridimensionabile sempre in primo piano; desktop principale mai annerito; chiusura non ferma cue.
  Esito: DA FARE · Note: __________

- [ ] **T48 · P0 · Secondo schermo reale** — Collegare monitor, scegliere destinazione in Screens, avviare/fermare cue.
  Atteso: Schermo esterno nero a riposo, proiezione fullscreen senza controlli; operatore utilizzabile.
  Esito: DA FARE · Note: __________

- [ ] **T49 · P0 · Trasformazioni** — Keep proportions/Stretch/Crop, zoom oltre 100%, X/Y e incrementi 0,01%, digitazione durante play.
  Atteso: Geometria corretta senza sfarfallii; Invio conferma, proporzioni rispettate nel modo scelto.
  Esito: DA FARE · Note: __________

- [ ] **T50 · P0 · Fade video** — Regione IN/OUT con fade automatici on/off; FADE manuale, pausa/ripresa.
  Atteso: Dissolvenza verso nero riferita a regione e interruttori; audio segue impostazioni effettive.
  Esito: DA FARE · Note: __________

- [ ] **T51 · P0 · Loop video e immagine** — Loop su filmato e immagine con IN/OUT, poi disattivare durante play.
  Atteso: Nessun fermo nero o salto audio periodico; fine del giro corretta.
  Esito: DA FARE · Note: __________

- [ ] **T52 · P0 · Video simultanei** — Due video e un’immagine in contemporanea; fade/stop individuale; provare limite massimo 8.
  Atteso: Compositing e stop indipendenti; capacità oltre limite rifiutata senza interrompere voci già attive.
  Esito: DA FARE · Note: __________

- [ ] **T53 · P1 · Hotplug e schermi duplicati** — Cambiare collegamento display durante prova, verificare duplicazione/Spaces e poi ripristinare.
  Atteso: Nessuna copertura del desktop operatore; destinazione corretta dopo ripristino.
  Esito: DA FARE · Note: __________

### Bridge, preflight e durata

- [ ] **T54 · P0 · Round-trip DAW** — Edit in DAW da cue e waveform; modificare ordine stem e pubblicare ritorno.
  Atteso: Sessione in sottocartella bridge del progetto; marker e identità preservati; routing SHOW segue ordine stem, non routing DAW.
  Esito: DA FARE · Note: __________

- [ ] **T55 · P0 · Ritorno Bridge durante play** — Pubblicare versione aggiornata mentre cue è attiva; poi STOP e applicare.
  Atteso: Cue attiva non sostituita a metà; ritorno applicato al momento consentito senza perdita media.
  Esito: DA FARE · Note: __________

- [ ] **T56 · P1 · Preflight** — Provare media mancante, route non disponibile, collisione LTC/Monitor e progetto valido.
  Atteso: Problemi mostrati con cue identificabile; nessun falso stato di impianto certificato.
  Esito: DA FARE · Note: __________

- [ ] **T57 · P1 · Help e menu** — Aprire tutte le sezioni inspector, Rules, setup, normalizzazione e Help; cercare IN/OUT e stampare HTML.
  Atteso: Funzioni accessibili, testi leggibili, guida offline corretta; dialoghi macOS nativi conservati.
  Esito: DA FARE · Note: __________

- [ ] **T58 · P0 · Prova lunga di spettacolo** — Eseguire progetto reale almeno 2 ore o durata spettacolo maggiore, con cambio cue, loop, video e trigger; registrare uscita.
  Atteso: Nessun crash, dropout, deriva, crescita continua memoria o inspector vuoto. Conservare registrazione e log.
  Esito: DA FARE · Note: __________

- [ ] **T59 · P0 · Doppio passaggio completo** — Eseguire due volte la scaletta reale, poi chiudere/riaprire e riprovare il primo GO.
  Atteso: Esito ripetibile, nessuno stato o comando residuo tra i giri.
  Esito: DA FARE · Note: __________

### Recupero da errore differito

- [ ] **T60 · P0 · Errore dopo Pre-wait (B01)** — Creare cue vuota con durata 0 e Pre-wait 0,1 s; PLAY LIST, attendere errore, correggere durata a 2 s e riprovare PLAY LIST.
  Atteso: errore controllato, playlist liberata e nuovo avvio possibile senza STOP ALL.
  Esito: **BUG RIPRODOTTO sulla candidata e sulla baseline** — attualmente playlist resta occupata; STOP ALL recupera. Da correggere e ricollaudare separatamente dal restyling.

## Segnalazione di un difetto

ID test / versione / progetto / cue e marker / condizioni e altre cue attive / passi numerati / atteso / ottenuto / frequenza (es. 2 volte su 20) / file o registrazione / configurazione hardware. Specificare se resta riproducibile dopo riapertura.

## Limiti da non confondere con bug nuovi

Il restyling non aggiunge funzioni. MTC runtime, chase continuo, genlock e main/backup automatico non sono inclusi. L’editing della regione è sull’intera cue, non sulle regioni indipendenti dei singoli stem. Loop nativi compatibili e fallback a timer hanno garanzie differenti; azioni sulle altre cue non sono sample-accurate. Meter peak/RMS non equivalgono a true peak oversampled. Le finestre di sistema mantengono comportamento e resa macOS.
