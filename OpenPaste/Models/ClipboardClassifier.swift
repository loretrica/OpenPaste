import Foundation

enum ClipboardClassifier {
    static let supportedCodeLanguages: Set<String> = [
        "Swift", "JavaScript", "TypeScript", "Python", "JSON",
        "SQL", "Shell", "HTML", "CSS"
    ]

    static func normalizeColor(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6,
              hex.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              })
        else { return nil }
        return "#\(hex.uppercased())"
    }

    static func classify(_ text: String) -> ClipboardPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasColorPrefix = trimmed.hasPrefix("#")
        let hasHexLetter = trimmed.unicodeScalars.contains {
            CharacterSet(charactersIn: "abcdefABCDEF").contains($0)
        }
        if (hasColorPrefix || hasHexLetter), let color = normalizeColor(trimmed) {
            return ClipboardPayload(kind: .color, content: text, colorHex: color)
        }
        if URLIdentity.canonicalize(text) != nil {
            return ClipboardPayload(kind: .link, content: text)
        }
        let language = detectedCodeLanguage(in: text)
        return ClipboardPayload(
            kind: language == nil ? .text : .code,
            content: text,
            codeLanguage: language)
    }

    static func normalizeCodeLanguage(_ language: String?) -> String? {
        guard let language,
              let supported = supportedCodeLanguages.first(where: {
                  $0.caseInsensitiveCompare(language) == .orderedSame
              })
        else { return nil }
        return supported
    }

    static func detectedCodeLanguage(in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("\n") else { return nil }
        if (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) != nil {
            return "JSON"
        }
        if value.contains("<") && value.contains(">") && (value.contains("</") || value.hasPrefix("<")) {
            return "HTML"
        }
        if value.contains("interface ") || value.contains("type ") && value.contains(" = ") { return "TypeScript" }
        if (value.contains("struct ") || value.contains("enum ") || value.contains("protocol ")
            || value.contains("func ")) && value.contains("{") {
            return "Swift"
        }
        if value.contains("def ") && value.contains(":") && (value.contains("import ") || value.contains("return ")) {
            return "Python"
        }
        if value.contains("SELECT ") || value.contains("select ") { return "SQL" }
        if value.contains("const ") || value.contains("function ") || value.contains("=>") { return "JavaScript" }
        let cssMarkers = ["color:", "display:", "margin:", "padding:", "font-size:", "background:"]
        if value.contains("{") && value.contains("}")
            && cssMarkers.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
            return "CSS"
        }
        if value.contains("#!/") || value.contains("echo ") { return "Shell" }
        return nil
    }
}
