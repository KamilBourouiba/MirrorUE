import AppKit
import Carbon
import Foundation

/// Mac glyph / key → HID chord for the **iPhone hardware-keyboard layout**.
///
/// USB HID usages are US key *positions*. iOS then remaps them through
/// Settings → General → Keyboard → Hardware Keyboard. Sending US logical
/// ``a`` (usage 0x04) to an AZERTY iPhone types ``q`` — that is ``kamil`` →
/// ``kq,il``.
///
/// Default ``MIRRORUE_KB_PHONE=auto`` picks the iPhone HID mapping from the
/// Mac preferred language first (``fr-US`` → French AZERTY), then the active
/// input source. That way an Italian-Pro layout on a French Mac still maps
/// correctly to a French iPhone hardware keyboard.
///
/// Overrides: ``us``, ``fr``, ``physical``.
public enum KeyboardTranslator {
    public struct Chord: Equatable {
        public let usage: UInt16
        public let token: String
        public let mods: UInt8
    }

    public enum PhoneLayout: String {
        case physical
        case us
        case fr
        case de

        static func fromEnv() -> PhoneLayout {
            // Prefer persisted Settings (and env) via MirrorUESettings.
            switch MirrorUESettings.keyboardMode {
            case .auto:
                return resolveAuto()
            case .physical:
                return .physical
            case .us:
                return .us
            case .fr:
                return .fr
            case .de:
                return .de
            }
        }

        /// Pick a phone HID strategy.
        ///
        /// Prefer the Mac **preferred language** (usually matches the iPhone
        /// hardware-keyboard language) over the active input source — a French
        /// user on an Italian-Pro layout still typically has a French iPhone.
        static func resolveAuto() -> PhoneLayout {
            let langs = Locale.preferredLanguages.map { $0.lowercased() }
            if let primary = langs.first {
                if primary.hasPrefix("fr") { return .fr }
                if primary.hasPrefix("de") { return .de }
                if primary.hasPrefix("en") { return .us }
                if primary.hasPrefix("it")
                    || primary.hasPrefix("es")
                    || primary.hasPrefix("pt") {
                    return .us // QWERTY letter positions
                }
                if primary.hasPrefix("sv") || primary.hasPrefix("fi") {
                    return .physical
                }
            }

            let id = currentInputSourceID().lowercased()
            if !id.isEmpty {
                if isAZERTY(id: id) { return .fr }
                if id.contains("german") || id.contains("austrian") || id.contains("swiss.german") {
                    return .de
                }
                if isQWERTYFamily(id: id) { return .us }
                return .physical
            }
            return .physical
        }

        private static func isAZERTY(id: String) -> Bool {
            ["french", "azerty", "belgium", "belgian", "canadianfrench", "canadian-french", "abc-azerty"]
                .contains { id.contains($0) }
        }

        /// Layouts whose letter keys match US HID positions (a→0x04, m→0x10, …).
        private static func isQWERTYFamily(id: String) -> Bool {
            if id.contains("azerty") { return false }
            return [
                "keylayout.us", "keylayout.abc", "keylayout.british",
                "australian", "irish", "usinternational", "usextended",
                "dvora", "colemak",
                "italian", "spanish", "portuguese",
                "keylayout.dutch", // NL QWERTY
            ].contains { id.contains($0) }
                || id.hasSuffix(".us")
                || id.hasSuffix(".abc")
        }

        static func currentInputSourceID() -> String {
            if let id = NSTextInputContext.current?.selectedKeyboardInputSource, !id.isEmpty {
                return id
            }
            guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
                return ""
            }
            return tisString(src, kTISPropertyInputSourceID) ?? ""
        }

        private static func tisString(_ src: TISInputSource, _ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
    }

    public static var phoneLayout: PhoneLayout {
        let layout = PhoneLayout.fromEnv()
        logAutoIfNeeded(layout)
        return layout
    }

