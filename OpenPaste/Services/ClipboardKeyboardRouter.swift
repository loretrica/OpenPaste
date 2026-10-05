import AppKit
import SwiftUI

struct ClipboardKeyboardRouter: NSViewRepresentable {
    let isSearchFocused: Bool
    let onCommand: @MainActor (ClipboardKeyboardCommand) -> Void

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        view.isSearchFocused = isSearchFocused
        view.onCommand = onCommand
        return view
    }

    func updateNSView(_ view: RouterView, context: Context) {
        view.isSearchFocused = isSearchFocused
        view.onCommand = onCommand
    }

    @MainActor
    final class RouterView: NSView {
        var isSearchFocused = false
        var onCommand: (@MainActor (ClipboardKeyboardCommand) -> Void)?
        private var keyDownMonitor: Any?

        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installKeyDownMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeKeyDownMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func installKeyDownMonitor() {
            guard keyDownMonitor == nil else { return }
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let panel = self.window,
                      panel.isKeyWindow,
                      panel.attachedSheet == nil,
                      event.window === panel else {
                    return event
                }

                let editorHasFocus = self.isTextEditor(panel.firstResponder)
                guard let command = Self.command(
                    for: event,
                    isSearchFocused: self.isSearchFocused,
                    editorHasFocus: editorHasFocus)
                else { return event }

                self.onCommand?(command)
                return nil
            }
        }

        private func removeKeyDownMonitor() {
            guard let keyDownMonitor else { return }
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }

        private func isTextEditor(_ responder: NSResponder?) -> Bool {
            responder is NSTextView || responder is NSTextField
        }

        /// Pure key mapping, separated from event monitoring so the command contract is testable.
        static func command(
            for event: NSEvent,
            isSearchFocused: Bool,
            editorHasFocus: Bool
        ) -> ClipboardKeyboardCommand? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommand = flags.contains(.command)
            let isShift = flags.contains(.shift)
            let isOption = flags.contains(.option)

            switch event.keyCode {
            case 53: // Escape; UI applies layered dismissal.
                return .dismiss
            case 48: // Tab is routed when navigation is active, otherwise the editor owns it.
                return editorHasFocus && !isSearchFocused ? nil : .tab
            case 36, 76: // Return submits search, or pastes the active card.
                return isSearchFocused ? .open : .paste(plainText: isShift)
            case 123: // Left
                guard !editorHasFocus else { return nil }
                if isCommand && isOption { return .previousCollection }
                if isCommand { return .first }
                if isShift { return .extendPrevious }
                return .previous
            case 124: // Right
                guard !editorHasFocus else { return nil }
                if isCommand && isOption { return .nextCollection }
                if isCommand { return .last }
                if isShift { return .extendNext }
                return .next
            case 126: // Up
                guard !editorHasFocus else { return nil }
                if isCommand { return .first }
                if isShift { return .extendPrevious }
                return .previous
            case 125: // Down
                guard !editorHasFocus else { return nil }
                if isCommand { return .last }
                if isShift { return .extendNext }
                return .next
            case 115, 116: // Home / Page Up
                guard !editorHasFocus else { return nil }
                return .first
            case 119, 121: // End / Page Down
                guard !editorHasFocus else { return nil }
                return .last
            case 51, 117: // Delete / forward delete
                guard !editorHasFocus else { return nil }
                return .delete
            case 49: // Space
                guard !editorHasFocus else { return nil }
                return .preview
            default:
                if isCommand {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "f": return .search
                    case "a" where !editorHasFocus: return .selectAll
                    case "c" where !editorHasFocus: return .copy
                    case "v" where !editorHasFocus: return .paste(plainText: isShift)
                    case "r" where !editorHasFocus: return .rename
                    case "e" where !editorHasFocus: return .edit
                    case "n" where !editorHasFocus:
                        return isShift ? .newCollection : .newText
                    case let digit? where !editorHasFocus && ("1"..."9").contains(digit):
                        guard let index = Int(digit) else { return nil }
                        return .quickPaste(index: index, plainText: isShift)
                    default:
                        return nil
                    }
                }

                guard !editorHasFocus,
                      !isSearchFocused,
                      !flags.contains(.control),
                      !flags.contains(.option),
                      !flags.contains(.command),
                      let text = event.characters,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
                else { return nil }
                return .searchText(text)
            }
        }
    }
}
