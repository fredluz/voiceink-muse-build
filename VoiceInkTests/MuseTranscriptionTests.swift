import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
struct MuseTranscriptionTests {
    @Test func handshakeUsesMuseDuplexFieldsAndRawCredential() throws {
        let data = try #require(MuseDictationClient.handshakeJSON(credential: "login-secret").data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["mode"] as? String == "DEFAULT")
        #expect(object["audioEncoding"] as? String == "PCM_16KHZ")
        #expect(object["model"] as? String == "prod_tbh")
        let authorization = try #require(object["authorization"] as? [String: Any])
        #expect(authorization["accessToken"] as? String == "login-secret")
        #expect(!String(decoding: data, as: UTF8.self).contains("Bearer"))
        #expect(MuseDictationClient.endpoint.absoluteString == "wss://shortwave.facebook.com/voyager/v1/asr/duplex")
    }

    @Test func duplexFinishesWithCumulativeTranscriptAfterKnownEOF() async throws {
        let socket = MuseTestSocket(frames: [
            .string("{\"transcript\":{\"transcript\":\"hello\",\"final\":false}}"),
            .string("{\"transcript\":{\"transcript\":\"hello world\",\"final\":true}}"),
        ])
        let client = MuseDictationClient(
            credential: "login-secret",
            socketFactory: { socket },
            handshakeTimeoutNanoseconds: 1_000_000_000,
            finishTimeoutNanoseconds: 1_000_000_000
        )

        try await client.connect()
        try await client.sendAudio(Data([0, 1]))
        let transcript = try await client.finish()
        #expect(transcript == "hello world")

        let sent = await socket.sentMessages
        #expect(sent.count == 3)
        guard case .string(let handshake) = sent[0] else { Issue.record("missing handshake"); return }
        #expect(handshake.contains("\"accessToken\":\"login-secret\""))
        guard case .data(let audio) = sent[1] else { Issue.record("missing audio"); return }
        #expect(audio == Data([0, 1]))
        guard case .string(let endMarker) = sent[2] else { Issue.record("missing end marker"); return }
        #expect(endMarker == "{\"endStream\":{}}")
    }

    @Test func latestPartialAfterKnownEOFIsAccepted() async throws {
        let socket = MuseTestSocket(frames: [
            .string("{\"transcript\":{\"transcript\":\"partial only\",\"final\":false}}"),
        ])
        let client = MuseDictationClient(
            credential: "login-secret",
            socketFactory: { socket },
            handshakeTimeoutNanoseconds: 1_000_000_000,
            finishTimeoutNanoseconds: 1_000_000_000
        )
        try await client.connect()
        let transcript = try await client.finish()
        #expect(transcript == "partial only")
    }

