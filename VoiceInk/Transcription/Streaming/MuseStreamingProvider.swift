import Foundation

/// Bridges the shared VoiceInk realtime lifecycle to the same Muse duplex client used for
/// saved recordings. Muse returns a cumulative transcript and closes after endStream.
final class MuseStreamingProvider: StreamingTranscriptionProvider {
    /// Muse's wire cadence: 1280-byte PCM frames (80 ms @ 16 kHz mono s16le), matching
    /// MuseProvider's batch sender. The recorder emits ~10 ms callbacks; sending each as
    /// its own WebSocket message floods the server ("Audio processing backlog too large").
    private static let frameSize = 16_000 * 2 * 80 / 1_000
    private static let frameIntervalNanoseconds: UInt64 = 80_000_000

    private var client: MuseDictationClient?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    /// Accumulates raw PCM until a full frame is available, then sends paced frames.
    private var frameBuffer: MuseFrameBuffer?
    private var sendTask: Task<Void, Never>?

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model _: any TranscriptionModel, language _: String?) async throws {
        guard client == nil else { return }

        let credential = try MuseLoginCredentials.load()

        let continuation = eventsContinuation
        let newClient = MuseDictationClient(credential: credential) { text in
            continuation?.yield(.partial(text: text))
        }
        do {
            try await newClient.connect()
        } catch {
            throw Self.mapError(error)
        }
        client = newClient
        startPacedSender(for: newClient)
        continuation?.yield(.sessionStarted)
    }

    private func startPacedSender(for client: MuseDictationClient) {
        let buffer = MuseFrameBuffer(frameSize: Self.frameSize)
        frameBuffer = buffer
        sendTask = Task {
            while let frame = await buffer.nextFrame() {
                do {
                    try await client.sendAudio(frame)
                } catch {
                    await buffer.fail(error)
                    return
                }
                // Pace to the wire cadence; a burst of small frames is what trips
                // the server's "Audio processing backlog too large".
                do {
                    try await Task.sleep(nanoseconds: Self.frameIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard client != nil, let frameBuffer else {
            throw StreamingTranscriptionError.notConnected
        }
        do {
            try await frameBuffer.push(data)
        } catch {
            let mapped = Self.mapError(error)
            eventsContinuation?.yield(.error(mapped))
            throw mapped
        }
    }

    func commit() async throws {
        guard let client else { throw StreamingTranscriptionError.notConnected }

        // Flush remaining partial frame, wait for the paced sender to drain, then
        // surface any send failure before asking the client for the transcript.
        if let frameBuffer {
            await frameBuffer.finish()
            await sendTask?.value
            if let sendError = await frameBuffer.failure {
                let mapped = Self.mapError(sendError)
                eventsContinuation?.yield(.error(mapped))
                throw mapped
            }
        }

        do {
            let text = try await client.finish()
            eventsContinuation?.yield(.committed(text: text))
        } catch {
            let mapped = Self.mapError(error)
            // The shared service observes error events for logging; throwing here also makes
            // stopAndFinalize fail instead of treating a partial transcript as success.
            eventsContinuation?.yield(.error(mapped))
            throw mapped
        }
    }

    func disconnect() async {
        sendTask?.cancel()
        sendTask = nil
        frameBuffer = nil
        if let client {
            await client.cancel()
        }
        client = nil
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    private static func mapError(_ error: Error) -> Error {
        guard let museError = error as? MuseDictationError else { return error }
        switch museError {
        case .missingCredential:
            return museError
        case .serverError(let message):
            let lowercased = message.lowercased()
            if lowercased.contains("auth") || lowercased.contains("unauthor")
                || lowercased.contains("expired") || lowercased.contains("credential")
                || lowercased.contains("token") || lowercased.contains("login")
            {
                return StreamingTranscriptionError.serverError(
                    "Muse login was rejected. Sign in again with muse login.")
            }
            return StreamingTranscriptionError.serverError(message)
        case .timeout:
            return StreamingTranscriptionError.timeout
        case .notConnected:
            return StreamingTranscriptionError.notConnected
        case .connectionFailed(let message):
            return StreamingTranscriptionError.connectionFailed(message)
        case .malformedResponse, .noTranscript:
            return StreamingTranscriptionError.serverError(museError.localizedDescription)
        }
    }
}

/// Buffers raw PCM into fixed-size frames for the paced sender. Suspends the consumer
/// until a full frame is ready; on finish() a trailing partial frame is delivered once.
private actor MuseFrameBuffer {
    private let frameSize: Int
    private var pending = Data()
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var failure: Error?

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func push(_ data: Data) throws {
        if let failure { throw failure }
        guard !isFinished else { throw MuseDictationError.notConnected }
        pending.append(data)
        if pending.count >= frameSize {
            wakeWaiters()
        }
    }

    func finish() {
        isFinished = true
        wakeWaiters()
    }

    func fail(_ error: Error) {
        failure = error
        isFinished = true
        wakeWaiters()
    }

    /// Returns the next frame to send, or nil once finished and drained.
    /// A trailing partial frame is emitted once when the stream finishes.
    func nextFrame() async -> Data? {
        while true {
            if failure != nil { return nil }

            if pending.count >= frameSize {
                return takeFrame()
            }

            if isFinished {
                guard !pending.isEmpty else { return nil }
                let tail = pending
                pending.removeAll()
                return tail
            }

            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func takeFrame() -> Data {
        let frame = pending.prefix(frameSize)
        pending.removeFirst(frameSize)
        return Data(frame)
    }

    private func wakeWaiters() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.resume()
        }
    }
}