    private static var didLogLayout = false
    private static func logAutoIfNeeded(_ layout: PhoneLayout) {
        guard !didLogLayout else { return }
        didLogLayout = true
        let id = PhoneLayout.currentInputSourceID()
        let lang = Locale.preferredLanguages.first ?? "?"
        let env = ProcessInfo.processInfo.environment["MIRRORUE_KB_PHONE"] ?? ""
        NSLog("MirrorUE keyboard: mode=%@ (MIRRORUE_KB_PHONE=%@, mac=%@, lang=%@)",
              layout.rawValue, env.isEmpty ? "auto" : env, id, lang)
    }

    /// When a glyph cannot map to HID, paste it via Cmd+V (clipboard).
    public static var pasteUnmapped: Bool {
        let raw = ProcessInfo.processInfo.environment["MIRRORUE_KB_PASTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == nil || raw!.isEmpty { return true }
        return !(raw == "0" || raw == "off" || raw == "false" || raw == "no")
    }

    /// Resolve a printable glyph for ``us`` / ``fr`` phone layouts.
    public static func resolve(_ glyph: String, hostMods: UInt8) -> Chord? {
        guard glyph.first != nil else { return nil }
        let folded = fold(glyph)
        guard let ascii = folded.first, ascii.isASCII else { return nil }
        let key = String(ascii)
        let table: [String: (UInt16, Bool)]
        switch phoneLayout {
        case .us: table = asciiToHID_US
        case .fr: table = asciiToHID_FR
        case .de: table = asciiToHID_DE
        case .physical: return nil
        }
        if phoneLayout == .fr, key == "@" {
            // French iOS hardware keyboard: @ is Option+0. Mapping it avoids
            // the paste fallback, which triggers iOS "Allow Paste" prompts.
            return Chord(usage: 0x27, token: key, mods: (hostMods & 0x0A) | 0x04)
        }
        guard let (usage, needsShift) = table[key]
            ?? table[key.lowercased()]
            ?? table[key.uppercased()]
        else { return nil }

        var mods = hostMods & 0x0A
        if needsShift || ascii.isUppercase { mods |= 0x01 }
        return Chord(usage: usage, token: key, mods: mods)
    }

    /// Closest ASCII the HID tables can type (NFKD + compat table).
    public static func fold(_ glyph: String) -> String {
        guard let ch = glyph.first else { return "" }
        let s = String(ch)
        if let mapped = compat[s] { return mapped }

        let stripped: String = {
            if let t = s.applyingTransform(.stripDiacritics, reverse: false) {
                let latin = t.applyingTransform(.toLatin, reverse: false) ?? t
                return latin
            }
            let m = NSMutableString(string: s)
            CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            return String(m)
        }()

        if let mapped = compat[stripped] { return mapped }
        if stripped.count == 1, let c = stripped.first, c.isASCII {
            return String(c)
        }
        let asciiOnly = stripped.filter(\.isASCII)
        if let c = asciiOnly.first { return String(c) }

        if let scalar = s.unicodeScalars.first {
            let name = scalar.properties.name ?? ""
            for marker in ["LETTER ", "DIGIT "] {
                if let r = name.range(of: marker) {
                    let rest = name[r.upperBound...]
                    if let letter = rest.split(separator: " ").first, letter.count == 1 {
                        let c = Character(String(letter))
                        if c.isASCII {
                            return name.contains("SMALL") ? String(c).lowercased() : String(c)
                        }
                    }
                }
            }
        }
        return ""
    }

    /// Put ``text`` on the pasteboard and emit Cmd+V as HID chords.
    public static func pasteChords(_ text: String) -> [Chord] {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return [
            Chord(usage: 0x19, token: "v", mods: 0x08),
        ]
    }

    // MARK: - US logical (iPhone Hardware Keyboard = U.S.)

    private static let asciiToHID_US: [String: (UInt16, Bool)] = [
        "a": (0x04, false), "b": (0x05, false), "c": (0x06, false), "d": (0x07, false),
        "e": (0x08, false), "f": (0x09, false), "g": (0x0A, false), "h": (0x0B, false),
        "i": (0x0C, false), "j": (0x0D, false), "k": (0x0E, false), "l": (0x0F, false),
        "m": (0x10, false), "n": (0x11, false), "o": (0x12, false), "p": (0x13, false),
        "q": (0x14, false), "r": (0x15, false), "s": (0x16, false), "t": (0x17, false),
        "u": (0x18, false), "v": (0x19, false), "w": (0x1A, false), "x": (0x1B, false),
        "y": (0x1C, false), "z": (0x1D, false),
        "A": (0x04, true), "B": (0x05, true), "C": (0x06, true), "D": (0x07, true),
        "E": (0x08, true), "F": (0x09, true), "G": (0x0A, true), "H": (0x0B, true),
        "I": (0x0C, true), "J": (0x0D, true), "K": (0x0E, true), "L": (0x0F, true),
        "M": (0x10, true), "N": (0x11, true), "O": (0x12, true), "P": (0x13, true),
        "Q": (0x14, true), "R": (0x15, true), "S": (0x16, true), "T": (0x17, true),
        "U": (0x18, true), "V": (0x19, true), "W": (0x1A, true), "X": (0x1B, true),
        "Y": (0x1C, true), "Z": (0x1D, true),
        "1": (0x1E, false), "2": (0x1F, false), "3": (0x20, false), "4": (0x21, false),
        "5": (0x22, false), "6": (0x23, false), "7": (0x24, false), "8": (0x25, false),
        "9": (0x26, false), "0": (0x27, false),
        "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true),
        "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
        "(": (0x26, true), ")": (0x27, true),
        " ": (0x2C, false), "\t": (0x2B, false), "\n": (0x28, false), "\r": (0x28, false),
        "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
        "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
        "\\": (0x31, false), "|": (0x31, true),
        ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true),
        "`": (0x35, false), "~": (0x35, true),
        ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
        "/": (0x38, false), "?": (0x38, true),
    ]

