import Foundation

final class OpenAITranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let providerType: TranscriptionProviderType = .openAI

    private static let sampleRate = 16_000
    private static let channels = 1
    private static let bytesPerSample = 2
    private static let bytesPerSecond = sampleRate * channels * bytesPerSample
    private static let maxChunkBytes = 18 * 1_024 * 1_024

    private let keychain: KeychainStore
    private let queue = DispatchQueue(label: "openai.transcription.provider")
    private var activeSessionId: UUID?
    private var config: TranscriptionConfig?
    private var bufferedPCM16 = Data()

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func startSession(config: TranscriptionConfig, sessionId: UUID) async throws {
        guard let openAI = config.openAIConfig, openAI.isConfigured else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.openai.config_incomplete"))
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
                throw AppError.providerUnavailable(reason: L10n.tr("error.openai.no_active_transcription_session"))
            }
            guard let config else {
                throw AppError.invalidConfiguration(reason: L10n.tr("error.openai.transcription_config_lost"))
            }

            let data = bufferedPCM16
            activeSessionId = nil
            self.config = nil
            bufferedPCM16.removeAll(keepingCapacity: false)
            return (sessionId, config, data)
        }

        guard !captured.pcm16.isEmpty else {
            throw AppError.providerUnavailable(reason: L10n.tr("error.openai.no_audio_chunks"))
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
                            sourceProvider: .openAI,
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
                        sourceProvider: .openAI,
                        isFinal: true
                    )
                )
            }
        }

        if finalSegments.isEmpty {
            throw AppError.providerUnavailable(reason: L10n.tr("error.openai.empty_transcript"))
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
        guard let openAI = config.openAIConfig else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.openai.config_missing_transcription"))
        }
        guard let apiKey = try keychain.get(openAI.apiKeyRef), !apiKey.isEmpty else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.openai.api_key_missing", openAI.apiKeyRef))
        }

        guard let url = transcriptionURL(baseURL: openAI.baseURL) else {
            throw AppError.invalidConfiguration(reason: L10n.tr("error.openai.transcription_url_invalid"))
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendOpenAIFormField(named: "model", value: openAI.transcriptionModel, boundary: boundary)
        body.appendOpenAIFormField(named: "response_format", value: "verbose_json", boundary: boundary)
        body.appendOpenAIFormField(named: "temperature", value: "0", boundary: boundary)
        if let language = fixedLanguage(from: config.languageMode) {
            body.appendOpenAIFormField(named: "language", value: language, boundary: boundary)
        }
        if let promptTail, !promptTail.isEmpty {
            body.appendOpenAIFormField(named: "prompt", value: promptTail, boundary: boundary)
        }
        body.appendOpenAIFileField(
            named: "file",
            filename: "audio.wav",
            mimeType: "audio/wav",
            data: wavData,
            boundary: boundary
        )
        body.appendOpenAIUTF8("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await HTTPRetryPolicy.send(
            request: request,
            configuration: HTTPRetryPolicy.azureDefault
        )

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw AppError.networkFailure(reason: L10n.tr("error.openai.auth_failed", http.statusCode))
        case 429:
            throw AppError.networkFailure(reason: L10n.tr("error.openai.rate_limited"))
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.networkFailure(reason: L10n.tr("error.openai.http", http.statusCode, text))
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

    private func transcriptionURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        var basePath = components.path
        if basePath.isEmpty {
            basePath = "/v1"
        }
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        components.path = "\(basePath)/audio/transcriptions"
        return components.url
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

        wav.appendOpenAIUTF8("RIFF")
        wav.appendOpenAILittleEndian(riffChunkSize)
        wav.appendOpenAIUTF8("WAVE")
        wav.appendOpenAIUTF8("fmt ")
        wav.appendOpenAILittleEndian(UInt32(16))
        wav.appendOpenAILittleEndian(UInt16(1))
        wav.appendOpenAILittleEndian(UInt16(Self.channels))
        wav.appendOpenAILittleEndian(UInt32(Self.sampleRate))
        wav.appendOpenAILittleEndian(byteRate)
        wav.appendOpenAILittleEndian(blockAlign)
        wav.appendOpenAILittleEndian(bitsPerSample)
        wav.appendOpenAIUTF8("data")
        wav.appendOpenAILittleEndian(subchunk2Size)
        wav.append(pcmData)

        return wav
    }
}

private extension Data {
    mutating func appendOpenAIUTF8(_ text: String) {
        if let data = text.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendOpenAILittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendOpenAIFormField(named name: String, value: String, boundary: String) {
        appendOpenAIUTF8("--\(boundary)\r\n")
        appendOpenAIUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendOpenAIUTF8(value)
        appendOpenAIUTF8("\r\n")
    }

    mutating func appendOpenAIFileField(
        named name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        appendOpenAIUTF8("--\(boundary)\r\n")
        appendOpenAIUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendOpenAIUTF8("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendOpenAIUTF8("\r\n")
    }
}
