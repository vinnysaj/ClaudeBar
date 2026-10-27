import Foundation

/// A global hotkey, stored in Carbon's units because `RegisterEventHotKey` takes
/// them directly; `ShortcutRecorder` converts from `NSEvent` at the boundary.
struct KeyCombo: Sendable, Codable, Equatable {
    /// Carbon modifier bits, spelled out so this file stays Foundation-only.
    /// These match HIToolbox's `cmdKey`/`shiftKey`/`optionKey`/`controlKey`.
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    let keyCode: UInt32
    let modifiers: UInt32

    /// A bare key would swallow that keystroke system-wide, which is never what
    /// someone means to configure. Whether the *specific* modifiers are acceptable
    /// is left to the OS: Sequoia rejects shift/option-only combos with -9868, but
    /// 15.2 relaxed that again, so hardcoding the rule here would be wrong on one
    /// version or the other.
    var hasModifier: Bool { self.modifiers != 0 }
}
