import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey, which (unlike event taps)
/// needs no Accessibility permission.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    private static var nextID: UInt32 = 1

    init?(_ spec: String, action: @escaping () -> Void) {
        self.action = action
        id = Hotkey.nextID
        Hotkey.nextID += 1
        guard let (keyCode, modifiers) = Hotkey.parse(spec) else {
            warn("invalid hotkey '\(spec)' (example: \"alt+space\", \"cmd+shift+p\")")
            return nil
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Every handler sees every hotkey press, so each one checks the ID and passes on the rest.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData!).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotkey.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &eventType, selfPtr, &handler)

        let hotkeyID = EventHotKeyID(signature: OSType(0x6d6f6669) /* 'mofi' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            warn("could not register hotkey '\(spec)' (already in use?)")
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "super": modifiers |= UInt32(cmdKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "space": 0x31, "return": 0x24, "enter": 0x24, "tab": 0x30, "escape": 0x35, "esc": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
}
