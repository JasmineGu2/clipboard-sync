import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut through Carbon's `RegisterEventHotKey`. It's the long-standing way to get one
/// without any permission: macOS delivers only that exact key combination to the app, so unlike a global key
/// monitor (`NSEvent.addGlobalMonitorForEvents`) it needs no Accessibility or Input Monitoring grant, and it works
/// in the sandbox. Carbon calls the handler on the main thread.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌘V.
    static func controlCommandV(_ action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey), action: action)
    }

    /// nil when another app already holds the combination (or registration fails for another reason).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        // "CSyn": any four-character signature unique to this app.
        let id = EventHotKeyID(signature: 0x4353_796E, id: 1)
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    /// Carbon keeps an unretained pointer to this object, so unregister before it goes away.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
