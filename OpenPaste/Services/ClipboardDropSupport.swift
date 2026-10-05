import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipboardDropSupport {
    static let internalItemsType = ClipboardDragTypes.internalItemsType
    private static let colorType = "com.apple.cocoa.pasteboard.color"

    static let acceptedTypes: [String] = [
        internalItemsType.rawValue,
        UTType.fileURL.identifier,
        UTType.image.identifier,
        colorType,
        UTType.url.identifier,
        UTType.sourceCode.identifier,
        UTType.html.identifier,
        UTType.rtf.identifier,
        UTType.plainText.identifier
    ]

    @discardableResult
    static func accept(
        providers: [NSItemProvider],
        onItems: @escaping ([Int64]) -> Void,
        onPayload: @escaping (ClipboardPayload) -> Void
    ) -> Bool {
        let matching = providers.filter { provider in
            acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0) }
        }
        guard !matching.isEmpty else { return false }

        let batch = ClipboardDropBatch(
            expectedResults: matching.count,
            onItems: onItems,
            onPayload: onPayload)
        for (index, provider) in matching.enumerated() {
            load(provider, at: index, into: batch)
        }
        return true
    }

    private static func load(_ provider: NSItemProvider, at index: Int, into batch: ClipboardDropBatch) {
        if provider.hasItemConformingToTypeIdentifier(internalItemsType.rawValue) {
            provider.loadDataRepresentation(forTypeIdentifier: internalItemsType.rawValue) { data, _ in
                let numbers = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [NSNumber]
                Task { @MainActor in batch.complete(index: index, itemIDs: numbers?.map(\.int64Value) ?? []) }
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let nsURL = object as? NSURL,
                      let url = nsURL as URL?
                else {
                    Task { @MainActor in batch.complete(index: index, payload: nil) }
                    return
                }
                let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                let file = ClipboardFileReference(
                    url: url.absoluteString,
                    bookmark: bookmark,
                    name: url.lastPathComponent)
                let payload = ClipboardPayload(kind: .file, content: file.name, files: [file])
                Task { @MainActor in batch.complete(index: index, payload: payload) }
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(colorType) {
            provider.loadDataRepresentation(forTypeIdentifier: colorType) { data, _ in
                guard let data else {
                    Task { @MainActor in batch.complete(index: index, payload: nil) }
                    return
                }
                Task { @MainActor in
                    let color = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSColor.self,
                        from: data)
                    batch.complete(index: index, payload: color.flatMap(makeColorPayload))
                }
            }
            return
        }

        if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                guard let data else {
                    Task { @MainActor in batch.complete(index: index, payload: nil) }
                    return
                }
                let image = NSImage(data: data)
                let rep = image?.representations.first
                let payload = ClipboardPayload(
                    kind: .image,
                    content: "Image",
                    representations: [ClipboardRepresentation(type: imageType, data: data)],
                    imageWidth: rep?.pixelsWide,
                    imageHeight: rep?.pixelsHigh)
                Task { @MainActor in batch.complete(index: index, payload: payload) }
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? URL else {
                    Task { @MainActor in batch.complete(index: index, payload: nil) }
                    return
                }
                let value = url.absoluteString
                let rep = ClipboardRepresentation(
                    type: UTType.url.identifier,
                    data: Data(value.utf8))
                let payload = ClipboardPayload(
                    kind: ClipboardContent.classify(value).kind,
                    content: value,
                    representations: [rep])
                Task { @MainActor in batch.complete(index: index, payload: payload) }
            }
            return
        }

        let sourceType = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .sourceCode) == true
        }
        let richType = provider.registeredTypeIdentifiers.first {
            let type = UTType($0)
            return type?.conforms(to: .rtf) == true || type?.conforms(to: .html) == true
        }
        let typeIdentifier = sourceType ?? richType ?? UTType.plainText.identifier
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data else {
                Task { @MainActor in batch.complete(index: index, payload: nil) }
                return
            }
            let documentType: NSAttributedString.DocumentType?
            if UTType(typeIdentifier)?.conforms(to: .rtf) == true {
                documentType = .rtf
            } else if UTType(typeIdentifier)?.conforms(to: .html) == true {
                documentType = .html
            } else {
                documentType = nil
            }
            let attributedText: String? = documentType.flatMap { type in
                try? NSAttributedString(
                    data: data,
                    options: [.documentType: type],
                    documentAttributes: nil).string
            }
            guard let text = attributedText ?? String(data: data, encoding: .utf8) else {
                Task { @MainActor in batch.complete(index: index, payload: nil) }
                return
            }
            let classified = ClipboardContent.classify(text)
            let payload = ClipboardPayload(
                kind: sourceType == nil ? classified.kind : .code,
                content: text,
                representations: [ClipboardRepresentation(type: typeIdentifier, data: data)])
            Task { @MainActor in batch.complete(index: index, payload: payload) }
        }
    }

    private static func makeColorPayload(_ color: NSColor) -> ClipboardPayload? {
        guard let color = color.usingColorSpace(.deviceRGB),
              let components = color.cgColor.components,
              components.count >= 3
        else { return nil }
        let hex = String(
            format: "#%02X%02X%02X",
            Int((components[0] * 255).rounded()),
            Int((components[1] * 255).rounded()),
            Int((components[2] * 255).rounded()))
        return ClipboardPayload(kind: .color, content: hex, colorHex: hex)
    }
}

