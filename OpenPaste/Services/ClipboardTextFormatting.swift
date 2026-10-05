import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipboardTextFormatting {
    static func attributedText(from payload: ClipboardPayload) -> NSAttributedString {
        if let richText = payload.representations.first(where: { format(for: $0.type) == .rtf }),
           let attributed = decode(richText.data, documentType: .rtf) {
            return attributed
        }
        if let html = payload.representations.first(where: { format(for: $0.type) == .html }),
           let attributed = decode(html.data, documentType: .html) {
            return removingImporterParagraphTerminator(from: attributed, canonicalContent: payload.content)
        }
        return NSAttributedString(string: payload.content)
    }

    static func updatedPayload(
        _ original: ClipboardPayload,
        text: NSAttributedString,
        language: String?
    ) throws -> ClipboardPayload {
        var updated = original
        updated.content = text.string
        updated.kind = language == nil ? .text : .code
        updated.codeLanguage = ClipboardClassifier.normalizeCodeLanguage(language)
        updated.colorHex = nil

        let hasRichFormat = original.representations.contains {
            let format = format(for: $0.type)
            return format == .rtf || format == .html
        }
        var hasPlainText = false
        var representations: [ClipboardRepresentation] = []
        for representation in original.representations {
            switch format(for: representation.type) {
            case .rtf:
                representations.append(ClipboardRepresentation(
                    type: representation.type,
                    data: try encode(text, documentType: .rtf)))
            case .html:
                representations.append(ClipboardRepresentation(
                    type: representation.type,
                    data: try encode(text, documentType: .html)))
            case .plainText:
                hasPlainText = true
                representations.append(ClipboardRepresentation(
                    type: representation.type,
                    data: Data(text.string.utf8)))
            case nil:
                if representation.type.lowercased() != "com.apple.flat-rtfd",
                   !isTextRepresentation(representation.type) {
                    representations.append(representation)
                }
            }
        }

        if hasRichFormat && !hasPlainText {
            representations.append(ClipboardRepresentation(
                type: "public.utf8-plain-text",
                data: Data(text.string.utf8)))
        }
        updated.representations = representations
        return updated
    }

    private enum RepresentationFormat {
        case rtf
        case html
        case plainText
    }

    private static func format(for type: String) -> RepresentationFormat? {
        switch type.lowercased() {
        case "public.rtf", "text/rtf":
            .rtf
        case "public.html", "text/html":
            .html
        case "public.utf8-plain-text", "public.plain-text", "text/plain", "nsstringpboardtype":
            .plainText
        default:
            nil
        }
    }

    private static func isTextRepresentation(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .text) == true
    }

    private static func decode(
        _ data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil)
    }

    private static func removingImporterParagraphTerminator(
        from attributed: NSAttributedString,
        canonicalContent: String
    ) -> NSAttributedString {
        guard attributed.string == canonicalContent + "\n" else {
            return attributed
        }

        let normalized = NSMutableAttributedString(attributedString: attributed)
        normalized.deleteCharacters(in: NSRange(location: normalized.length - 1, length: 1))
        return normalized
    }

    private static func encode(
        _ text: NSAttributedString,
        documentType: NSAttributedString.DocumentType
    ) throws -> Data {
        try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: documentType])
    }
}
