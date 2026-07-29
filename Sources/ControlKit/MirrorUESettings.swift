import Foundation

/// User-facing preferences. Environment variables still win when set (dev/CI).
public enum MirrorUESettings {
    public enum Keys {
        public static let captureFPS = "mirrorue.captureFPS"
        public static let keyboard = "mirrorue.keyboardPhone"
        public static let landscape = "mirrorue.landscapeHome"
        public static let hidOrient = "mirrorue.hidOrient"
        public static let didShowHints = "mirrorue.didShowFirstHints"
        public static let setupSeen = "mirrorue.setupChecklistSeen"
        public static let permissionsGate = "mirrorue.permissionsGateCompleted"
        public static let showTouches = "mirrorue.showTouches"
    }

    public enum KeyboardMode: String, CaseIterable {
        case auto
        case fr
        case us
        case de
        case physical

        public var title: String {
            switch self {
            case .auto: return "Detect automatically"
            case .fr: return "French AZERTY"
            case .us: return "US / IT / ES QWERTY"
            case .de: return "German QWERTZ"
            case .physical: return "Match Mac keys"
            }
        }
    }

    public enum LandscapeHome: String, CaseIterable {
        case automatic = "right"
        case left
        case buffer

        public var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .left: return "Home on left"
            case .buffer: return "No remap (debug)"
            }
        }
    }

    public enum FrameRate: Int, CaseIterable {
        case automatic = 0
        case fps60 = 60
        case fps120 = 120

        public var title: String {
            switch self {
            case .automatic: return "Automatic (120)"
            case .fps60: return "60 fps"
            case .fps120: return "120 fps"
            }
        }

        public var resolvedFPS: Int {
            switch self {
            case .automatic, .fps120: return 120
            case .fps60: return 60
            }
        }
    }

    private static var defaults: UserDefaults { .standard }

    public static var frameRate: FrameRate {
        get {
            let raw = defaults.object(forKey: Keys.captureFPS) as? Int
            return FrameRate(rawValue: raw ?? 0) ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.captureFPS) }
    }

    public static var captureFPS: Int {
        if let env = ProcessInfo.processInfo.environment["MIRRORUE_CAPTURE_FPS"],
           let n = Int(env.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            return min(240, max(1, n))
        }
        return frameRate.resolvedFPS
    }

    public static var keyboardMode: KeyboardMode {
        get {
            if let env = ProcessInfo.processInfo.environment["MIRRORUE_KB_PHONE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !env.isEmpty {
                return KeyboardMode(rawValue: env) ?? (env == "en" || env == "english" ? .us : .auto)
            }
            let raw = defaults.string(forKey: Keys.keyboard) ?? KeyboardMode.auto.rawValue
            return KeyboardMode(rawValue: raw) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.keyboard) }
    }

    public static var landscapeHome: LandscapeHome {
        get {
            if let env = ProcessInfo.processInfo.environment["MIRRORUE_LANDSCAPE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !env.isEmpty {
                if env == "left" || env == "homeleft" { return .left }
                if env == "buffer" { return .buffer }
                return .automatic
            }
            if let orient = ProcessInfo.processInfo.environment["MIRRORUE_HID_ORIENT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               orient == "buffer" || orient == "off" || orient == "0" {
                return .buffer
            }
            let raw = defaults.string(forKey: Keys.landscape) ?? LandscapeHome.automatic.rawValue
            return LandscapeHome(rawValue: raw) ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.landscape) }
    }

    public static var didShowFirstHints: Bool {
        get { defaults.bool(forKey: Keys.didShowHints) }
        set { defaults.set(newValue, forKey: Keys.didShowHints) }
    }

    public static var setupChecklistSeen: Bool {
        get { defaults.bool(forKey: Keys.setupSeen) }
        set { defaults.set(newValue, forKey: Keys.setupSeen) }
    }

    public static var permissionsGateCompleted: Bool {
        get { defaults.bool(forKey: Keys.permissionsGate) }
        set { defaults.set(newValue, forKey: Keys.permissionsGate) }
    }

    public static var showTouches: Bool {
        get {
            if defaults.object(forKey: Keys.showTouches) == nil { return true }
            return defaults.bool(forKey: Keys.showTouches)
        }
        set { defaults.set(newValue, forKey: Keys.showTouches) }
    }

    /// Push current prefs into the process env so existing readers keep working.
    public static func applyToEnvironment() {
        setenv("MIRRORUE_CAPTURE_FPS", "\(captureFPS)", 1)
        setenv("MIRRORUE_KB_PHONE", keyboardMode.rawValue, 1)
        switch landscapeHome {
        case .automatic:
            setenv("MIRRORUE_LANDSCAPE", "right", 1)
            unsetenv("MIRRORUE_HID_ORIENT")
        case .left:
            setenv("MIRRORUE_LANDSCAPE", "left", 1)
            unsetenv("MIRRORUE_HID_ORIENT")
        case .buffer:
            setenv("MIRRORUE_HID_ORIENT", "buffer", 1)
        }
    }
}
