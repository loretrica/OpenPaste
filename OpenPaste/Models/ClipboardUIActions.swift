import Foundation
import Observation

enum ClipboardKeyboardCommand {
    case previous, next, first, last
    case extendPrevious, extendNext
    case previousCollection, nextCollection
    case selectAll, copy, preview, open, rename, edit, newText, newCollection
    case paste(plainText: Bool)
    case quickPaste(index: Int, plainText: Bool)
    case search, tab, delete, dismiss
    case searchText(String)
}

/// The UI sends user intents; AppKit owns focus and the system pasteboard.
@MainActor
struct ClipboardUIActions {
    var paste: (ClipboardItem, Bool) -> Void = { _, _ in }
    var copy: (ClipboardItem) -> Void = { _ in }
    var preview: (ClipboardItem) -> Void = { _ in }
    var open: (ClipboardItem) -> Void = { _ in }
    var holdInteraction: (Bool) -> Void = { _ in }
    var pause: (CapturePauseDuration) -> Void = { _ in }
    var resume: () -> Void = {}
    var status: ClipboardActionStatus? = nil
}

@MainActor
@Observable
final class ClipboardActionStatus {
    var message: String?
    var isBusy = false
}
