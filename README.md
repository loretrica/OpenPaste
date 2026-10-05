# OpenPaste

📝 **OpenPaste** è un gestore degli appunti gratuito in sviluppo, ispirato a [Paste](https://pasteapp.io/). È un progetto indipendente e non è affiliato a Paste.

## Stato

OpenPaste conserva gli appunti localmente mentre l’app è in esecuzione, anche quando la pillola è chiusa. La pillola flottante si apre all’avvio o con ⇧⌘V, compare dal basso sul display attivo e occupa la larghezza disponibile con margini laterali. Riceve il focus della tastiera e ripristina l’app precedente alla chiusura con Escape.

La barra contiene ricerca, cronologia, raccolte colorate, aggiunta di una raccolta e menu. Le raccolte scorrono orizzontalmente e si possono riordinare. Le card sono quadrate, con intestazione colorata, icona dell’app sorgente e anteprima del contenuto. L’elemento attivo ha un bordo blu; gli altri elementi selezionati hanno un’indicazione distinta. Sono supportati aspetto chiaro e scuro e vista compatta automatica sotto i 320 pt. L’altezza iniziale è 360 pt; le dimensioni già salvate restano rispettate.

## Contenuti

- Testo semplice e formattato: vengono conservate le rappresentazioni originali RTF/HTML, quando disponibili.
- Link HTTP/HTTPS: URL, titolo, descrizione e immagine di anteprima, quando il sito li fornisce. L’URL resta utilizzabile se il recupero non riesce.
- Immagini: rappresentazioni originali, anteprima e dimensioni.
- File e PDF: riferimenti agli originali con bookmark, anche per gruppi di file. OpenPaste non archivia una copia dei file; se l’originale viene rimosso, il riferimento non può ripristinarlo.
- Codice: rilevamento automatico prudente e scelta manuale di tipo e linguaggio. Linguaggi disponibili: Swift, JavaScript, TypeScript, Python, JSON, SQL, Shell, HTML e CSS.
- Colori HEX: campione del colore e valore normalizzato.

Testo e URL hanno chiavi di deduplicazione stabili. Le ricopie aggiornano data e sorgente e riportano l’elemento all’inizio della cronologia; conservano titolo personalizzato, classificazione manuale e posizione nella raccolta.

## Uso e tastiera

Un clic seleziona una card. Un doppio clic o Invio copia l’elemento attivo, chiude la pillola e lo incolla nell’app precedente. Per l’incolla automatico macOS può richiedere il permesso di inviare eventi: la richiesta avviene alla prima azione, mai all’avvio. Se il permesso manca o l’app di destinazione non è disponibile, il contenuto rimane negli appunti per un incolla manuale.

| Comando | Azione |
| --- | --- |
| ⇧⌘V | Apri o chiudi la pillola |
| ← / → | Card precedente o successiva |
| ⌘↑ / ⌘↓ | Prima o ultima card |
| Invio | Incolla la sola card attiva nell’app precedente |
| ⇧Invio | Incolla come testo semplice |
| ⌘C | Copia la sola card attiva e mantiene aperta la pillola |
| ⌘1…⌘9 | Incolla la card nella posizione corrispondente |
| Spazio | Anteprima; Quick Look per immagini e file |
| ⌘F | Ricerca e filtri |
| Tab | Passa fra campo di ricerca e risultati |
| ⇧← / ⇧→, ⇧clic | Seleziona un intervallo |
| ⌘clic | Aggiungi o rimuovi una card dalla selezione |
| ⌘A | Seleziona tutti gli elementi della vista corrente |
| ⌘R | Rinomina l’elemento attivo |
| ⌘E | Modifica testo o codice |
| ⌘N | Crea un testo nella raccolta corrente o in cronologia |
| ⇧⌘N | Crea una raccolta |
| Cancella | Rimuovi dalla vista corrente |
| Escape | Chiudi prima anteprima/editor, poi ricerca, poi pillola |

La selezione multipla serve per spostare, trascinare o rimuovere più elementi; copia e incolla agiscono sull’elemento attivo. L’editor mantiene la formattazione del testo. Il menu della card permette anche di modificare il tipo e il linguaggio del codice.

Digitare avvia la ricerca globale, che include anche gli elementi conservati solo nelle raccolte. Sono disponibili filtri per tipo, app sorgente e intervallo di date. Invio nel campo passa ai risultati; un secondo Invio incolla la card attiva. Cambiare raccolta azzera ricerca e filtri. La cronologia e i risultati vengono caricati progressivamente.

## Raccolte e trascinamento

Ogni card può appartenere a una sola raccolta e restare anche nella cronologia. Le raccolte hanno nome e colore modificabili e un ordine manuale; anche le card di una raccolta si possono riordinare. I nuovi elementi vengono aggiunti in fondo alla raccolta.

Trascina card sulle raccolte per assegnarle, fra card della stessa raccolta per riordinarle, oppure verso un’altra app per esportare il contenuto nei formati originali. È possibile trascinare contenuti da altre app nella cronologia o in una raccolta. Le operazioni di trascinamento, anteprima, modifica e conferma mantengono aperta la pillola durante l’interazione.

Rimuovere una card dalla raccolta o eliminare la raccolta mantiene le card in cronologia. Se un elemento era già scaduto o assente dalla cronologia, viene rinnovata la sua scadenza senza cambiare la data della copia originale. Cancella nella cronologia rimuove dalla cronologia, preservando gli elementi appartenenti a una raccolta. L’eliminazione definitiva richiede conferma e rimuove anche i dati associati.

## Conservazione

La durata è configurabile: 1 giorno, 1 settimana, 1 mese, 1 anno o per sempre. Il valore iniziale è 1 mese. La durata viene registrata per ogni copia: cambiarla influisce sulle copie successive. Gli elementi scaduti vengono tolti dalla cronologia all’avvio e ogni 24 ore; se appartengono a una raccolta, restano conservati lì.

Il monitor controlla la clipboard ogni 250 ms. Le scritture effettuate da OpenPaste vengono ignorate usando il loro specifico contatore di modifica, senza scartare la successiva copia esterna. L’acquisizione si può sospendere dal menu per 15 minuti, 1 ora o fino alla ripresa manuale. Pausa e arresto non annullano i salvataggi già acquisiti.

## Dati e privacy

Il database SQLite si trova in `~/Library/Application Support/OpenPaste/OpenPaste.sqlite`. GRDB 7 gestisce migrazioni versionate e ricerca full-text FTS5. La migrazione per i nuovi tipi preserva gli identificativi, le chiavi di deduplicazione, le raccolte e l’indice di ricerca; non serve un reset del database.

Le rappresentazioni originali sono salvate separatamente in `~/Library/Application Support/OpenPaste/Assets`, come payload JSON con dati binari codificati. Le immagini delle anteprime dei link sono nella cache locale `~/Library/Caches/OpenPaste/LinkPreviews`. Le letture della lista non caricano i payload binari; vengono recuperati quando servono per anteprima, modifica, copia o trascinamento.

I contenuti non vengono inviati a server OpenPaste. Il recupero dei metadati e delle immagini dei link effettua richieste al sito del link copiato, senza cookie o cache condivisi. Le richieste e i redirect rifiutano URL non HTTP/HTTPS, host locali e indirizzi privati noti; il download delle immagini ha un limite di 5 MB.

Sincronizzazione, collaborazione, OCR, Paste Stack e funzioni AI non sono inclusi.

L’App Sandbox è disattivata nel target, in linea con la distribuzione diretta prevista. Hardened Runtime è attivo; firma Developer ID e notarizzazione restano da configurare prima di distribuire una release.

## Requisiti e avvio

- macOS 27 o successivo, secondo il deployment target Xcode attuale.
- Xcode 27 o successivo con SDK macOS 27 e compilatore Swift 6.
- Dipendenza Swift Package Manager: [GRDB.swift](https://github.com/groue/GRDB.swift), prodotto GRDB.

1. Apri `OpenPaste.xcodeproj` con Xcode.
2. Seleziona lo schema `OpenPaste` e la destinazione My Mac.
3. Premi Run (▶).

Il progetto usa controllo completo della concorrenza e isolamento sul main actor per AppKit e lo stato dell’interfaccia. Per eseguire i test usa Product → Test (⌘U).

Il target OpenPasteTests copre migrazioni, deduplicazione e stabilità delle chiavi, retention e raccolte, payload e formattazione, classificazione, ricerca e filtri, selezione, preferenze, metadati, geometria e ciclo di vita dei servizi. Include il caso di ricerca su 100.000 elementi. OpenPasteUITests verifica ricerca ed Escape, selezione e copia con ⌘C, menu contestuale, anteprima con Spazio e trascinamento nelle raccolte con dati dimostrativi isolati tramite `--ui-testing`: non apre il database personale, non avvia l’acquisizione e usa una clipboard privata. Il test `testLightAndDarkPillSnapshots` allega schermate della pillola nei due temi; `--appearance-light` e `--appearance-dark` forzano l’aspetto solo nella modalità dimostrativa DEBUG. Le anteprime “Pillola chiara” e “Pillola scura” in `ClipboardPanelPreview.swift` usano la stessa fixture isolata con tutti i tipi di card.

## Struttura essenziale

- `OpenPaste/Application/` — avvio, composizione delle dipendenze, menu di stato e fixture dimostrativa.
- `OpenPaste/Database/` — migrazioni, query condivise e repository.
- `OpenPaste/Models/` — dati, classificazione, preferenze e stato osservabile della cronologia.
- `OpenPaste/Services/` — acquisizione, storage dei payload, incolla, trascinamento, Quick Look, rete e finestra.
- `OpenPaste/Views/` — toolbar, selezione, carousel, card, editor e anteprime.
- `OpenPasteTests/` e `OpenPasteUITests/` — test.
- [Docs/PRODUCT_SPEC.md](Docs/PRODUCT_SPEC.md) — direzione UX e schermate di riferimento.

## Licenza

La licenza non è ancora stata definita. Fino alla sua aggiunta, non presumere che il codice sia disponibile per il riutilizzo o la redistribuzione.
