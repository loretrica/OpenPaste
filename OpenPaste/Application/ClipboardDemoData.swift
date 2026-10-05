#if DEBUG
import AppKit
import CoreGraphics

enum ClipboardDemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") }

    static func makeRepository() throws -> ClipboardRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPaste-UI-" + UUID().uuidString, isDirectory: true)
        return ClipboardRepository(
            database: try AppDatabase.makeInMemory(),
            metadataLoader: DemoMetadataLoader(),
            assetStore: FileClipboardAssetStore(directory: directory))
    }

    @MainActor
    static func populate(_ repository: ClipboardRepository) async throws {
        let colors = [("Link utili", "#FF3B30"), ("Codice", "#FF9500"), ("Design", "#AF52DE")]
        var collectionIDs: [Int64] = []
        for (name, color) in colors {
            let collection = try await repository.createCollection(name: name)
            if let id = collection.id {
                try await repository.updateCollection(collectionID: id, name: name, colorHex: color)
                collectionIDs.append(id)
            }
        }
        let text = "OpenPaste salva quello che copi. Seleziona una card e premi Invio per riutilizzarla. Puoi anche trascinarla in una raccolta."
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor
        ])
        let richData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let image = NSImage(size: NSSize(width: 600, height: 420))
        image.lockFocus()
        NSGradient(colors: [.systemTeal, .systemBlue, .systemIndigo])?.draw(
            in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 420)), angle: 35)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: 280, y: 180, width: 220, height: 220)).fill()
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: NSRect(x: 80, y: 40, width: 280, height: 280)).fill()
        image.unlockFocus()
        let imageData = image.tiffRepresentation ?? Data()

        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenPaste-demo-" + UUID().uuidString + ".pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 560)
        if let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 560))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 30, y: 300, width: 340, height: 180))
            context.endPDFPage()
            context.closePDF()
        }
        let bookmark = try? pdfURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let payloads: [(ClipboardPayload, String, Int?)] = [
            (ClipboardPayload(kind: .text, content: text,
                representations: [.init(type: "public.rtf", data: richData)]), "com.apple.Notes", nil),
            (ClipboardPayload(kind: .link, content: "https://example.com/openpaste"), "com.apple.Safari", 0),
            (ClipboardPayload(kind: .code, content: "struct Greeting: View {\n    var body: some View {\n        Text(\"Ciao, OpenPaste\")\n    }\n}", codeLanguage: "Swift"), "com.apple.dt.Xcode", 1),
            (ClipboardPayload(kind: .color, content: "#FFC777", colorHex: "#FFC777"), "com.apple.TextEdit", 2),
            (ClipboardPayload(kind: .image, content: "Immagine demo",
                representations: [.init(type: "public.tiff", data: imageData)],
                imageWidth: 600, imageHeight: 420), "com.apple.Photos", 2),
            (ClipboardPayload(kind: .file, content: "Documento demo.pdf",
                files: [.init(url: pdfURL.absoluteString, bookmark: bookmark, name: "Documento demo.pdf")]), "com.apple.finder", nil)
        ]
        for (index, sample) in payloads.enumerated() {
            if let item = try await repository.recordCopy(
                sample.0, sourceAppBundleID: sample.1,
                copiedAt: .now.addingTimeInterval(Double(-index * 60)), retentionPolicy: .forever),
               let id = item.id, let collectionIndex = sample.2,
               collectionIDs.indices.contains(collectionIndex) {
                try await repository.moveItems(
                    ids: [id], to: collectionIDs[collectionIndex],
                    retentionPolicy: .forever, now: .now)
            }
        }
    }

    private struct DemoMetadataLoader: LinkMetadataLoading {
        func metadata(for url: URL) async throws -> ClipboardLinkMetadata? {
            ClipboardLinkMetadata(title: "OpenPaste: tutto quello che copi", description: "Un link di esempio per la UI.")
        }
    }
}
#endif
