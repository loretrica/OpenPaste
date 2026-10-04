import AppKit

@MainActor
enum PillWindowScreenLocator {
    static func activeScreen() -> NSScreen? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPID,
           let windowFrame = frontmostWindowFrame(processID: frontmostPID),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    private static func frontmostWindowFrame(processID: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        for windowInfo in windows {
            guard let owner = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  owner == processID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else {
                continue
            }
            return frame
        }
        return nil
    }
}
