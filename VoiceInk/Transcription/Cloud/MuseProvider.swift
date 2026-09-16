import Foundation
import SwiftData

struct MuseProvider: CloudProvider {
    let modelProvider: ModelProvider = .muse
    let providerKey: String = "Muse"
    // No stable public language catalog is part of this login-backed wire contract.
    // Keep auto detection available without advertising unverified language support.
    let languageCodes: [String]? = []
    let includesAutoDetect: Bool = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: "prod_tbh",
                displayName: "Muse Dictation",
                description: "Muse login-backed dictation for live and saved recordings.",
                provider: .muse,
                speed: 0,
                accuracy: 0,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forCodes([], includesAutoDetect: true)
            )
        ]
    }

    func transcribe(
        audioData: Data, fileName _: String, apiKey: String, model _: String, language _: String?, customVocabulary _: [String]
    ) async throws -> String {
        let pcmData: Data
        do {
            pcmData = try MuseWAVDecoder.pcm16Mono16kHz(from: audioData)
        } catch {
            throw CloudTranscriptionError.dataEncodingError
        }

        let client = MuseDictationClient(credential: apiKey)
        do {
            try await client.connect()
            let frameSize = 16_000 * 2 * 80 / 1_000
            var offset = 0
            while offset < pcmData.count {
                let end = min(offset + frameSize, pcmData.count)
                try await client.sendAudio(Data(pcmData[offset..<end]))
                offset = end
                if offset < pcmData.count {
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
            }
            let transcript = try await client.finish()
            await client.cancel()
            return transcript
        } catch let error as MuseDictationError {
            await client.cancel()
            if case .missingCredential = error {
                throw error
            }
            throw Self.mapMuseError(error)
        } catch let error as CloudTranscriptionError {
            await client.cancel()
            throw error
        } catch {
            await client.cancel()
            throw CloudTranscriptionError.networkError(error)
        }
    }

    func makeStreamingProvider(modelContext _: ModelContext) -> (any StreamingTranscriptionProvider)? {
        MuseStreamingProvider()
    }

    /// The protocol hook is retained for generic provider plumbing, but Muse does not accept
    /// manually entered developer keys. Availability comes from the existing Muse login.
    func verifyAPIKey(_: String) async -> (isValid: Bool, errorMessage: String?) {
        (false, "Muse uses your Muse login. Sign in with muse login.")
    }

    private static func mapMuseError(_ error: MuseDictationError) -> CloudTranscriptionError {
        switch error {
        case .missingCredential:
            return .networkError(error)
        case .noTranscript:
            return .noTranscriptionReturned
        case .malformedResponse:
            return .dataEncodingError
        case .serverError(let message):
            return .networkError(MuseDictationError.serverError(message))
        case .connectionFailed, .timeout, .notConnected:
            return .networkError(error)
        }
    }
}

/// Parses the WAV files produced by VoiceInk into the raw bytes Muse expects.
enum MuseWAVDecoder {
    static func pcm16Mono16kHz(from data: Data) throws -> Data {
        guard data.count >= 12,
            data[0..<4].elementsEqual(Data("RIFF".utf8)),
            data[8..<12].elementsEqual(Data("WAVE".utf8))
        else {
            throw MuseWAVError.invalidContainer
        }

        var offset = 12
        var foundFormat = false
        var foundData: Data?
        while offset <= data.count - 8 {
            let chunkID = data[offset..<(offset + 4)]
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            guard chunkSize >= 0, chunkSize <= data.count - offset - 8 else {
                throw MuseWAVError.invalidContainer
            }
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize

            if chunkID.elementsEqual(Data("fmt ".utf8)) {
                guard chunkSize >= 16 else { throw MuseWAVError.unsupportedFormat }
                let audioFormat = readUInt16LE(data, at: payloadStart)
                let channels = readUInt16LE(data, at: payloadStart + 2)
                let sampleRate = readUInt32LE(data, at: payloadStart + 4)
                let byteRate = readUInt32LE(data, at: payloadStart + 8)
                let blockAlign = readUInt16LE(data, at: payloadStart + 12)
                let bitsPerSample = readUInt16LE(data, at: payloadStart + 14)
                guard audioFormat == 1, channels == 1, sampleRate == 16_000,
                    byteRate == 32_000, blockAlign == 2, bitsPerSample == 16
                else {
                    throw MuseWAVError.unsupportedFormat
                }
                foundFormat = true
            } else if chunkID.elementsEqual(Data("data".utf8)) {
                foundData = Data(data[payloadStart..<payloadEnd])
            }

            let paddedSize = chunkSize + (chunkSize % 2)
            guard paddedSize <= data.count - offset - 8 else {
                throw MuseWAVError.invalidContainer
            }
            offset = payloadStart + paddedSize
        }

        guard offset == data.count else {
            throw MuseWAVError.invalidContainer
        }

        guard foundFormat, let pcm = foundData, pcm.count.isMultiple(of: 2) else {
            throw MuseWAVError.unsupportedFormat
        }
        return pcm
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum MuseWAVError: Error, Equatable {
    case invalidContainer
    case unsupportedFormat
}