    // MARK: - French AZERTY positions (iPhone Hardware Keyboard = French)

    /// Glyph → HID usage for a French AZERTY hardware keyboard on iOS.
    /// Letters sit on US-position usages (A→Q=0x14, M→;=0x33, …).
    private static let asciiToHID_FR: [String: (UInt16, Bool)] = [
        "a": (0x14, false), "z": (0x1A, false), "e": (0x08, false), "r": (0x15, false),
        "t": (0x17, false), "y": (0x1C, false), "u": (0x18, false), "i": (0x0C, false),
        "o": (0x12, false), "p": (0x13, false),
        "q": (0x04, false), "s": (0x16, false), "d": (0x07, false), "f": (0x09, false),
        "g": (0x0A, false), "h": (0x0B, false), "j": (0x0D, false), "k": (0x0E, false),
        "l": (0x0F, false), "m": (0x33, false),
        "w": (0x1D, false), "x": (0x1B, false), "c": (0x06, false), "v": (0x19, false),
        "b": (0x05, false), "n": (0x11, false),
        "A": (0x14, true), "Z": (0x1A, true), "E": (0x08, true), "R": (0x15, true),
        "T": (0x17, true), "Y": (0x1C, true), "U": (0x18, true), "I": (0x0C, true),
        "O": (0x12, true), "P": (0x13, true),
        "Q": (0x04, true), "S": (0x16, true), "D": (0x07, true), "F": (0x09, true),
        "G": (0x0A, true), "H": (0x0B, true), "J": (0x0D, true), "K": (0x0E, true),
        "L": (0x0F, true), "M": (0x33, true),
        "W": (0x1D, true), "X": (0x1B, true), "C": (0x06, true), "V": (0x19, true),
        "B": (0x05, true), "N": (0x11, true),
        // Digits / many punctuation still differ on AZERTY; paste covers the rest.
        " ": (0x2C, false), "\t": (0x2B, false), "\n": (0x28, false), "\r": (0x28, false),
        ",": (0x10, false), "?": (0x10, true),
        ";": (0x36, false), ".": (0x36, true),
        ":": (0x37, false), "/": (0x37, true),
        "!": (0x1E, false), "1": (0x1E, true),
        "2": (0x1F, true), "3": (0x20, true), "4": (0x21, true), "5": (0x22, true),
        "6": (0x23, true), "7": (0x24, true), "8": (0x25, true), "9": (0x26, true),
        "0": (0x27, true),
    ]

    // MARK: - German QWERTZ (iPhone Hardware Keyboard = German)

