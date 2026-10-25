# SCULPT SHOW 1.0.0 RC1 — restyling e audit pre-v1

25 ottobre 2026. Baseline: f77c7209c9b3fbaf9ce3221625b95a2e3347d68a (0.24.1 RC2). Questa è una candidata, non una certificazione della v1 finale.

## Esito del debugging

**B01 aperto — errore differito dopo Pre-wait lascia PLAY LIST occupato.** Caso minimo: cue vuota, durata 0, Pre-wait 0,1 s, PLAY LIST; dopo l’errore portare durata a 2 e riprovare PLAY LIST. Nessuno snapshot attivo, ma la lista conserva il riferimento alla cue e non riparte; STOP ALL recupera. Riprodotto sulla baseline e sulla versione restilizzata con `PrewaitFailureAudit.swift`.

Causa osservata: il Task di Pre-wait rimuove lo snapshot e ignora il false restituito da `playImmediately`; la notifica di fallimento non libera `ShowStore.playingLists`. Il codice di scheduling/motore non è stato modificato, come richiesto dalla specifica estetica. Da correggere in intervento funzionale separato e ricollaudare con T60 prima della promozione finale.

Nessun altro difetto riprodotto nelle regressioni eseguite. Non equivale ad assenza di bug. Il vuoto intermittente dell’inspector segnalato in precedenza richiede ancora la verifica sul progetto utente, anche se il suo layout corretto è stato preservato.

## Audit e cambiamenti grafici

- Tema statico `SculptTheme.swift`: antracite freddo, ambra, bianco caldo nei campi, grigio metallico, turchese selezioni, rosso arresti/errori; colori tecnici verde/ambra/clip preservati come significato.
- Workspace e Cue List: superfici, bordi e selezione; GO turchese, STOP rosso, FADE ambra. Testi, icone, comandi e azioni invariati.
- Inspector, waveform, marker, mixer Input/Output/Monitor: colori coerenti; nessuna modifica alle forme d’onda, scale meter, soglie, pan o routing.
- Rules, patch, trigger, LTC, preflight, campi numerici e Help: accenti ereditati o token tema; i pannelli e dialoghi nativi conservano controlli efficienti e focus di macOS.
- Rimosso il vecchio bagliore sulle spunte M/S del mixer; nessuna ombra o animazione aggiunta. Una finitura hover sperimentale è stata scartata per il costo misurato. Hover/focus nativi restano quelli della piattaforma; niente nuova infrastruttura eventi estetici.
- Nessuna texture raster, blur, filtro dinamico, nuovo timer, polling o pubblicazione aggiunti. Le finiture sono piatte e leggere; nessun caricamento di font.

Il mockup ha guidato palette e finitura: non ne sono stati copiati tabs, layout o funzioni. Nessun intervento su DAW, Sculpt Video o roadmap.

## Layout e perimetro protetto

`QA/verify-restyle-scope.py` confronta ogni chiamata a frame/padding/offset/position/font/controlSize/fixedSize/layoutPriority ecc. con la baseline e verifica hash dei file Core/C, motori, stato, dispositivi, messaggi, Bridge e controllo pan. **PASS: nessuna geometria/tipografia cambiata, nessun file protetto modificato.** Il controllo è integrato nel build script macOS.

Screenshot hosted AppKit/SwiftUI a 1280×820 e 1100×680 punti, Retina 2×: stesso progetto sintetico, quattro cue, prima con sette stem, inspector 346 punti, stesso dispositivo a due uscite/48 kHz. Prima/dopo acquisiti a STOP, senza cambiare modello o selezione. Sono snapshot dell’app reale ospitata in una finestra di prova, non ricostruzioni del mockup.

## Regressioni eseguite

**213 controlli locali superati sia prima sia dopo**: 13 formati/fade/Invio, 17 editing inspector, 2 pubblicazioni/meter/LTC display, 93 IN/OUT/loop audio-video-immagine e Store, 63 proiezione/audio MP4/compositing/loop, 22 MIDI virtuale e UDP OSC, 3 Help offline. I numerosi campioni temporali del probe regioni contano nei 93 controlli; non sono 93 scenari hardware distinti.

Build Debug e Release arm64/x86_64 riuscite. La suite XCTest completa e le verifiche del pacchetto del commit finale sono registrate nella checklist di consegna, senza confonderle con il collaudo fisico.

## Confronto prestazioni

Hosted workspace Debug, stesso Mac/device, 7 stem stereo; secondo carico con un MP4 aggiuntivo e audio. Sei prove per versione: tre da 8 s per carico, cambio cue ogni ~1 s; warm-up prima di ogni campione. CPU è percentuale di un core del processo intero e può superare 100. Il p95 misura il ritardo di risveglio di un Task sul MainActor oltre 20 ms: proxy di reattività, **non latenza click-to-frame né FPS**.

| Configurazione | Prima CPU % | Dopo CPU % | Prima p95 ms | Dopo p95 ms |
|---|---:|---:|---:|---:|
| 7-stems | 110.82 | 109.87 | 15.16 | 18.88 |
| 7-stems+video | 112.42 | 112.51 | 16.86 | 19.95 |

Aggiornamenti globali durante il playback: **0** in ogni prova. Picco RSS prima 166,61 MiB, dopo 166,81 MiB (+0,20 MiB); non cresce attraverso i sei campioni, ma non è una misura delle singole allocazioni né una prova lunga di assenza leak. La ripetizione della baseline ha dato 162,38 MiB, CPU 109,99/111,64% e p95 25,57/21,08 ms: esiste variabilità tra processi e sessioni. Una prima prova di ricontrollo della baseline è iniziata a ridosso della compilazione; va trattata come dato supplementare, non come unico confronto controllato.

CPU finale vicina o inferiore al primo confronto; p95 finale nell’intervallo osservato nelle baseline, ma superiore alla prima mediana. Non dichiariamo assenza assoluta di regressioni misurabili: i campioni brevi e Debug non sostituiscono Instruments, misure GPU/frame e collaudo Release sul Mac dell’utente. Non sono state alterate frequenze di pubblicazione, callback o buffer per migliorare artificialmente le misure. Il criterio prestazionale rigoroso della specifica resta da concludere con la prova lunga e l’interfaccia reale.

I JSON grezzi e gli screenshot sono nel dossier V1-QA. Le prove hover sperimentali non rappresentano il pacchetto consegnato.

## Differenze residue dal riferimento

Layout e dimensioni originari conservati; nessuna pagina o matrice aggiunta dal mockup. Niente texture decorative o effetti luminosi costosi. Menu, file picker, focus, slider e pan nativi restano macOS. Non aggiunti MTC/chase/genlock/main-backup. Immagini e preview mostrano i media del progetto, non la foto dimostrativa.

## Decisione di rilascio

Restyling pronto per collaudo della candidata. **V1 definitiva: non ancora promossa**, per B01 e per test fisici/prova lunga ancora aperti. Il piano contiene 60 schede con atteso, priorità ed esito da compilare; ascolto, interfaccia multicanale, LTC/MIDI fisici, LAN e display esterno non sono dichiarati completati.
