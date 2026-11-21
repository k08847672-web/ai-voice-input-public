import Foundation
import VoiceInputCore

enum DictionarySyncError: LocalizedError {
    case invalidLocalEntries
    case invalidResponse
    case unauthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidLocalEntries: "词典有重复或超长的读音/写法，请先修正"
        case .invalidResponse: "词典同步服务返回了无效数据"
        case .unauthorized: "词典同步令牌无效，请检查识别服务设置"
        case .unavailable: "词典同步服务暂不可用，本地词典不受影响"
        }
    }
}

struct DictionarySyncHTTPClient {
    let url: URL
    let token: String

    func fetch() async throws -> DictionarySyncSnapshot {
        let (data, response) = try await request(method: "GET", body: nil, revision: nil)
        guard response.statusCode == 200 else { throw error(for: response.statusCode) }
        return try decode(data)
    }

    func replace(_ snapshot: DictionarySyncSnapshot) async throws -> DictionarySyncSnapshot? {
        let body = try JSONEncoder().encode(snapshot)
        let (data, response) = try await request(
            method: "PUT", body: body, revision: snapshot.revision
        )
        if response.statusCode == 409 { return nil }
        guard response.statusCode == 200 else { throw error(for: response.statusCode) }
        return try decode(data)
    }

    private func request(
        method: String,
        body: Data?,
        revision: Int?
    ) async throws -> (Data, HTTPURLResponse) {
        guard !token.isEmpty else { throw DictionarySyncError.unauthorized }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let revision { request.setValue(String(revision), forHTTPHeaderField: "If-Match") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DictionarySyncError.invalidResponse
        }
        return (data, response)
    }

    private func decode(_ data: Data) throws -> DictionarySyncSnapshot {
        guard data.count <= 1_200_000,
              let snapshot = try? JSONDecoder().decode(DictionarySyncSnapshot.self, from: data),
              snapshot.revision >= 0,
              snapshot.entries.count <= 1_000,
              snapshot.entries.allSatisfy({ spoken, written in
                  !spoken.isEmpty && spoken == spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                      && spoken.count <= 100 && !written.isEmpty && written.count <= 200
              })
        else { throw DictionarySyncError.invalidResponse }
        return snapshot
    }

    private func error(for status: Int) -> DictionarySyncError {
        status == 401 ? .unauthorized : .unavailable
    }
}
