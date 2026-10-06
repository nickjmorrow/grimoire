#if os(macOS)
import AppKit

/// Builds and delivers synthetic keyboard and mouse events straight to a window (no screen, no Accessibility permission).
/// Used by the headless end-to-end tests.
public enum EventInjector {
    static let keyCodes: [String: UInt16] = ["return": 36, "tab": 48, "delete": 51, "escape": 53, "up": 126, "down": 125, "left": 123, "right": 124,
                                             "space": 49, "forwarddelete": 117, "a": 0, "b": 11, "i": 34, "k": 40, "t": 17, "n": 45, "w": 13, "f": 3, "z": 6, "c": 8, "v": 9, "x": 7]
    static let specials: [String: String] = [
        "return": "\r", "tab": "\t", "delete": "\u{7f}", "escape": "\u{1b}", "space": " ",
        "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!),
        "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
        "forwarddelete": String(UnicodeScalar(NSDeleteFunctionKey)!)]

    public static func flags(_ mods: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in mods { switch m { case "cmd": f.insert(.command); case "shift": f.insert(.shift); case "opt": f.insert(.option); case "ctrl": f.insert(.control); default: break } }
        return f
    }

    /// A named key ("return", "tab", "up", "a"…) with modifiers, or a literal character via `chars`.
    public static func key(_ name: String, chars: String? = nil, mods: [String] = [], in window: NSWindow) {
        let c = chars ?? ((name.lowercased() == "tab" && mods.contains("shift")) ? "\u{19}" : (specials[name.lowercased()] ?? name))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags(mods), timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c.lowercased(),
                                        isARepeat: false, keyCode: keyCodes[name.lowercased()] ?? 0) { window.sendEvent(e) }
        }
    }

    public static func type(_ text: String, in window: NSWindow) {
        for ch in text { key(String(ch), chars: String(ch), in: window) }
    }

    /// A click at `point` (window coordinates, origin bottom-left).
    public static func click(at point: NSPoint, mods: [String] = [], count: Int = 1, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags(mods), timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) { window.sendEvent(e) }
        }
    }
}
#endif
