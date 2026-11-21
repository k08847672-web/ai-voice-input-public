import Foundation
import VoiceInputCore

actor WebSocketASRClient {
    private struct Connection {
        let id: UUID
        let codec: ASRWireCodec
        let socket: URLSessionWebSocketTask
        let session: URLSession
        let continuation: AsyncStream<ASREvent>.Continuation
        var receiveTask: Task<Void, Never>?
    }

    private var connection: Connection?

    func start(
        serverURL: String,
        token: String,
        allowInsecurePrivateNetwork: Bool,
        configuration: ASRStartConfiguration
    ) async throws -> AsyncStream<ASREvent> {
        cancelCurrentConnection()
        try configuration.validate()
        let url = try ASRURLValidator.validate(
            serverURL,
            allowInsecurePrivateNetwork: allowInsecurePrivateNetwork
        )
        let sessionID = UUID()
        let connectionID = UUID()
        let codec = ASRWireCodec(url: url, sessionID: sessionID)
        let (stream, streamContinuation) = AsyncStream<ASREvent>.makeStream()

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        sessionConfiguration.timeoutIntervalForResource = 3_600
        sessionConfiguration.waitsForConnectivity = true
        let urlSession = URLSession(configuration: sessionConfiguration)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceInput/1.0", forHTTPHeaderField: "X-VoiceInput-Client")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let webSocket = urlSession.webSocketTask(with: request)
        connection = Connection(
            id: connectionID,
            codec: codec,
            socket: webSocket,
            session: urlSession,
            continuation: streamContinuation
        )
        webSocket.resume()

        do {
            try await webSocket.send(.string(try codec.startMessage(configuration: configuration)))
        } catch {
            cancelConnection(connectionID)
            throw error
        }
        guard connection?.id == connectionID else { throw CancellationError() }
        let receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(
                connectionID: connectionID,
                codec: codec,
                socket: webSocket,
                continuation: streamContinuation
            )
        }
        connection?.receiveTask = receiveTask
        return stream
    }

    func sendAudio(_ data: Data) async throws {
        guard let connection else { throw ASRProtocolError.connectionClosed }
        try await connection.socket.send(.data(data))
    }

    func finish() async throws {
        guard let connection else { throw ASRProtocolError.connectionClosed }
        try await connection.socket.send(.string(try connection.codec.stopMessage()))
    }

    func cancel() {
        cancelCurrentConnection()
    }

    private func receiveLoop(
        connectionID: UUID,
        codec: ASRWireCodec,
        socket: URLSessionWebSocketTask,
        continuation: AsyncStream<ASREvent>.Continuation
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: continue
                }
                let event = try codec.event(from: data)
                continuation.yield(event)
                if case .final = event { break }
                if case .error = event { break }
            }
        } catch is CancellationError {
            // A user-initiated cancellation is not surfaced as a recognition error.
        } catch {
            continuation.yield(.error(code: "transport_error", message: error.localizedDescription))
        }
        continuation.finish()
        completeConnection(connectionID)
    }

    private func cancelCurrentConnection() {
        guard let connection else { return }
        cancelConnection(connection.id)
    }

    private func cancelConnection(_ id: UUID) {
        guard let current = connection, current.id == id else { return }
        connection = nil
        current.receiveTask?.cancel()
        current.socket.cancel(with: .goingAway, reason: nil)
        current.session.invalidateAndCancel()
        current.continuation.finish()
    }

    private func completeConnection(_ id: UUID) {
        guard let current = connection, current.id == id else { return }
        connection = nil
        current.socket.cancel(with: .normalClosure, reason: nil)
        current.session.finishTasksAndInvalidate()
        current.continuation.finish()
    }
}
