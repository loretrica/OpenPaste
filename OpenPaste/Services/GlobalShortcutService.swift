import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalShortcutService {
    private(set) var registrationError: OSStatus?
    var onActivate: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register(_ binding: ShortcutBinding) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            openPasteGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        guard installStatus == noErr else {
            registrationError = installStatus
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x4F504E50, id: 1)
        let registerStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey)
        guard registerStatus == noErr else {
            registrationError = registerStatus
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            return
        }
        registrationError = nil
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        registrationError = nil
    }

    fileprivate func activateFromHotKey() {
        onActivate?()
    }
}

private func openPasteGlobalHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let pointerValue = UInt(bitPattern: userData)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: pointerValue) else { return }
        Unmanaged<GlobalShortcutService>
            .fromOpaque(pointer)
            .takeUnretainedValue()
            .activateFromHotKey()
    }
    return noErr
}
