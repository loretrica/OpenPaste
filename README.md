# OpenPaste

📝 **OpenPaste** è un gestore degli appunti gratuito in sviluppo, ispirato a [Paste](https://pasteapp.io/). È un progetto indipendente e non è affiliato a Paste.

## Stato

OpenPaste acquisisce automaticamente testo e link copiati mentre l’app è in esecuzione, anche se la mega pill è chiusa, e li salva nel database locale. La pillola flottante si apre all’avvio o con ⇧⌘V, compare dal basso sul display attivo e si chiude con Escape o clic esterno. Riducendone l’altezza passa automaticamente alla vista compatta.

## Funzioni disponibili

- Database SQLite locale tramite GRDB 7, con migrazioni versionate e indice full-text FTS5.
- Supporto dati per testo e link HTTP/HTTPS, con deduplicazione del testo esatto e degli URL normalizzati.
- Le copie successive dello stesso contenuto aggiornano data, sorgente e posizione nella cronologia.
- Ricerca reattiva di contenuto, titolo e descrizione dei link.
- Conservazione configurabile: 1 giorno, 1 settimana, 1 mese, 1 anno o per sempre. Il valore iniziale è 1 mese.
- API per osservare e gestire raccolte, assegnarvi un elemento, rimuoverlo dalla cronologia e cancellarlo definitivamente.
- Recupero asincrono di titolo e descrizione per i link; se il recupero fallisce, l’URL resta salvato.
- Provenienza dell’ultima copia tramite bundle ID dell’app sorgente.
- Scorciatoia globale iniziale ⇧⌘V e comando di pausa nel menu di stato (15 minuti, 1 ora o fino alla ripresa manuale).
- Preferenze locali per retention, dimensioni della pillola e scorciatoia; le dimensioni vengono ripristinate alla prossima apertura.
- Vista compatta automatica sotto i 320 pt di altezza.

La retention viene registrata per ogni copia: cambiare la durata influisce sulle copie successive e non rimuove quelle già presenti. Gli elementi scaduti vengono tolti dalla cronologia all’avvio e ogni 24 ore mentre l’app è in esecuzione; se appartengono a una raccolta, restano conservati lì.

Il monitor controlla gli aggiornamenti della clipboard ogni 250 ms mentre l’app è in esecuzione; legge il testo e ignora i contenuti vuoti. Per metadati dei link rifiuta gli host locali e gli indirizzi privati noti. Immagini, file, sincronizzazione, collaborazione e filtri per app sorgente non sono inclusi.

## Dati e privacy

Il database si trova in ~/Library/Application Support/OpenPaste/OpenPaste.sqlite. I contenuti vengono conservati localmente e non inviati a server OpenPaste. Per recuperare i metadati, l’app effettua una richiesta HTTP/HTTPS al sito del link copiato. Le richieste non usano cookie o cache condivisi.

L’App Sandbox è disattivata nel target, in linea con la distribuzione diretta prevista. Hardened Runtime è attivo; firma Developer ID e notarizzazione restano da configurare prima di distribuire una release.

## Requisiti

- macOS 27 o successivo, secondo il deployment target Xcode attuale.
- Xcode 16 o successivo e compilatore Swift 6, richiesti da GRDB 7.
- Dipendenza Swift Package Manager: [GRDB.swift](https://github.com/groue/GRDB.swift), prodotto GRDB.

## Avvio

1. Apri OpenPaste.xcodeproj con Xcode.
2. Seleziona lo schema OpenPaste.
3. Scegli My Mac come destinazione.
4. Premi Run (▶).

Il target test OpenPasteTests include test per deduplicazione, retention, raccolte, ricerca reattiva, concorrenza e ricerca su 100.000 elementi.

## Documentazione

- [Docs/PRODUCT_SPEC.md](Docs/PRODUCT_SPEC.md) — requisiti, direzione UX, stato attuale, priorità, criteri di accettazione e schermate di riferimento anonimizzate.

## Struttura essenziale

- OpenPaste/Database/ — migrazioni SQLite e repository.
- OpenPaste/Models/ — modelli e stato osservabile SwiftUI.
- OpenPaste/Services/ — monitor della clipboard e recupero dei metadati dei link.
- OpenPasteTests/ — test del database e dell’interfaccia.
- OpenPaste.xcodeproj/ — progetto Xcode.

## Licenza

La licenza non è ancora stata definita. Fino alla sua aggiunta, non presumere che il codice sia disponibile per il riutilizzo o la redistribuzione.
