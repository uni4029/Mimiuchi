import AppKit
import Carbon.HIToolbox

/// A "press twice" keyboard shortcut (DeepL style: modifier + key, pressed twice).
public struct DoublePressShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    /// Raw value of the device-independent `NSEvent.ModifierFlags` (⌘ ⌥ ⌃ ⇧ only).
    public var modifiers: UInt
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// DeepL's default: hold ⌘ and press C twice.
    public static let commandC = DoublePressShortcut(
        keyCode: UInt16(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "C")

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    public var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    public var modifierSymbols: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s
    }

    /// e.g. "⌘ + C + C"
    public var displayString: String {
        let mods = modifierSymbols.map(String.init).joined(separator: " + ")
        return mods.isEmpty ? "\(keyLabel) + \(keyLabel)" : "\(mods) + \(keyLabel) + \(keyLabel)"
    }

    /// The system copy shortcut: the frontmost app copies the selection by itself.
    public var isCopyShortcut: Bool { self == .commandC }
}

/// Pure state machine that recognizes "modifier + key pressed twice" (DeepL's ⌘+C+C).
///
/// - Both presses must use exactly the shortcut's modifiers (⌘ ⌥ ⌃ ⇧; Caps Lock / Fn ignored).
/// - Auto-repeat events (holding the key) are ignored.
/// - Any other key press in between cancels the sequence.
/// - A third quick press starts a new sequence instead of triggering again.
public struct DoublePressDetector: Sendable {
    public var shortcut: DoublePressShortcut
    public var interval: TimeInterval
    public private(set) var firstPressTime: TimeInterval?

    public init(shortcut: DoublePressShortcut, interval: TimeInterval) {
        self.shortcut = shortcut
        self.interval = interval
    }

    /// Returns `true` when the event completes a double press.
    public mutating func handleKeyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, timestamp: TimeInterval
    ) -> Bool {
        if isRepeat { return false }
        let relevant = modifiers.intersection(DoublePressShortcut.relevantModifiers)
        guard keyCode == shortcut.keyCode, relevant == shortcut.modifierFlags else {
            firstPressTime = nil
            return false
        }
        if let first = firstPressTime, timestamp >= first, timestamp - first <= interval {
            firstPressTime = nil
            return true
        }
        firstPressTime = timestamp
        return false
    }

    public mutating func reset() { firstPressTime = nil }
}

/// DeepL-like automatic target selection.
public enum LanguageRouting {
    /// If the source is already in the primary language, translate into the secondary one.
    public static func preferredTarget(detected: String?, primary: String, secondary: String) -> String {
        if let detected, detected == primary || (primary == "ja-easy" && detected == "ja") {
            return secondary
        }
        return primary
    }
}
