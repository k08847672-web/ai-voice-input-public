import Foundation

public struct DictionarySyncSnapshot: Codable, Equatable, Sendable {
    public let revision: Int
    public let entries: [String: String]

    public init(revision: Int, entries: [String: String]) {
        self.revision = revision
        self.entries = entries
    }
}

public struct DictionaryMergeResult: Equatable, Sendable {
    public let entries: [String: String]
    public let conflicts: [String]
}

public enum DictionarySyncMerge {
    public static func merge(
        baseline: [String: String],
        local: [String: String],
        remote: [String: String]
    ) -> DictionaryMergeResult {
        var merged: [String: String] = [:]
        var conflicts: [String] = []
        for spoken in Set(baseline.keys).union(local.keys).union(remote.keys).sorted() {
            let original = baseline[spoken]
            let onDevice = local[spoken]
            let onServer = remote[spoken]
            let value: String?
            if onDevice == original {
                value = onServer
            } else if onServer == original || onDevice == onServer {
                value = onDevice
            } else {
                value = onDevice
                conflicts.append(spoken)
            }
            if let value { merged[spoken] = value }
        }
        return DictionaryMergeResult(entries: merged, conflicts: conflicts)
    }
}

public enum DictionarySyncURL {
    public static func fromASR(
        _ serverURL: String,
        allowInsecurePrivateNetwork: Bool
    ) throws -> URL {
        let asrURL = try ASRURLValidator.validate(
            serverURL,
            allowInsecurePrivateNetwork: allowInsecurePrivateNetwork
        )
        guard asrURL.path == "/v1/asr/stream",
              var components = URLComponents(url: asrURL, resolvingAgainstBaseURL: false)
        else { throw ASRProtocolError.invalidServerURL }
        components.scheme = asrURL.scheme?.lowercased() == "wss" ? "https" : "http"
        components.path = "/v1/dictionary"
        guard let url = components.url else { throw ASRProtocolError.invalidServerURL }
        return url
    }
}