    /// Glyph → HID for German QWERTZ (Y/Z swapped vs US).
    private static let asciiToHID_DE: [String: (UInt16, Bool)] = [
        "a": (0x04, false), "b": (0x05, false), "c": (0x06, false), "d": (0x07, false),
        "e": (0x08, false), "f": (0x09, false), "g": (0x0A, false), "h": (0x0B, false),
        "i": (0x0C, false), "j": (0x0D, false), "k": (0x0E, false), "l": (0x0F, false),
        "m": (0x10, false), "n": (0x11, false), "o": (0x12, false), "p": (0x13, false),
        "q": (0x14, false), "r": (0x15, false), "s": (0x16, false), "t": (0x17, false),
        "u": (0x18, false), "v": (0x19, false),
        "y": (0x1D, false), "z": (0x1C, false), "w": (0x1A, false), "x": (0x1B, false),
        "A": (0x04, true), "B": (0x05, true), "C": (0x06, true), "D": (0x07, true),
        "E": (0x08, true), "F": (0x09, true), "G": (0x0A, true), "H": (0x0B, true),
        "I": (0x0C, true), "J": (0x0D, true), "K": (0x0E, true), "L": (0x0F, true),
        "M": (0x10, true), "N": (0x11, true), "O": (0x12, true), "P": (0x13, true),
        "Q": (0x14, true), "R": (0x15, true), "S": (0x16, true), "T": (0x17, true),
        "U": (0x18, true), "V": (0x19, true),
        "Y": (0x1D, true), "Z": (0x1C, true), "W": (0x1A, true), "X": (0x1B, true),
        " ": (0x2C, false), "\t": (0x2B, false), "\n": (0x28, false), "\r": (0x28, false),
        "-": (0x2D, false), "_": (0x2D, true),
        ",": (0x36, false), ";": (0x36, true),
        ".": (0x37, false), ":": (0x37, true),
    ]

    private static let compat: [String: String] = [
        "ß": "s", "ẞ": "S", "ø": "o", "Ø": "O", "đ": "d", "Đ": "D",
        "ł": "l", "Ł": "L", "ı": "i", "İ": "I", "œ": "o", "Œ": "O",
        "æ": "a", "Æ": "A", "þ": "t", "Þ": "T", "ð": "d", "Ð": "D",
        "«": "\"", "»": "\"", "“": "\"", "”": "\"", "„": "\"",
        "‘": "'", "’": "'", "‚": "'",
        "–": "-", "—": "-", "−": "-", "…": ".", "·": ".",
        "¡": "!", "¿": "?",
        "\u{00A0}": " ", "\u{202F}": " ",
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "z", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "c", "ш": "s", "щ": "s", "ы": "y",
        "э": "e", "ю": "u", "я": "a",
        "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "E",
        "Ж": "Z", "З": "Z", "И": "I", "Й": "I", "К": "K", "Л": "L", "М": "M",
        "Н": "N", "О": "O", "П": "P", "Р": "R", "С": "S", "Т": "T", "У": "U",
        "Ф": "F", "Х": "H", "Ц": "C", "Ч": "C", "Ш": "S", "Щ": "S", "Ы": "Y",
        "Э": "E", "Ю": "U", "Я": "A",
        "α": "a", "β": "b", "γ": "g", "δ": "d", "ε": "e", "ζ": "z", "η": "i",
        "θ": "t", "ι": "i", "κ": "k", "λ": "l", "μ": "m", "ν": "n", "ξ": "x",
        "ο": "o", "π": "p", "ρ": "r", "σ": "s", "ς": "s", "τ": "t", "υ": "y",
        "φ": "f", "χ": "h", "ψ": "p", "ω": "o",
        "Α": "A", "Β": "B", "Γ": "G", "Δ": "D", "Ε": "E", "Ζ": "Z", "Η": "I",
        "Θ": "T", "Ι": "I", "Κ": "K", "Λ": "L", "Μ": "M", "Ν": "N", "Ξ": "X",
        "Ο": "O", "Π": "P", "Ρ": "R", "Σ": "S", "Τ": "T", "Υ": "Y", "Φ": "F",
        "Χ": "H", "Ψ": "P", "Ω": "O",
    ]
}
