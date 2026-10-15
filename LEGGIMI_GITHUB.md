# Sculpt Show × Cue Native — compilazione su GitHub Actions

Questa consegna non richiede di compilare sul Mac. Serve solo a pubblicare il codice della **Convergenza 0.1** sul tuo repository GitHub `mrgianluca990-bit/Sculpt-Show` su un ramo separato.

## Un solo comando per pubblicare

Estrai lo ZIP nella cartella Download. In Terminale incolla:

```bash
cd ~/Downloads/Sculpt_Show_GitHub_Convergenza_0_1
bash PUBBLICA_E_COMPILA_SU_GITHUB.command
```

Il comando:
1. Scarica Sculpt Show dal repository GitHub.
2. Crea il ramo `convergence/cue-native-0.5.2` partendo dalla revisione Show verificata `d57440a2dcce43097b9672aec8e52393d61a3dfc`.
3. Verifica gli hash dei 3 file Show coinvolti **prima** di modificarli.
4. Applica l'integrazione MUTE/SOLO 64ch usando il MatrixMixer già presente in Show.
5. Crea un commit e tenta il push nel tuo GitHub. **Non tocca il ramo `main`.**
6. Se GitHub CLI (`gh`) è autenticato sul Mac, avvia anche la compilazione automatica con `workflow_dispatch`.

Se `gh` non è installato, la pubblicazione funziona comunque. Per avviare la compilazione apri:

**https://github.com/mrgianluca990-bit/Sculpt-Show/actions/workflows/macos-build.yml**

Seleziona **Run workflow**, scegli il ramo `convergence/cue-native-0.5.2` e premi **Run workflow**.

Il workflow esistente `macos-build.yml` di Show esegue `swift test`, compila su `macos-15`, verifica l'app e carica l'artifact **Sculpt-Show-macOS**. A conclusione apri la singola esecuzione e scarica l'artifact.

## Accesso GitHub

Devi poter eseguire `git push` sul repository. Se Git richiede autenticazione o rifiuta il push, usa GitHub Desktop per pubblicare il branch, oppure configura il GitHub CLI (`gh auth login`). Non inserire token o password in questa chat.

La connessione GitHub disponibile in ChatGPT consente la lettura ma ha rifiutato la creazione del branch (HTTP 403), quindi questa pubblicazione deve essere autorizzata dal tuo ambiente GitHub.

## Stato

Convergenza 0.1: MUTE/SOLO sulle 64 uscite, SOLO multiplo, Reset M/S, banchi da 16, nomi con Invio. **Non ci sono ancora meter Peak/RMS integrati dentro Show.**

Il backend precedente di Show resta invariato per clock condiviso, multi-stem, routing delle singole tracce, Rule, MIDI, cue list e formato `.scshow`.

Questa patch si applica esclusivamente alla revisione Show indicata, non automaticamente a versioni successive. Se la build GitHub non compila, conserva il log del job e non sostituire l'app Show stabile.
