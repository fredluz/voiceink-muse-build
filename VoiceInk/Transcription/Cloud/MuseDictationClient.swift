import Foundation

/// Errors raised by the Muse login-backed duplex transcription connection.
enum MuseDictationError: LocalizedError {
    case missingCredential
    case connectionFailed(String)
    case notConnected
    case timeout
    case serverError(String)
    case malformedResponse
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Muse login credential is missing. Sign in with muse login."
        case .connectionFailed(let message):
            return "Muse dictation connection failed: \(message)"
        case .notConnected:
            return "Muse dictation is not connected."
        case .timeout:
            return "Muse dictation timed out waiting for the server."
        case .serverError(let message):
            let lowercased = message.lowercased()
            if lowercased.contains("auth") || lowercased.contains("unauthor")
                || lowercased.contains("expired") || lowercased.contains("credential")
                || lowercased.contains("token") || lowercased.contains("login")
            {
                return "Muse login was rejected. Sign in again with muse login."
            }
            return "Muse dictation server error: \(message)"
        case .malformedResponse:
            return "Muse dictation returned a malformed response."
        case .noTranscript:
            return "Muse dictation returned no transcript."
        }
    }
}

/// Small transport seam used by the client and by focused protocol tests.
protocol MuseSocket: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

/// The installed Muse app's login-backed duplex ASR protocol.
actor MuseDictationClient {
    static let endpoint = URL(string: "wss://shortwave.facebook.com/voyager/v1/asr/duplex")!
    static let model = "prod_tbh"
    static let audioEncoding = "PCM_16KHZ"
    static let endStreamMessage = "{\"endStream\":{}}"

    private let credential: String
    private let onPartial: (@Sendable (String) -> Void)?
    private let socketFactory: @Sendable () throws -> any MuseSocket
    private let handshakeTimeoutNanoseconds: UInt64
    private let finishTimeoutNanoseconds: UInt64
    private let sendTimeoutNanoseconds: UInt64
    private var socket: (any MuseSocket)?
    private var receiveTask: Task<Void, Never>?
    private(set) var latestTranscript = ""
    private var terminalError: Error?
    private var receiveFailure: Error?
    private var receiveEnded = false
    private var didReceiveFinalTranscript = false
    private var finalSignal: AsyncStream<Void>.Continuation?
    private var didSendEndStream = false
    private var isConnected = false
    init(credential: String, onPartial: (@Sendable (String) -> Void)? = nil) {
        self.init(
            credential: credential,
            onPartial: onPartial,
            socketFactory: {
                let session = URLSession(configuration: .ephemeral)
                let task = session.webSocketTask(with: Self.endpoint)
                return URLSessionMuseSocket(session: session, task: task)
            },
            handshakeTimeoutNanoseconds: 15_000_000_000,
            finishTimeoutNanoseconds: 15_000_000_000,
            sendTimeoutNanoseconds: 10_000_000_000
        )
    }
    /// Internal initializer keeps protocol/lifecycle tests independent of a real WebSocket.
    init(
        credential: String,
        onPartial: (@Sendable (String) -> Void)? = nil,
        socketFactory: @escaping @Sendable () throws -> any MuseSocket,
        handshakeTimeoutNanoseconds: UInt64 = 15_000_000_000,
        finishTimeoutNanoseconds: UInt64 = 15_000_000_000,
        sendTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.credential = credential
        self.onPartial = onPartial
        self.socketFactory = socketFactory
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.finishTimeoutNanoseconds = finishTimeoutNanoseconds
        self.sendTimeoutNanoseconds = sendTimeoutNanoseconds
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel()
    }

    func connect() async throws {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseDictationError.missingCredential
        }
        guard !isConnected else { return }

        var newSocket: (any MuseSocket)?
        let timeoutState = MuseTimeoutState()
        do {
            let createdSocket = try socketFactory()
            newSocket = createdSocket
            try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.performHandshake(on: createdSocket)
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: self.handshakeTimeoutNanoseconds)
                        } catch {
                            throw CancellationError()
                        }
                        timeoutState.markTimedOut()
                        createdSocket.cancel()
                        throw MuseDictationError.timeout
                    }
                    defer { group.cancelAll() }
                    try await group.next()!
                }
            }, onCancel: {
                createdSocket.cancel()
            })
        } catch {
            newSocket?.cancel()
            if Task.isCancelled { throw CancellationError() }
            if timeoutState.didTimeOut { throw MuseDictationError.timeout }
            throw Self.connectionError(error)
        }
        if timeoutState.didTimeOut {
            newSocket?.cancel()
            throw MuseDictationError.timeout
        }
        guard let newSocket else {
            throw MuseDictationError.connectionFailed("The WebSocket could not be created.")
        }

        // Do not put cancellation in a defer: this socket is intentionally owned by the
        // receive loop after a successful handshake.
        socket = newSocket
        isConnected = true
        latestTranscript = ""
        terminalError = nil
        receiveFailure = nil
        receiveEnded = false
        didReceiveFinalTranscript = false
        didSendEndStream = false
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard isConnected, !didSendEndStream, let socket else {
            throw terminalError ?? (receiveEnded ? MuseDictationError.connectionFailed("The server closed the connection.") : MuseDictationError.notConnected)
        }
        guard terminalError == nil, !receiveEnded else {
            throw terminalError ?? MuseDictationError.connectionFailed("The server closed the connection.")
        }
        // Bounded wait: a silently dead socket must not suspend the paced sender forever.
        try await sendMessage(.data(data), on: socket, timeoutNanoseconds: sendTimeoutNanoseconds)
    }
    /// Sends the exact end marker and accepts either an explicit final transcript or Muse's
    /// latest transcript on a known clean EOF.
    func finish() async throws -> String {
        guard isConnected, let socket else {
            throw terminalError ?? MuseDictationError.notConnected
        }
        guard !didSendEndStream else {
            throw MuseDictationError.notConnected
        }
        if let terminalError {
            await cancel()
            throw terminalError
        }
        if receiveEnded {
            // A mid-stream server close still delivers the transcript it already sent;
            // only a close with no usable text is a connection failure.
            await cancel()
            guard !latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MuseDictationError.connectionFailed("The server closed before endStream.")
            }
            return latestTranscript
        }

        let timeoutState = MuseTimeoutState()
        do {
            try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.sendEndAndWait(on: socket)
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: self.finishTimeoutNanoseconds)
                        } catch {
                            throw CancellationError()
                        }
                        timeoutState.markTimedOut()
                        socket.cancel()
                        throw MuseDictationError.timeout
                    }
                    defer { group.cancelAll() }
                    try await group.next()!
                }
            }, onCancel: {
                socket.cancel()
            })
        } catch {
            await cancel()
            if Task.isCancelled { throw CancellationError() }
            if timeoutState.didTimeOut { throw MuseDictationError.timeout }
            throw Self.connectionError(error)
        }
        if timeoutState.didTimeOut {
            await cancel()
            throw MuseDictationError.timeout
        }

        if let terminalError {
            await cancel()
            throw terminalError
        }
        if let receiveFailure {
            await cancel()
            throw Self.connectionError(receiveFailure)
        }
        guard didReceiveFinalTranscript || receiveEnded else {
            await cancel()
            throw MuseDictationError.timeout
        }

        isConnected = false
        socket.cancel()
        self.socket = nil
        self.receiveTask = nil
        return try Self.requireTranscript(latestTranscript)
    }

    private func sendEndAndWait(on socket: any MuseSocket) async throws {
        try await socket.send(.string(Self.endStreamMessage))
        didSendEndStream = true
        guard let receiveTask else { return }

        let (finalStream, finalContinuation) = AsyncStream.makeStream(of: Void.self)
        finalSignal = finalContinuation
        if didReceiveFinalTranscript {
            finalContinuation.finish()
            finalSignal = nil
            return
        }

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in finalStream { return true }
                return false
            }
            group.addTask {
                await receiveTask.value
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
        finalContinuation.finish()
        finalSignal = nil
    }

    /// Sends one message with a bounded wait. The timeout cancels the socket so a
    /// suspended send unblocks instead of hanging on a dead connection.
    private func sendMessage(
        _ message: URLSessionWebSocketTask.Message,
        on socket: any MuseSocket,
        timeoutNanoseconds: UInt64
    ) async throws {
        let timeoutState = MuseTimeoutState()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await socket.send(message)
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        throw CancellationError()
                    }
                    timeoutState.markTimedOut()
                    socket.cancel()
                    throw MuseDictationError.connectionFailed("Send timed out.")
                }
                defer { group.cancelAll() }
                try await group.next()!
            }
        } catch {
            if timeoutState.didTimeOut {
                throw MuseDictationError.connectionFailed("Send timed out.")
            }
            throw Self.connectionError(error)
        }
    }

    func cancel() async {
        receiveTask?.cancel()
        receiveTask = nil
        finalSignal?.finish()
        finalSignal = nil
        socket?.cancel()
        socket = nil
        isConnected = false
        receiveEnded = true
    }

    private func performHandshake(on socket: any MuseSocket) async throws {
        try await socket.send(.string(Self.handshakeJSON(credential: credential)))
        let acknowledgement = try await receiveMessage(
            from: socket,
            timeoutNanoseconds: handshakeTimeoutNanoseconds
        )
        try Self.validateAcknowledgement(acknowledgement, credential: credential)
    }

    private static func validateAcknowledgement(
        _ message: URLSessionWebSocketTask.Message,
        credential: String
    ) throws {
        let object = try jsonObject(from: message)
        if let error = serverError(from: object) {
            throw MuseDictationError.serverError(redact(error, credential: credential))
        }
        guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else {
            throw MuseDictationError.malformedResponse
        }
    }

    static func handshakeJSON(credential: String) -> String {
        // JSONSerialization keeps escaping correct while preserving the protocol's exact fields.
        let object: [String: Any] = [
            "mode": "DEFAULT",
            "authorization": ["accessToken": credential],
            "audioEncoding": audioEncoding,
            "model": model,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonObject(from message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let value):
            guard let encoded = value.data(using: .utf8) else { throw MuseDictationError.malformedResponse }
            data = encoded
        case .data(let value):
            data = value
        @unknown default:
            throw MuseDictationError.malformedResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MuseDictationError.malformedResponse
        }
        return object
    }

    private static func serverError(from object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorType = (error["errorType"] as? String)?.lowercased() ?? ""
        let errorCode = (error["errorCode"] as? String)?.lowercased() ?? ""
        if errorType.contains("auth") || errorType.contains("unauthor")
            || errorCode == "401" || errorCode == "403"
        {
            return "Muse login was rejected. Sign in again with muse login."
        }
        return message.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Muse server error"
    }

    private static func redact(_ message: String, credential: String) -> String {
        guard !credential.isEmpty else { return String(message.prefix(512)) }
        return String(message.replacingOccurrences(of: credential, with: "[redacted]").prefix(512))
    }

    private static func requireTranscript(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MuseDictationError.noTranscript }
        return text
    }

    // MARK: - Receive lifecycle

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while true {
                let message = try await socket.receive()
                try handle(message)
            }
        } catch {
            receiveEnded = true
            finalSignal?.finish()
            // Muse commonly reports a normal close as POSIX 57, OSStatus -9805, or
            // networkConnectionLost. These are clean EOFs only after endStream; all other
            // transport failures remain terminal.
            if let museError = error as? MuseDictationError {
                switch museError {
                case .serverError, .malformedResponse:
                    terminalError = museError
                default:
                    break
                }
            } else if !Self.isExpectedEOF(error) {
                receiveFailure = error
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let object = try Self.jsonObject(from: message)
        if let error = Self.serverError(from: object) {
            throw MuseDictationError.serverError(Self.redact(error, credential: credential))
        }
        if let transcriptObject = object["transcript"] as? [String: Any] {
            guard let transcript = transcriptObject["transcript"] as? String,
                let isFinal = transcriptObject["final"] as? Bool
            else {
                throw MuseDictationError.malformedResponse
            }
            if transcript != latestTranscript {
                latestTranscript = transcript
                onPartial?(transcript)
            }
            didReceiveFinalTranscript = isFinal
            if isFinal {
                finalSignal?.yield()
            }
            return
        }
        // Progress is advisory and deliberately does not affect the transcript.
        if object["audioProgress"] is [String: Any] { return }
        throw MuseDictationError.malformedResponse
    }

    private func waitForReceiveLoop(_ task: Task<Void, Never>, socket: any MuseSocket) async throws {
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: self.finishTimeoutNanoseconds)
                } catch {
                    return false
                }
                socket.cancel()
                return true
            }
            let result = await group.next() ?? true
            group.cancelAll()
            return result
        }
        if timedOut { throw MuseDictationError.timeout }
    }

    private func receiveMessage(
        from socket: any MuseSocket,
        timeoutNanoseconds: UInt64
    ) async throws -> URLSessionWebSocketTask.Message {
        let timeoutState = MuseTimeoutState()
        do {
            return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await socket.receive()
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        throw CancellationError()
                    }
                    timeoutState.markTimedOut()
                    socket.cancel()
                    throw MuseDictationError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            if timeoutState.didTimeOut { throw MuseDictationError.timeout }
            throw Self.connectionError(error)
        }
    }


    private static func isExpectedEOF(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
            return true
        }
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == -9805 {
            return true
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.networkConnectionLost.rawValue {
            return true
        }
        return false
    }

    private static func connectionError(_ error: Error) -> Error {
        if error is MuseDictationError { return error }
        if error is CancellationError { return CancellationError() }
        return MuseDictationError.connectionFailed(error.localizedDescription)
    }
}
private final class MuseTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

private final class URLSessionMuseSocket: MuseSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
        task.resume()
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }
    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
