import Foundation

public enum AudioEncoding: String, Codable, Sendable {
    case pcmS16LE = "pcm_s16le"
}

public struct ASRStartConfiguration: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let encoding: AudioEncoding
    public let language: String
    public let mode: InputMode
    public let hotwords: [String]
    public let dictionary: [String: String]
    public let style: String
    public let sourceApplication: String?

    public init(
        sampleRate: Int = 16_000,
        channels: Int = 1,
        encoding: AudioEncoding = .pcmS16LE,
        language: String,
        mode: InputMode,
        hotwords: [String],
        dictionary: [String: String],
        style: String,
        sourceApplication: String?
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
        self.language = language
        self.mode = mode
        self.hotwords = hotwords
        self.dictionary = dictionary
        self.style = style
        self.sourceApplication = sourceApplication
    }

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case encoding
        case language
        case mode
        case hotwords
        case dictionary
        case style
        case sourceApplication = "source_application"
    }

    public func validate() throws {
        guard sampleRate == 16_000, channels == 1, encoding == .pcmS16LE else {
            throw ASRConfigurationError.unsupportedAudio
        }
        guard (2 ... 32).contains(language.unicodeScalars.count) else {
            throw ASRConfigurationError.invalidLanguage
        }
        guard hotwords.count <= 500,
              hotwords.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.unicodeScalars.count <= 100
              })
        else {
            throw ASRConfigurationError.invalidHotwords
        }
        guard dictionary.count <= 1_000,
              dictionary.allSatisfy({ key, replacement in
                  !key.isEmpty
                      && key.unicodeScalars.count <= 100
                      && replacement.unicodeScalars.count <= 200
              })
        else {
            throw ASRConfigurationError.invalidDictionary
        }
        guard style.unicodeScalars.count <= 2_000 else {
            throw ASRConfigurationError.invalidStyle
        }
        guard sourceApplication?.unicodeScalars.count ?? 0 <= 255 else {
            throw ASRConfigurationError.invalidSourceApplication
        }
    }
}

public enum ASRConfigurationError: LocalizedError, Equatable {
    case unsupportedAudio
    case invalidLanguage
    case invalidHotwords
    case invalidDictionary
    case invalidStyle
    case invalidSourceApplication

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudio: "ASR v1 只支持 16 kHz 单声道 PCM16 音频"
        case .invalidLanguage: "识别语言代码长度必须为 2–32 个字符"
        case .invalidHotwords: "热词最多 500 个，每个热词需为 1–100 个字符"
        case .invalidDictionary: "个人词典最多 1000 条，词条或替换文字过长"
        case .invalidStyle: "应用表达风格不能超过 2000 个字符"
        case .invalidSourceApplication: "来源应用标识不能超过 255 个字符"
        }
    }
}

public struct ASRClientEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let sessionID: UUID
    public let protocolVersion: Int?
    public let configuration: ASRStartConfiguration?

    public static func start(sessionID: UUID, configuration: ASRStartConfiguration) -> Self {
        Self(
            type: "start",
            sessionID: sessionID,
            protocolVersion: 1,
            configuration: configuration
        )
    }

    public static func stop(sessionID: UUID) -> Self {
        Self(type: "stop", sessionID: sessionID, protocolVersion: nil, configuration: nil)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case protocolVersion = "protocol_version"
        case configuration = "config"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
        try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(configuration, forKey: .configuration)
    }
}

public struct ASRServerEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let sessionID: UUID?
    public let text: String?
    public let code: String?
    public let message: String?

    public init(type: String, sessionID: UUID?, text: String?, code: String?, message: String?) {
        self.type = type
        self.sessionID = sessionID
        self.text = text
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case text
        case code
        case message
    }
}

public enum ASREvent: Equatable, Sendable {
    case ready
    case partial(String)
    case final(String)
    case error(code: String, message: String)

    public init(envelope: ASRServerEnvelope) throws {
        switch envelope.type {
        case "ready":
            guard envelope.sessionID != nil else {
                throw ASRProtocolError.invalidEvent("ready 缺少 session_id")
            }
            self = .ready
        case "partial":
            guard envelope.sessionID != nil, let text = envelope.text else {
                throw ASRProtocolError.invalidEvent("partial 缺少 session_id 或 text")
            }
            guard text.unicodeScalars.count <= 100_000 else {
                throw ASRProtocolError.invalidEvent("partial text 过长")
            }
            self = .partial(text)
        case "final":
            guard envelope.sessionID != nil, let text = envelope.text else {
                throw ASRProtocolError.invalidEvent("final 缺少 session_id 或 text")
            }
            guard text.unicodeScalars.count <= 100_000 else {
                throw ASRProtocolError.invalidEvent("final text 过长")
            }
            self = .final(text)
        case "error":
            guard envelope.code != nil,
                  let message = envelope.message,
                  !message.isEmpty,
                  message.unicodeScalars.count <= 1_000
            else {
                throw ASRProtocolError.invalidEvent("error 缺少 code 或 message")
            }
            self = .error(
                code: Self.safeErrorCode(envelope.code),
                message: message
            )
        default:
            let safeType = envelope.type.unicodeScalars.count <= 64 ? envelope.type : "unknown"
            throw ASRProtocolError.unknownEvent(safeType)
        }
    }

    private static func safeErrorCode(_ value: String?) -> String {
        guard let value,
              value.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil
        else {
            return "server_error"
        }
        return value
    }
}

public enum ASRProtocolError: LocalizedError, Equatable {
    case invalidServerURL
    case placeholderServerURL
    case insecureServerURL
    case unknownEvent(String)
    case invalidEvent(String)
    case sessionMismatch
    case connectionClosed
    case finalTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "ASR 服务地址无效"
        case .placeholderServerURL: "请先在设置中填写有效的 ASR 服务地址"
        case .insecureServerURL: "生产连接必须使用 wss://；仅可显式允许本机或 Tailscale 私网 ws://"
        case let .unknownEvent(type): "ASR 返回了不支持的事件：\(type)"
        case let .invalidEvent(reason): "ASR 返回了无效事件：\(reason)"
        case .sessionMismatch: "ASR 返回了错误的会话标识"
        case .connectionClosed: "ASR 连接已断开"
        case .finalTimedOut: "等待最终识别结果超时"
        }
    }
}

public enum ASRURLValidator {
    public static func validate(_ value: String, allowInsecurePrivateNetwork: Bool) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            throw ASRProtocolError.invalidServerURL
        }
        let normalizedHost = host.lowercased()
        if normalizedHost.hasSuffix(".invalid") {
            throw ASRProtocolError.placeholderServerURL
        }
        if scheme == "wss" { return url }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        if scheme == "ws",
           allowInsecurePrivateNetwork,
           localHosts.contains(normalizedHost) || isTailscaleIPv4(normalizedHost)
        {
            return url
        }
        throw ASRProtocolError.insecureServerURL
    }

    private static func isTailscaleIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { UInt8($0) }
        guard octets.count == components.count else { return false }
        return octets[0] == 100 && (64 ... 127).contains(octets[1])
    }
}
