import Foundation

struct WindowDimensions: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    static let `default`: WindowDimensions = .init(width: 920, height: 360)

    func clamped(to size: CGSize) -> WindowDimensions {
        let maxWidth = max(1, size.width)
        let maxHeight = max(1, size.height)
        let minWidth = min(640, maxWidth)
        let minHeight = min(180, maxHeight)
        return WindowDimensions(
            width: min(max(width, minWidth), maxWidth),
            height: min(max(height, minHeight), maxHeight))
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifierFlags: UInt32

    static let `default` = ShortcutBinding(keyCode: 9, modifierFlags: 0x0300)
}

enum CapturePauseState: Codable, Equatable, Sendable {
    case active
    case pausedUntil(Date)
    case pausedUntilResumed

    func isPaused(at date: Date = .now) -> Bool {
        switch self {
        case .active:
            false
        case let .pausedUntil(until):
            until > date
        case .pausedUntilResumed:
            true
        }
    }

    var expirationDate: Date? {
        guard case let .pausedUntil(date) = self else { return nil }
        return date
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var retentionPolicy: ClipboardRetentionPolicy
    var windowDimensions: WindowDimensions
    var activationShortcut: ShortcutBinding
    var capturePauseState: CapturePauseState

    static let `default` = AppPreferences(
        retentionPolicy: .oneMonth,
        windowDimensions: .default,
        activationShortcut: .default,
        capturePauseState: .active)
}
