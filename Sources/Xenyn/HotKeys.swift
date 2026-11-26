import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon's RegisterEventHotKey.
/// These fire while another app (FaceTime) is in front and need no Accessibility permission.
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x5845_4E59   // 'XENY'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            hotKeys.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    deinit {
        refs.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// `keyCode` is a kVK_* constant; `modifiers` combines Carbon masks such as controlKey | optionKey.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs.append(ref)
    }
}
