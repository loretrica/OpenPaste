import AppKit
import Testing
@testable import OpenPaste

@MainActor
struct ClipboardInteractionTests {
    @Test
    func pasteboardWriteExportsEachReferencedFile() {
        let pasteboard = privatePasteboard()
        let service = ClipboardPasteService(pasteboard: pasteboard)
        let payload = ClipboardPayload(
            kind: .file,
            content: "Two files",
            files: [
                ClipboardFileReference(url: URL(fileURLWithPath: "/tmp/first.txt").absoluteString),
                ClipboardFileReference(url: URL(fileURLWithPath: "/tmp/second.txt").absoluteString)
            ])

        service.write(payload)

        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.compactMap { $0.string(forType: .fileURL) }.sorted() == [
            URL(fileURLWithPath: "/tmp/first.txt").absoluteString,
            URL(fileURLWithPath: "/tmp/second.txt").absoluteString
        ].sorted())
    }

    @Test
    func pasteboardWritePreservesRTFAndHTMLRepresentations() {
        let pasteboard = privatePasteboard()
        let service = ClipboardPasteService(pasteboard: pasteboard)
        let rtf = Data(#"{\rtf1\ansi Rich text}"#.utf8)
        let html = Data("<b>Rich text</b>".utf8)
        let payload = ClipboardPayload(
            kind: .text,
            content: "Rich text",
            representations: [
                ClipboardRepresentation(type: "public.rtf", data: rtf),
                ClipboardRepresentation(type: "public.html", data: html)
            ])

        service.write(payload)

        let item = pasteboard.pasteboardItems?.first
        #expect(item?.data(forType: NSPasteboard.PasteboardType("public.rtf")) == rtf)
        #expect(item?.data(forType: NSPasteboard.PasteboardType("public.html")) == html)
    }

    @Test
    func editedContentOverridesStalePlainTextRepresentation() {
        let pasteboard = privatePasteboard()
        let service = ClipboardPasteService(pasteboard: pasteboard)
        let payload = ClipboardPayload(
            kind: .text,
            content: "Edited content",
            representations: [
                ClipboardRepresentation(
                    type: "public.utf8-plain-text",
                    data: Data("Captured content".utf8)),
                ClipboardRepresentation(
                    type: "public.html",
                    data: Data("<b>Captured content</b>".utf8))
            ])

        service.write(payload)

        let item = pasteboard.pasteboardItems?.first
        #expect(item?.string(forType: .string) == "Edited content")
        #expect(item?.data(forType: NSPasteboard.PasteboardType("public.html")) == Data("<b>Captured content</b>".utf8))
    }

    @Test
    func plainTextWriteDropsRichRepresentations() {
        let pasteboard = privatePasteboard()
        let service = ClipboardPasteService(pasteboard: pasteboard)
        let payload = ClipboardPayload(
            kind: .text,
            content: "Plain text",
            representations: [
                ClipboardRepresentation(type: "public.rtf", data: Data(#"{\rtf1 rich}"#.utf8)),
                ClipboardRepresentation(type: "public.html", data: Data("<b>rich</b>".utf8))
            ])

        service.write(payload, plainText: true)

        let item = pasteboard.pasteboardItems?.first
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(item?.string(forType: .string) == "Plain text")
        #expect(item?.data(forType: NSPasteboard.PasteboardType("public.rtf")) == nil)
        #expect(item?.data(forType: NSPasteboard.PasteboardType("public.html")) == nil)
    }

    @Test
    func keyboardMapperRoutesNavigationAndPasteModifiers() throws {
        let commandUp = try keyEvent(keyCode: 126, flags: [.command])
        let commandDown = try keyEvent(keyCode: 125, flags: [.command])
        let enter = try keyEvent(keyCode: 36)
        let shiftedEnter = try keyEvent(keyCode: 36, flags: [.shift])

        #expect(isFirst(ClipboardKeyboardRouter.RouterView.command(
            for: commandUp, isSearchFocused: false, editorHasFocus: false)))
        #expect(isLast(ClipboardKeyboardRouter.RouterView.command(
            for: commandDown, isSearchFocused: false, editorHasFocus: false)))
        #expect(isPaste(ClipboardKeyboardRouter.RouterView.command(
            for: enter, isSearchFocused: false, editorHasFocus: false), plainText: false))
        #expect(isPaste(ClipboardKeyboardRouter.RouterView.command(
            for: shiftedEnter, isSearchFocused: false, editorHasFocus: false), plainText: true))
        #expect(isOpen(ClipboardKeyboardRouter.RouterView.command(
            for: enter, isSearchFocused: true, editorHasFocus: true)))
    }

    @Test
    func keyboardMapperLeavesNativeEditorCopyAndArrowKeysAlone() throws {
        let commandC = try keyEvent(keyCode: 8, flags: [.command], characters: "c")
        let commandA = try keyEvent(keyCode: 0, flags: [.command], characters: "a")
        let leftArrow = try keyEvent(keyCode: 123)

        #expect(ClipboardKeyboardRouter.RouterView.command(
            for: commandC, isSearchFocused: true, editorHasFocus: true) == nil)
        #expect(ClipboardKeyboardRouter.RouterView.command(
            for: commandA, isSearchFocused: true, editorHasFocus: true) == nil)
        #expect(ClipboardKeyboardRouter.RouterView.command(
            for: leftArrow, isSearchFocused: true, editorHasFocus: true) == nil)
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenPaste-Tests-\(UUID().uuidString)"))
    }

    private func keyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [],
        characters: String? = nil
    ) throws -> NSEvent {
        let characterString = characters ?? (keyCode == 36 ? "\r" : "")
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characterString,
            charactersIgnoringModifiers: characters ?? characterString,
            isARepeat: false,
            keyCode: keyCode)
        guard let event else {
            throw InteractionTestError.couldNotCreateKeyEvent
        }
        return event
    }

    private func isFirst(_ command: ClipboardKeyboardCommand?) -> Bool {
        guard case .first? = command else { return false }
        return true
    }

    private func isLast(_ command: ClipboardKeyboardCommand?) -> Bool {
        guard case .last? = command else { return false }
        return true
    }

    private func isOpen(_ command: ClipboardKeyboardCommand?) -> Bool {
        guard case .open? = command else { return false }
        return true
    }

    private func isPaste(_ command: ClipboardKeyboardCommand?, plainText: Bool) -> Bool {
        guard case let .paste(actualPlainText)? = command else { return false }
        return actualPlainText == plainText
    }
}

private enum InteractionTestError: Error {
    case couldNotCreateKeyEvent
}
