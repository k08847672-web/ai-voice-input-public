import Foundation

public enum InputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case faithful
    case smart
    case command

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .faithful: "忠实听写"
        case .smart: "智能整理"
        case .command: "指令"
        }
    }
}

public enum HotKeyActivationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pressAndHold
    case toggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pressAndHold: "按住说话"
        case .toggle: "按一下开始，再按一下结束"
        }
    }
}

public struct HotKeyDescriptor: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var activationMode: HotKeyActivationMode

    public init(
        keyCode: UInt16 = 49,
        modifiers: UInt64 = 786_432,
        activationMode: HotKeyActivationMode = .pressAndHold
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.activationMode = activationMode
    }

    public static let `default` = HotKeyDescriptor()

    public var isCommandModifierOnly: Bool {
        (keyCode == 54 || keyCode == 55) && modifiers == Self.commandMask
    }

    public var isValidGlobalShortcut: Bool {
        if keyCode == 54 || keyCode == 55 { return isCommandModifierOnly }
        let primaryModifierMask = Self.controlMask | Self.optionMask | Self.commandMask
        return modifiers & primaryModifierMask != 0 || Self.isFunctionKey(keyCode)
    }

    public var displayName: String {
        if isCommandModifierOnly { return Self.keyLabel(for: keyCode) }
        var result = ""
        if modifiers & Self.controlMask != 0 { result += "⌃" }
        if modifiers & Self.optionMask != 0 { result += "⌥" }
        if modifiers & Self.commandMask != 0 { result += "⌘" }
        if modifiers & Self.shiftMask != 0 { result += "⇧" }
        return result + Self.keyLabel(for: keyCode)
    }

    private static let shiftMask: UInt64 = 131_072
    private static let controlMask: UInt64 = 262_144
    private static let optionMask: UInt64 = 524_288
    private static let commandMask: UInt64 = 1_048_576

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 64, 79, 80, 90, 96 ... 101, 103, 105 ... 107, 109, 111, 113, 118, 120, 122:
            true
        default:
            false
        }
    }

    private static func keyLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case 53: "Esc"
        case 54: "右⌘"
        case 55: "左⌘"
        case 64: "F17"
        case 79: "F18"
        case 80: "F19"
        case 90: "F20"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 106: "F16"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 115: "Home"
        case 116: "Page Up"
        case 117: "Forward Delete"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "Page Down"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case activationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt64.self, forKey: .modifiers)
        activationMode = try container.decodeIfPresent(
            HotKeyActivationMode.self,
            forKey: .activationMode
        ) ?? .pressAndHold
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(activationMode, forKey: .activationMode)
    }
}

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var spoken: String
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var name: String
    public var mode: InputMode
    public var style: String

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        name: String,
        mode: InputMode,
        style: String = ""
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.mode = mode
        self.style = style
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var serverURL: String
    public var language: String
    public var defaultMode: InputMode
    public var hotKey: HotKeyDescriptor
    public var showOverlay: Bool
    public var playSounds: Bool
    public var launchAtLogin: Bool
    public var allowInsecureLocalhost: Bool
    public var hotwords: [String]
    public var dictionary: [DictionaryEntry]
    public var appProfiles: [AppProfile]

    public init(
        serverURL: String = "wss://asr.example.invalid/v1/asr/stream",
        language: String = "zh-CN",
        defaultMode: InputMode = .smart,
        hotKey: HotKeyDescriptor = .default,
        showOverlay: Bool = true,
        playSounds: Bool = true,
        launchAtLogin: Bool = false,
        allowInsecureLocalhost: Bool = false,
        hotwords: [String] = [],
        dictionary: [DictionaryEntry] = [],
        appProfiles: [AppProfile] = []
    ) {
        self.serverURL = serverURL
        self.language = language
        self.defaultMode = defaultMode
        self.hotKey = hotKey
        self.showOverlay = showOverlay
        self.playSounds = playSounds
        self.launchAtLogin = launchAtLogin
        self.allowInsecureLocalhost = allowInsecureLocalhost
        self.hotwords = hotwords
        self.dictionary = dictionary
        self.appProfiles = appProfiles
    }

    public func resolvedProfile(for bundleIdentifier: String?) -> (mode: InputMode, style: String) {
        guard let bundleIdentifier,
              let profile = appProfiles.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return (defaultMode, "")
        }
        return (profile.mode, profile.style)
    }

    public var allowInsecurePrivateNetwork: Bool {
        get { allowInsecureLocalhost }
        set { allowInsecureLocalhost = newValue }
    }
}
