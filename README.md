# OpenPaste

📝 **OpenPaste** è un progetto in sviluppo con l’obiettivo di diventare un gestore degli appunti gratuito, ispirato a [Paste](https://pasteapp.io/).

L’idea è poter ritrovare e riutilizzare ciò che si copia, senza pagare per le funzioni di base. OpenPaste è un progetto indipendente e non è affiliato a Paste.

> 🚧 **Stato del progetto:** prototipo iniziale. Al momento l’app mostra soltanto la schermata predefinita di SwiftUI (“Hello, world!”). Non registra né mostra la cronologia degli appunti.

## 🎯 Direzione del progetto

Le seguenti funzioni descrivono l’obiettivo di OpenPaste; **non sono ancora disponibili**:

- 📋 Conservare una cronologia degli elementi copiati.
- 🔎 Cercare rapidamente nella cronologia.
- 📌 Contrassegnare gli elementi da riutilizzare spesso.
- ⚡ Rendere rapido l’accesso agli appunti salvati.

La gestione di immagini e altri tipi di contenuto, la sincronizzazione tra dispositivi e le impostazioni di privacy sono ancora da definire.

## ✅ Funzionalità disponibili

Al momento non sono implementate funzioni di gestione degli appunti. Il progetto contiene:

- 🖥️ Un’app macOS basata su SwiftUI con una schermata segnaposto.
- 🧪 Target di test iniziali, ancora senza verifiche funzionali significative.

## 🛠️ Avvio del progetto

1. Apri `OpenPaste.xcodeproj` con Xcode.
2. Seleziona lo schema **OpenPaste**.
3. Scegli **My Mac** come destinazione di esecuzione.
4. Premi **Run** (▶) per compilare e avviare l’app.

Il progetto non dichiara ancora requisiti minimi di versione di macOS o Xcode.

## 🗂️ Struttura essenziale

- `OpenPaste/` — codice dell’app SwiftUI.
- `OpenPasteTests/` — target per i test unitari.
- `OpenPasteUITests/` — target per i test dell’interfaccia.
- `OpenPaste.xcodeproj/` — progetto Xcode.

## 📄 Licenza

La licenza del progetto non è ancora stata definita. Fino alla sua aggiunta, non presumere che il codice sia disponibile per il riutilizzo o la redistribuzione.
