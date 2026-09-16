import Foundation

/// Bridges the shared VoiceInk realtime lifecycle to the same Muse duplex client used for
/// saved recordings. Muse returns a cumulative transcript and closes after endStream.
final class MuseStreamingProvider: StreamingTranscriptionProvider {
    private var client: MuseDictationClient?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init() {
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

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
        continuation?.yield(.sessionStarted)
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let client else { throw StreamingTranscriptionError.notConnected }
        do {
            try await client.sendAudio(data)
        } catch {
            let mapped = Self.mapError(error)
            eventsContinuation?.yield(.error(mapped))
            throw mapped
        }
    }

    func commit() async throws {
        guard let client else { throw StreamingTranscriptionError.notConnected }
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