    @Test func serverErrorNeverReturnsPartialTranscript() async throws {
        let socket = MuseTestSocket(frames: [
            .string("{\"error\":{\"message\":\"unauthorized\",\"errorType\":\"AUTH\",\"errorCode\":\"401\"}}"),
        ])
        let client = MuseDictationClient(
            credential: "login-secret",
            socketFactory: { socket },
            handshakeTimeoutNanoseconds: 1_000_000_000,
            finishTimeoutNanoseconds: 1_000_000_000
        )
        try await client.connect()
        do {
            _ = try await client.finish()
            Issue.record("server error was treated as success")
        } catch let error as MuseDictationError {
            guard case .serverError = error else {
                Issue.record("unexpected Muse error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test func finishTimeoutClosesStalledSocket() async throws {
        let socket = MuseTestSocket(frames: [], stallAfterEnd: true)
        let client = MuseDictationClient(
            credential: "login-secret",
            socketFactory: { socket },
            handshakeTimeoutNanoseconds: 1_000_000_000,
            finishTimeoutNanoseconds: 1_000_000
        )
        try await client.connect()
        do {
            _ = try await client.finish()
            Issue.record("stalled finish was treated as success")
        } catch let error as MuseDictationError {
            guard case .timeout = error else {
                Issue.record("unexpected timeout error: \(error.localizedDescription)")
                return
            }
        }
        #expect(socket.wasCancelled)
    }


    @Test func cancelledConnectClosesStalledSocket() async throws {
        let socket = MuseTestSocket(frames: [], stallBeforeAck: true)
        let client = MuseDictationClient(
            credential: "login-secret",
            socketFactory: { socket },
            handshakeTimeoutNanoseconds: 5_000_000_000,
            finishTimeoutNanoseconds: 5_000_000_000
        )
        let connection = Task { () -> Bool in
            do {
                try await client.connect()
                return false
            } catch {
                return error is CancellationError
            }
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        connection.cancel()
        #expect(await connection.value)
        #expect(socket.wasCancelled)
    }
    @Test func wavDecoderReturnsPCMAndRejectsUnsupportedInput() throws {
        let pcm = Data([0, 1, 2, 3])
        let wav = makeWAV(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        #expect(try MuseWAVDecoder.pcm16Mono16kHz(from: wav) == pcm)

        let stereo = makeWAV(pcm: pcm, sampleRate: 16_000, channels: 2, bitsPerSample: 16)
        #expect(throws: MuseWAVError.unsupportedFormat) {
            _ = try MuseWAVDecoder.pcm16Mono16kHz(from: stereo)
        }
        #expect(throws: MuseWAVError.invalidContainer) {
            _ = try MuseWAVDecoder.pcm16Mono16kHz(from: Data("not wav".utf8))
        }
    }
}

private actor MuseTestSocket: MuseSocket {
    let frames: [URLSessionWebSocketTask.Message]
    let stallAfterEnd: Bool
    let stallBeforeAck: Bool
    private let cancellation = MuseTestCancellation()
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var didSendEndMarker = false
    private var frameIndex = 0
    private var sentAcknowledgement = false
    nonisolated var wasCancelled: Bool { cancellation.isCancelled }

    init(
        frames: [URLSessionWebSocketTask.Message],
        stallAfterEnd: Bool = false,
        stallBeforeAck: Bool = false
    ) {
        self.frames = frames
        self.stallAfterEnd = stallAfterEnd
        self.stallBeforeAck = stallBeforeAck
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sentMessages.append(message)
        if case .string(let value) = message, value == MuseDictationClient.endStreamMessage {
            didSendEndMarker = true
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !sentAcknowledgement {
            if stallBeforeAck {
                while !cancellation.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
            sentAcknowledgement = true
            return .string("{\"sessionId\":\"test-session\"}")
        }
        while !didSendEndMarker {
            if cancellation.isCancelled { throw CancellationError() }
            await Task.yield()
        }
        if stallAfterEnd {
            while !cancellation.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        if frameIndex < frames.count {
            defer { frameIndex += 1 }
            return frames[frameIndex]
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: 57)
    }

    nonisolated func cancel() {
        cancellation.cancel()
    }
}

private final class MuseTestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private func makeWAV(pcm: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    let blockAlign = channels * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    let fmtSize: UInt32 = 16
    let dataSize = UInt32(pcm.count)
    let riffSize = 4 + 8 + fmtSize + 8 + dataSize

    var result = Data("RIFF".utf8)
    result.append(contentsOf: littleEndian(riffSize))
    result.append(contentsOf: Data("WAVEfmt ".utf8))
    result.append(contentsOf: littleEndian(fmtSize))
    result.append(contentsOf: littleEndian(UInt16(1)))
    result.append(contentsOf: littleEndian(channels))
    result.append(contentsOf: littleEndian(sampleRate))
    result.append(contentsOf: littleEndian(byteRate))
    result.append(contentsOf: littleEndian(blockAlign))
    result.append(contentsOf: littleEndian(bitsPerSample))
    result.append(contentsOf: Data("data".utf8))
    result.append(contentsOf: littleEndian(dataSize))
    result.append(pcm)
    return result
}

private func littleEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xff), UInt8(value >> 8)]
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
}
