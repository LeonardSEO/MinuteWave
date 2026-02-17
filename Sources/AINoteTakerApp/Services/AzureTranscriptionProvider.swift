import Foundation

final class AzureTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let providerType: TranscriptionProviderType = .azure

    private static let sampleRate = 16_000
    private static let channels = 1
    private static let bytesPerSample = 2
    private static let bytesPerSecond = sampleRate * channels * bytesPerSample
    private static let maxChunkBytes = 18 * 1_024 * 1_024

    private let keychain: KeychainStore
    private let queue = DispatchQueue(label: "azure.transcription.provider")
    private var activeSessionId: UUID?
    private var config: TranscriptionConfig?
    private var bufferedPCM16 = Data()

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func startSession(config: TranscriptionConfig, sessionId: UUID) async throws {
        guard let azure = config.azureConfig, azure.isTranscriptionConfigured else {
            throw AppError.invalidConfiguration(reason: "Azure transcription is selected but not fully configured.")
        }

        queue.sync {
            self.config = config
            self.activeSessionId = sessionId
            self.bufferedPCM16.removeAll(keepingCapacity: true)
        }
    }

    func ingestAudio(_ buffer: AudioChunk) async {
        queue.sync {
            guard activeSessionId != nil else { return }
            bufferedPCM16.append(buffer.data)
        }
    }

    func stopSession() async throws -> Transcript {
        let captured: (sessionId: UUID, config: TranscriptionConfig, pcm16: Data) = try queue.sync {
            guard let sessionId = activeSessionId else {
                throw AppError.providerUnavailable(reason: "No active Azure transcription session")
            }
            guard let config else {
                throw AppError.invalidConfiguration(reason: "Azure transcription config was lost.")
            }

            let data = bufferedPCM16
            activeSessionId = nil
            self.config = nil
            bufferedPCM16.removeAll(keepingCapacity: false)
            return (sessionId, config, data)
        }

        guard !captured.pcm16.isEmpty else {
            throw AppError.providerUnavailable(reason: "No audio chunks captured for Azure transcription.")
        }

        let pcmChunks = splitPCMIntoUploadChunks(captured.pcm16)
        var priorPromptTail: String?
        var totalConsumedBytes = 0
        var finalSegments: [TranscriptSegment] = []

        for pcmChunk in pcmChunks {
            let chunkStartMs = pcmBytesToMs(totalConsumedBytes)
            totalConsumedBytes += pcmChunk.count
            let chunkEndMs = pcmBytesToMs(totalConsumedBytes)

            let wavData = wavDataFromPCM16Mono16k(pcmChunk)
            let response = try await transcribeChunk(
                wavData: wavData,
                config: captured.config,
                promptTail: priorPromptTail
            )

            if let text = response.text, !text.isEmpty {
                priorPromptTail = continuationPrompt(from: text)
            }

            if response.segments.isEmpty {
                if let text = response.text, !text.isEmpty {
                    finalSegments.append(
                        TranscriptSegment(
                            id: UUID(),
                            sessionId: captured.sessionId,
                            startMs: chunkStartMs,
                            endMs: max(chunkStartMs + 80, chunkEndMs),
                            text: text,
                            confidence: 0.86,
                            sourceProvider: .azure,
                            isFinal: true
                        )
                    )
                }
                continue
            }

            for entry in response.segments {
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let localStart = max(0, Int64((entry.start ?? 0) * 1_000))
                let localEnd = max(localStart, Int64((entry.end ?? 0) * 1_000))
                let startMs = chunkStartMs + localStart
                let endMs = max(startMs + 80, chunkStartMs + localEnd)

                finalSegments.append(
                    TranscriptSegment(
                        id: UUID(),
                        sessionId: captured.sessionId,
                        startMs: startMs,
                        endMs: endMs,
                        text: text,
                        confidence: 0.9,
                        sourceProvider: .azure,
                        isFinal: true
                    )
                )
            }
        }

        if finalSegments.isEmpty {
            throw AppError.providerUnavailable(reason: "Azure returned an empty transcript.")
        }

        finalSegments.sort { lhs, rhs in
            if lhs.startMs == rhs.startMs {
                return lhs.endMs < rhs.endMs
            }
            return lhs.startMs < rhs.startMs
        }

        return Transcript(sessionId: captured.sessionId, segments: finalSegments)
    }

    func partialSegmentsStream() -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    private struct ChunkTranscription {
        struct Segment {
            let start: Double?
            let end: Double?
            let text: String
        }

        let text: String?
        let segments: [Segment]
    }

    private struct WhisperVerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }

        let text: String?
        let segments: [Segment]?
    }

    private func transcribeChunk(
        wavData: Data,
        config: TranscriptionConfig,
        promptTail: String?
    ) async throws -> ChunkTranscription {
        guard let azure = config.azureConfig else {
            throw AppError.invalidConfiguration(reason: "Azure config ontbreekt voor transcriptie.")
        }
        guard let apiKey = try keychain.get(azure.apiKeyRef), !apiKey.isEmpty else {
            throw AppError.invalidConfiguration(reason: "Azure API key ontbreekt in Keychain.")
        }
        guard var components = URLComponents(string: azure.endpoint),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false else {
            throw AppError.invalidConfiguration(reason: "Azure endpoint is ongeldig. Gebruik een https endpoint.")
        }

        components.path = "/openai/deployments/\(azure.transcriptionDeployment)/audio/transcriptions"
        components.queryItems = [URLQueryItem(name: "api-version", value: azure.transcriptionAPIVersion)]
        guard let url = components.url else {
            throw AppError.invalidConfiguration(reason: "Kan Azure transcription URL niet bouwen.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendFormField(named: "model", value: AzureModelPolicy.transcriptionModel, boundary: boundary)
        body.appendFormField(named: "response_format", value: "verbose_json", boundary: boundary)
        body.appendFormField(named: "temperature", value: "0", boundary: boundary)
        if let language = fixedLanguage(from: config.languageMode) {
            body.appendFormField(named: "language", value: language, boundary: boundary)
        }
        if let promptTail, !promptTail.isEmpty {
            body.appendFormField(named: "prompt", value: promptTail, boundary: boundary)
        }
        body.appendFileField(
            named: "file",
            filename: "audio.wav",
            mimeType: "audio/wav",
            data: wavData,
            boundary: boundary
        )
        body.appendUTF8("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await HTTPRetryPolicy.send(
            request: request,
            configuration: HTTPRetryPolicy.azureDefault
        )

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw AppError.networkFailure(reason: "Azure authentication failed (\(http.statusCode)).")
        case 429:
            throw AppError.networkFailure(reason: "Azure rate limit reached (429).")
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.networkFailure(reason: "Azure transcription error \(http.statusCode): \(text)")
        }

        let decoder = JSONDecoder()
        if let parsed = try? decoder.decode(WhisperVerboseResponse.self, from: data) {
            let text = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = (parsed.segments ?? []).compactMap { item -> ChunkTranscription.Segment? in
                let segmentText = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segmentText.isEmpty else { return nil }
                return ChunkTranscription.Segment(
                    start: item.start,
                    end: item.end,
                    text: segmentText
                )
            }
            return ChunkTranscription(text: text?.isEmpty == true ? nil : text, segments: segments)
        }

        let fallback = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChunkTranscription(text: fallback, segments: [])
    }

    private func splitPCMIntoUploadChunks(_ pcmData: Data) -> [Data] {
        guard !pcmData.isEmpty else { return [] }
        let alignedMaxChunk = Self.maxChunkBytes - (Self.maxChunkBytes % Self.bytesPerSample)
        if pcmData.count <= alignedMaxChunk {
            return [pcmData]
        }

        var chunks: [Data] = []
        var offset = 0
        while offset < pcmData.count {
            let rawEnd = min(offset + alignedMaxChunk, pcmData.count)
            var alignedEnd = rawEnd - ((rawEnd - offset) % Self.bytesPerSample)
            if alignedEnd <= offset {
                alignedEnd = min(pcmData.count, offset + Self.bytesPerSample)
            }
            chunks.append(pcmData.subdata(in: offset..<alignedEnd))
            offset = alignedEnd
        }
        return chunks
    }

    private func fixedLanguage(from mode: LanguageMode) -> String? {
        switch mode {
        case .fixed(let code):
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .auto:
            return nil
        }
    }

    private func continuationPrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return String(trimmed.suffix(220))
    }

    private func pcmBytesToMs(_ bytes: Int) -> Int64 {
        Int64((Double(bytes) / Double(Self.bytesPerSecond)) * 1_000.0)
    }

    private func wavDataFromPCM16Mono16k(_ pcmData: Data) -> Data {
        var wav = Data(capacity: pcmData.count + 44)
        let riffChunkSize = UInt32(36 + pcmData.count)
        let byteRate = UInt32(Self.sampleRate * Self.channels * Self.bytesPerSample)
        let blockAlign = UInt16(Self.channels * Self.bytesPerSample)
        let bitsPerSample = UInt16(Self.bytesPerSample * 8)
        let subchunk2Size = UInt32(pcmData.count)

        wav.appendUTF8("RIFF")
        wav.appendLittleEndian(riffChunkSize)
        wav.appendUTF8("WAVE")
        wav.appendUTF8("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(Self.channels))
        wav.appendLittleEndian(UInt32(Self.sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.appendUTF8("data")
        wav.appendLittleEndian(subchunk2Size)
        wav.append(pcmData)

        return wav
    }
}

private extension Data {
    mutating func appendUTF8(_ text: String) {
        if let data = text.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendFormField(named name: String, value: String, boundary: String) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendUTF8(value)
        appendUTF8("\r\n")
    }

    mutating func appendFileField(
        named name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendUTF8("\r\n")
    }
}
