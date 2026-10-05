import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardTextNormalizer {
    static func acceptedContent(_ content: String?) -> String? {
        guard let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return content
    }
}

@MainActor
protocol ClipboardPasteboardReading: AnyObject {
    var changeCount: Int { get }
    func payloadContents() -> ClipboardPayload?
    var sourceApplicationBundleIdentifier: String? { get }
}

@MainActor
final class AppKitClipboardPasteboardReader: ClipboardPasteboardReading {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    var sourceApplicationBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func payloadContents() -> ClipboardPayload? {
        let items = pasteboard.pasteboardItems ?? []
        var representations: [ClipboardRepresentation] = []
        for item in items {
            for type in item.types where isPublicRepresentation(type) {
                guard let data = item.data(forType: type) else { continue }
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
        }

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = fileURLs.map { url in
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            return ClipboardFileReference(
                url: url.absoluteString,
                bookmark: bookmark,
                name: url.lastPathComponent)
        }

        if !files.isEmpty {
            return ClipboardPayload(
                kind: .file,
                content: files.map(\.name).joined(separator: "\n"),
                representations: representations,
                files: files)
        }

        let text = ClipboardTextNormalizer.acceptedContent(
            pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: .URL))
        let imageData = representations.first { type in
            UTType(type.type)?.conforms(to: .image) == true
        }?.data
        if let imageData {
            let image = NSImage(data: imageData)
            let rep = image?.representations.first
            let size = rep?.pixelsWide ?? Int(image?.size.width ?? 0)
            let height = rep?.pixelsHigh ?? Int(image?.size.height ?? 0)
            return ClipboardPayload(
                kind: .image,
                content: text ?? "Image",
                representations: representations,
                imageWidth: size > 0 ? size : nil,
                imageHeight: height > 0 ? height : nil)
        }

        if let color = pasteboard.readObjects(forClasses: [NSColor.self], options: [:])?.first as? NSColor,
           let hex = Self.hexColor(color) {
            return ClipboardPayload(
                kind: .color,
                content: hex,
                representations: representations,
                colorHex: hex)
        }

        guard let text else { return nil }
        let classified = ClipboardContent.classify(text)
        let isSourceCode = items.contains { item in
            item.types.contains { UTType($0.rawValue)?.conforms(to: .sourceCode) == true }
        }
        return ClipboardPayload(
            kind: isSourceCode ? .code : classified.kind,
            content: text,
            representations: representations,
            codeLanguage: isSourceCode ? nil : nil)
    }

    private func isPublicRepresentation(_ type: NSPasteboard.PasteboardType) -> Bool {
        guard let uniformType = UTType(type.rawValue) else { return false }
        return uniformType.isPublic || uniformType.conforms(to: .fileURL)
    }

    private static func hexColor(_ color: NSColor) -> String? {
        guard let converted = color.usingColorSpace(.deviceRGB),
              let components = converted.cgColor.components,
              components.count >= 3
        else { return nil }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