@MainActor
private final class ClipboardDropBatch {
    private struct Result {
        var payload: ClipboardPayload?
        var itemIDs: [Int64]
    }

    private let expectedResults: Int
    private let onItems: ([Int64]) -> Void
    private let onPayload: (ClipboardPayload) -> Void
    private var completedResults = 0
    private var results: [Result?]

    init(
        expectedResults: Int,
        onItems: @escaping ([Int64]) -> Void,
        onPayload: @escaping (ClipboardPayload) -> Void
    ) {
        self.expectedResults = expectedResults
        self.onItems = onItems
        self.onPayload = onPayload
        results = Array(repeating: nil, count: expectedResults)
    }

    func complete(index: Int, payload: ClipboardPayload) {
        complete(index: index, result: Result(payload: payload, itemIDs: []))
    }

    func complete(index: Int, itemIDs: [Int64]) {
        complete(index: index, result: Result(payload: nil, itemIDs: itemIDs))
    }

    func complete(index: Int, payload: ClipboardPayload?) {
        complete(index: index, result: Result(payload: payload, itemIDs: []))
    }

    private func complete(index: Int, result: Result) {
        guard results.indices.contains(index), results[index] == nil else { return }
        results[index] = result
        completedResults += 1
        guard completedResults == expectedResults else { return }
        deliverResultsInProviderOrder()
    }

    private func deliverResultsInProviderOrder() {
        let completed = results.compactMap { $0 }
        var seen = Set<Int64>()
        let uniqueItemIDs = completed
            .flatMap { $0.itemIDs }
            .filter { seen.insert($0).inserted }
        if !uniqueItemIDs.isEmpty {
            onItems(uniqueItemIDs)
        }

        var groupedFiles: [ClipboardFileReference] = []
        var didDeliverFileGroup = false
        for result in completed {
            guard let payload = result.payload else { continue }
            guard payload.kind == .file else {
                onPayload(payload)
                continue
            }

            if !didDeliverFileGroup {
                didDeliverFileGroup = true
                groupedFiles = completed
                    .compactMap { $0.payload }
                    .filter { $0.kind == .file }
                    .flatMap { $0.files }
                if groupedFiles.count == 1, let file = groupedFiles.first {
                    onPayload(ClipboardPayload(kind: .file, content: file.name, files: [file]))
                } else if !groupedFiles.isEmpty {
                    onPayload(ClipboardPayload(
                        kind: .file,
                        content: groupedFiles.map { $0.name }.joined(separator: ", "),
                        files: groupedFiles))
                }
            }
        }
    }
}
