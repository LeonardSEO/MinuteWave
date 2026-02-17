import FluidAudio
import Foundation

final class LocalFluidAudioProvider: TranscriptionProvider, @unchecked Sendable {
    enum PreparationStep: Sendable {
        case checkingCache
        case downloadingAsr
        case initializingAsr
        case downloadingDiarizer
        case initializingDiarizer
    }

    enum RuntimeEvent: Sendable {
        case preparationStarted
        case preparationProgress(
            progress: Double,
            status: ModelInstallStatus,
            step: PreparationStep
        )
        case preparationReady
        case preparationFailed(message: String)
        case inferenceStarted
        case inferenceCompleted
        case warning(message: String)
    }

    private struct WordTiming: Sendable {
        let word: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
    }

    private struct AssignedWord: Sendable {
        let word: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
        let speakerLabel: String?
    }

    private struct RepoManifestEntry: Sendable {
        let relativePath: String
        let expectedSize: Int64?
    }

    private struct RepoManifest: Sendable {
        let entries: [RepoManifestEntry]
        let totalKnownBytes: Int64
    }

    private struct HuggingFaceTreeItem: Decodable {
        let path: String
        let type: String
        let size: Int64?
    }

    private enum Constants {
        static let sampleRate = 16_000.0
        static let bytesPerSample = 2
        static let maxIntraSegmentGapSeconds = 1.4
        static let monitorIntervalMs: UInt64 = 250
    }

    let providerType: TranscriptionProviderType = .localVoxtral

    private let queue = DispatchQueue(label: "local.fluidaudio.provider")
    private var activeSessionId: UUID?
    private var activeConfig: TranscriptionConfig?
    private var bufferedPCM16 = Data()

    private var asrManager: AsrManager?
    private var offlineDiarizerManager: OfflineDiarizerManager?
    private var modelsPrepared = false
    private var isPreparingModels = false
    private var lastPreparationError: String?

    var onRuntimeEvent: ((RuntimeEvent) -> Void)?

    func startSession(config: TranscriptionConfig, sessionId: UUID) async throws {
        queue.sync {
            activeSessionId = sessionId
            activeConfig = config
            bufferedPCM16.removeAll(keepingCapacity: true)
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
                throw AppError.providerUnavailable(reason: "No active local transcription session.")
            }
            guard let activeConfig else {
                throw AppError.invalidConfiguration(reason: "Local transcription config was lost.")
            }

            let capturedData = bufferedPCM16
            self.activeSessionId = nil
            self.activeConfig = nil
            bufferedPCM16.removeAll(keepingCapacity: false)

            return (sessionId, activeConfig, capturedData)
        }

        guard !captured.pcm16.isEmpty else {
            throw AppError.providerUnavailable(reason: "No audio chunks captured for local transcription.")
        }

        try await prepareModelsIfNeeded(modelRef: captured.config.localModelRef)
        emitRuntimeEvent(.inferenceStarted)
        defer { emitRuntimeEvent(.inferenceCompleted) }

        let audioSamples = pcm16ToFloatSamples(captured.pcm16)
        guard !audioSamples.isEmpty else {
            throw AppError.providerUnavailable(reason: "Local capture yielded empty samples.")
        }

        guard let asrManager = queue.sync(execute: { asrManager }) else {
            throw AppError.providerUnavailable(reason: "ASR manager is not initialized.")
        }

        let rawAsr = try await asrManager.transcribe(audioSamples, source: .system)
        let normalizedAsr = normalizeASRResult(rawAsr)
        let transcriptText = normalizedAsr.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !transcriptText.isEmpty else {
            throw AppError.providerUnavailable(reason: "Local ASR returned an empty transcript.")
        }

        let wordTimings = mergeTokensIntoWords(normalizedAsr.tokenTimings ?? [])
        let fallbackSegments = buildPlainSegments(
            text: transcriptText,
            wordTimings: wordTimings,
            sessionId: captured.sessionId
        )

        guard let diarizer = queue.sync(execute: { offlineDiarizerManager }) else {
            return Transcript(sessionId: captured.sessionId, segments: fallbackSegments)
        }

        do {
            let diarization = try await diarizer.process(audio: audioSamples)
            let enriched = buildSpeakerSegments(
                words: wordTimings,
                diarizationSegments: diarization.segments,
                sessionId: captured.sessionId,
                fallbackText: transcriptText
            )
            if enriched.isEmpty {
                return Transcript(sessionId: captured.sessionId, segments: fallbackSegments)
            }
            return Transcript(sessionId: captured.sessionId, segments: enriched)
        } catch {
            emitRuntimeEvent(.warning(message: "Diarization unavailable: \(error.localizedDescription)"))
            return Transcript(sessionId: captured.sessionId, segments: fallbackSegments)
        }
    }

    func partialSegmentsStream() -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func prepareModelsIfNeeded(modelRef: LocalModelRef?) async throws {
        _ = modelRef
        let claimedPreparation: Bool? = queue.sync {
            if modelsPrepared { return false }
            if isPreparingModels { return nil }
            isPreparingModels = true
            lastPreparationError = nil
            return true
        }

        if claimedPreparation == false {
            return
        }

        if claimedPreparation == nil {
            while true {
                let snapshot = queue.sync { (modelsPrepared, isPreparingModels, lastPreparationError) }
                if snapshot.0 {
                    return
                }
                if !snapshot.1 {
                    let reason = snapshot.2 ?? "Unknown local model preparation failure."
                    throw AppError.providerUnavailable(reason: reason)
                }
                if Task.isCancelled {
                    throw AppError.providerUnavailable(reason: "Local model preparation was cancelled.")
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        emitRuntimeEvent(.preparationStarted)
        emitPreparationProgress(
            progress: 0.02,
            status: .downloading,
            step: .checkingCache
        )

        do {
            let asrDirectory = AppPaths.fluidAudioModelsDirectory
                .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
            let asrCacheDirectory = AppPaths.fluidAudioModelsDirectory
                .appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)
            let diarizerCacheDirectory = AppPaths.fluidAudioModelsDirectory
                .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)

            async let asrManifestTask = fetchRepoManifest(
                repo: .parakeet,
                requiredModelRoots: ModelNames.ASR.requiredModels,
                includeMetadataExtensions: Set(["json", "txt"])
            )
            async let diarizerManifestTask = fetchRepoManifest(
                repo: .diarizer,
                requiredModelRoots: ModelNames.OfflineDiarizer.requiredModels,
                includeMetadataExtensions: Set(["json", "txt", "model"])
            )

            let asrManifest = await asrManifestTask
            let diarizerManifest = await diarizerManifestTask

            emitPreparationProgress(
                progress: 0.05,
                status: .downloading,
                step: .downloadingAsr
            )
            let asrMonitor = startProgressMonitor(
                manifest: asrManifest,
                cacheDirectory: asrCacheDirectory,
                range: 0.05...0.58,
                status: .downloading,
                step: .downloadingAsr
            )
            defer { asrMonitor?.cancel() }
            let loadedAsrModels = try await AsrModels.downloadAndLoad(to: asrDirectory, version: .v3)
            emitPreparationProgress(
                progress: 0.58,
                status: .verifying,
                step: .initializingAsr
            )
            let localAsrManager = AsrManager(config: .default)
            try await localAsrManager.initialize(models: loadedAsrModels)
            emitPreparationProgress(
                progress: 0.68,
                status: .verifying,
                step: .initializingAsr
            )

            let diarizationConfig = OfflineDiarizerConfig(clusteringThreshold: 0.6)
            let localDiarizer = OfflineDiarizerManager(config: diarizationConfig)
            emitPreparationProgress(
                progress: 0.72,
                status: .downloading,
                step: .downloadingDiarizer
            )
            let diarizerMonitor = startProgressMonitor(
                manifest: diarizerManifest,
                cacheDirectory: diarizerCacheDirectory,
                range: 0.72...0.95,
                status: .downloading,
                step: .downloadingDiarizer
            )
            defer { diarizerMonitor?.cancel() }
            try await localDiarizer.prepareModels(directory: AppPaths.fluidAudioModelsDirectory)
            emitPreparationProgress(
                progress: 0.97,
                status: .verifying,
                step: .initializingDiarizer
            )

            queue.sync {
                asrManager = localAsrManager
                offlineDiarizerManager = localDiarizer
                modelsPrepared = true
                isPreparingModels = false
                lastPreparationError = nil
            }
            emitRuntimeEvent(.preparationReady)
        } catch {
            let message = "FluidAudio model preparation failed: \(error.localizedDescription)"
            queue.sync {
                modelsPrepared = false
                isPreparingModels = false
                lastPreparationError = message
            }
            emitRuntimeEvent(.preparationFailed(message: message))
            throw AppError.providerUnavailable(reason: message)
        }
    }

    private func pcm16ToFloatSamples(_ pcm16: Data) -> [Float] {
        guard !pcm16.isEmpty else { return [] }
        let sampleCount = pcm16.count / Constants.bytesPerSample
        if sampleCount == 0 { return [] }

        return pcm16.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let samples = baseAddress.bindMemory(to: Int16.self, capacity: sampleCount)
            var floats = [Float]()
            floats.reserveCapacity(sampleCount)
            for index in 0..<sampleCount {
                let sample = samples[index]
                floats.append(Float(sample) / Float(Int16.max))
            }
            return floats
        }
    }

    private func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
        guard !tokenTimings.isEmpty else { return [] }

        var words: [WordTiming] = []
        var currentWord = ""
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval = 0
        var confidences: [Float] = []

        for timing in tokenTimings {
            let token = timing.token
            let startsNewWord = token.hasPrefix(" ") || token.hasPrefix("\n") || token.hasPrefix("\t")
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            if startsNewWord, !currentWord.isEmpty, let start = currentStart {
                words.append(
                    WordTiming(
                        word: currentWord,
                        startTime: start,
                        endTime: currentEnd,
                        confidence: averageConfidence(confidences)
                    )
                )
                currentWord = cleaned
                currentStart = timing.startTime
                currentEnd = timing.endTime
                confidences = [timing.confidence]
                continue
            }

            if currentStart == nil {
                currentStart = timing.startTime
                currentWord = cleaned
            } else if startsNewWord {
                currentWord = cleaned
            } else {
                currentWord += cleaned
            }
            currentEnd = timing.endTime
            confidences.append(timing.confidence)
        }

        if !currentWord.isEmpty, let currentStart {
            words.append(
                WordTiming(
                    word: currentWord,
                    startTime: currentStart,
                    endTime: currentEnd,
                    confidence: averageConfidence(confidences)
                )
            )
        }

        return words
    }

    private func buildSpeakerSegments(
        words: [WordTiming],
        diarizationSegments: [TimedSpeakerSegment],
        sessionId: UUID,
        fallbackText: String
    ) -> [TranscriptSegment] {
        if words.isEmpty {
            return buildPlainSegments(text: fallbackText, wordTimings: [], sessionId: sessionId)
        }

        let diarization = diarizationSegments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var speakerDisplayMap: [String: String] = [:]
        var nextSpeakerIndex = 1
        let assigned = words.map { word in
            let rawSpeakerId = bestSpeakerLabel(for: word, diarizationSegments: diarization)
            let speakerLabel: String?
            if let rawSpeakerId {
                if let existing = speakerDisplayMap[rawSpeakerId] {
                    speakerLabel = existing
                } else {
                    let generated = "S\(nextSpeakerIndex)"
                    speakerDisplayMap[rawSpeakerId] = generated
                    nextSpeakerIndex += 1
                    speakerLabel = generated
                }
            } else {
                speakerLabel = nil
            }
            return AssignedWord(
                word: word.word,
                startTime: word.startTime,
                endTime: word.endTime,
                confidence: word.confidence,
                speakerLabel: speakerLabel
            )
        }

        var segments: [TranscriptSegment] = []
        var bucket: [AssignedWord] = []

        func flushBucket() {
            guard let first = bucket.first, let last = bucket.last else {
                bucket.removeAll(keepingCapacity: true)
                return
            }
            let text = bucket.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                bucket.removeAll(keepingCapacity: true)
                return
            }

            let confidence = Double(bucket.map(\.confidence).reduce(0, +)) / Double(bucket.count)
            let startMs = Int64((first.startTime * 1_000).rounded())
            let endMs = Int64((last.endTime * 1_000).rounded())
            let boundedEnd = max(startMs + 80, endMs)
            let label = bucket.allSatisfy { $0.speakerLabel == first.speakerLabel } ? first.speakerLabel : nil

            segments.append(
                TranscriptSegment(
                    id: UUID(),
                    sessionId: sessionId,
                    startMs: startMs,
                    endMs: boundedEnd,
                    text: text,
                    confidence: confidence,
                    sourceProvider: .localVoxtral,
                    isFinal: true,
                    speakerLabel: label
                )
            )
            bucket.removeAll(keepingCapacity: true)
        }

        for word in assigned {
            if bucket.isEmpty {
                bucket.append(word)
                continue
            }

            let previous = bucket[bucket.count - 1]
            let gap = max(0, word.startTime - previous.endTime)
            let sameSpeaker = previous.speakerLabel == word.speakerLabel

            if sameSpeaker && gap <= Constants.maxIntraSegmentGapSeconds {
                bucket.append(word)
            } else {
                flushBucket()
                bucket.append(word)
            }
        }
        flushBucket()

        if segments.isEmpty {
            return buildPlainSegments(text: fallbackText, wordTimings: words, sessionId: sessionId)
        }
        return segments
    }

    private func buildPlainSegments(
        text: String,
        wordTimings: [WordTiming],
        sessionId: UUID
    ) -> [TranscriptSegment] {
        if wordTimings.isEmpty {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return [] }
            let durationMs = max(80, Int64((Double(cleaned.count) / 18.0) * 1_000.0))
            return [
                TranscriptSegment(
                    id: UUID(),
                    sessionId: sessionId,
                    startMs: 0,
                    endMs: durationMs,
                    text: cleaned,
                    confidence: 0.88,
                    sourceProvider: .localVoxtral,
                    isFinal: true,
                    speakerLabel: nil
                )
            ]
        }

        var segments: [TranscriptSegment] = []
        var bucket: [WordTiming] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else {
                bucket.removeAll(keepingCapacity: true)
                return
            }
            let text = bucket.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                bucket.removeAll(keepingCapacity: true)
                return
            }
            let confidence = Double(bucket.map(\.confidence).reduce(0, +)) / Double(bucket.count)
            let startMs = Int64((first.startTime * 1_000).rounded())
            let endMs = max(startMs + 80, Int64((last.endTime * 1_000).rounded()))
            segments.append(
                TranscriptSegment(
                    id: UUID(),
                    sessionId: sessionId,
                    startMs: startMs,
                    endMs: endMs,
                    text: text,
                    confidence: confidence,
                    sourceProvider: .localVoxtral,
                    isFinal: true,
                    speakerLabel: nil
                )
            )
            bucket.removeAll(keepingCapacity: true)
        }

        for word in wordTimings {
            if bucket.isEmpty {
                bucket.append(word)
                continue
            }
            let previous = bucket[bucket.count - 1]
            if (word.startTime - previous.endTime) > Constants.maxIntraSegmentGapSeconds {
                flush()
            }
            bucket.append(word)
        }
        flush()

        return segments
    }

    private func bestSpeakerLabel(
        for word: WordTiming,
        diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
        guard !diarizationSegments.isEmpty else { return nil }
        let midpoint = Float((word.startTime + word.endTime) / 2.0)
        if let direct = diarizationSegments.first(where: { midpoint >= $0.startTimeSeconds && midpoint <= $0.endTimeSeconds }) {
            return direct.speakerId
        }

        var best: (speaker: String, overlap: Double)?
        for segment in diarizationSegments {
            let overlap = max(
                0,
                min(word.endTime, Double(segment.endTimeSeconds)) - max(word.startTime, Double(segment.startTimeSeconds))
            )
            if overlap <= 0 { continue }
            if let current = best {
                if overlap > current.overlap {
                    best = (segment.speakerId, overlap)
                }
            } else {
                best = (segment.speakerId, overlap)
            }
        }
        return best?.speaker
    }

    private func averageConfidence(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0.85 }
        return values.reduce(0, +) / Float(values.count)
    }

    private func normalizeASRResult(_ result: ASRResult) -> ASRResult {
        // FluidAudio 0.12.1 does not expose the ITN normalizer in the public API.
        // Keep output unchanged as a safe fallback.
        result
    }

    private func emitPreparationProgress(
        progress: Double,
        status: ModelInstallStatus,
        step: PreparationStep
    ) {
        emitRuntimeEvent(
            .preparationProgress(
                progress: min(max(progress, 0.0), 1.0),
                status: status,
                step: step
            )
        )
    }

    private func fetchRepoManifest(
        repo: Repo,
        requiredModelRoots: Set<String>,
        includeMetadataExtensions: Set<String>
    ) async -> RepoManifest? {
        do {
            return try await buildRepoManifest(
                repo: repo,
                requiredModelRoots: requiredModelRoots,
                includeMetadataExtensions: includeMetadataExtensions
            )
        } catch {
            return nil
        }
    }

    private func buildRepoManifest(
        repo: Repo,
        requiredModelRoots: Set<String>,
        includeMetadataExtensions: Set<String>
    ) async throws -> RepoManifest {
        let subPath = repo.subPath
        let patterns = requiredModelRoots
            .map { modelName in
                if let subPath {
                    return "\(subPath)/\(modelName)/"
                }
                return "\(modelName)/"
            }
            .sorted()

        var pendingPaths = [subPath ?? ""]
        var visitedPaths = Set<String>()
        var fileMap: [String: RepoManifestEntry] = [:]

        while let currentPath = pendingPaths.popLast() {
            if visitedPaths.contains(currentPath) {
                continue
            }
            visitedPaths.insert(currentPath)

            let items = try await fetchTreeItems(repo: repo, path: currentPath)
            for item in items {
                if item.type == "directory" {
                    if shouldTraverseDirectory(item.path, patterns: patterns, subPath: subPath) {
                        pendingPaths.append(item.path)
                    }
                    continue
                }

                guard item.type == "file" else { continue }
                guard
                    shouldIncludeFile(
                        item.path,
                        patterns: patterns,
                        subPath: subPath,
                        includeMetadataExtensions: includeMetadataExtensions
                    )
                else {
                    continue
                }

                let localRelativePath: String
                if let subPath, item.path.hasPrefix("\(subPath)/") {
                    localRelativePath = String(item.path.dropFirst(subPath.count + 1))
                } else {
                    localRelativePath = item.path
                }

                guard !localRelativePath.isEmpty else { continue }
                let expectedSize = (item.size ?? -1) > 0 ? item.size : nil
                fileMap[localRelativePath] = RepoManifestEntry(
                    relativePath: localRelativePath,
                    expectedSize: expectedSize
                )
            }
        }

        let entries = fileMap.values.sorted { $0.relativePath < $1.relativePath }
        let totalKnownBytes = entries.reduce(into: Int64(0)) { result, entry in
            if let expectedSize = entry.expectedSize, expectedSize > 0 {
                result += expectedSize
            }
        }

        return RepoManifest(entries: entries, totalKnownBytes: totalKnownBytes)
    }

    private func fetchTreeItems(repo: Repo, path: String) async throws -> [HuggingFaceTreeItem] {
        let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
        let treeURL = try ModelRegistry.apiModels(repo.remotePath, apiPath)
        let (data, response) = try await DownloadUtils.fetchWithAuth(from: treeURL)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw NSError(
                    domain: "LocalFluidAudioProvider",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Manifest request failed for \(repo.remotePath)"]
                )
            }
        }

        return try JSONDecoder().decode([HuggingFaceTreeItem].self, from: data)
    }

    private func shouldTraverseDirectory(
        _ itemPath: String,
        patterns: [String],
        subPath: String?
    ) -> Bool {
        if let subPath {
            return itemPath == subPath
                || itemPath.hasPrefix("\(subPath)/")
                || patterns.contains { pattern in
                    itemPath.hasPrefix(pattern) || pattern.hasPrefix(itemPath + "/")
                }
        }

        if patterns.isEmpty { return true }
        return patterns.contains { pattern in
            itemPath.hasPrefix(pattern) || pattern.hasPrefix(itemPath + "/")
        }
    }

    private func shouldIncludeFile(
        _ itemPath: String,
        patterns: [String],
        subPath: String?,
        includeMetadataExtensions: Set<String>
    ) -> Bool {
        let hasMetadataExtension = includeMetadataExtensions.contains { ext in
            itemPath.lowercased().hasSuffix(".\(ext.lowercased())")
        }

        if let subPath {
            let isInSubPath = itemPath.hasPrefix("\(subPath)/")
            let matchesPattern = patterns.isEmpty || patterns.contains { itemPath.hasPrefix($0) }
            return isInSubPath && (matchesPattern || hasMetadataExtension)
        }

        return patterns.isEmpty || patterns.contains { itemPath.hasPrefix($0) } || hasMetadataExtension
    }

    private func startProgressMonitor(
        manifest: RepoManifest?,
        cacheDirectory: URL,
        range: ClosedRange<Double>,
        status: ModelInstallStatus,
        step: PreparationStep
    ) -> Task<Void, Never>? {
        guard range.upperBound > range.lowerBound else { return nil }

        return Task {
            let startedAt = Date()
            while !Task.isCancelled {
                let completion: Double
                if let manifest {
                    completion = calculateManifestCompletion(manifest, cacheDirectory: cacheDirectory)
                } else {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    completion = min(0.96, max(0.0, elapsed / 240.0))
                }

                let stageProgress = range.lowerBound + ((range.upperBound - range.lowerBound) * completion)
                emitPreparationProgress(progress: stageProgress, status: status, step: step)
                try? await Task.sleep(nanoseconds: Constants.monitorIntervalMs * 1_000_000)
            }
        }
    }

    private func calculateManifestCompletion(
        _ manifest: RepoManifest,
        cacheDirectory: URL
    ) -> Double {
        guard !manifest.entries.isEmpty else { return 1.0 }

        let fileManager = FileManager.default
        let unknownEntries = manifest.entries.filter { entry in
            guard let expectedSize = entry.expectedSize else { return true }
            return expectedSize <= 0
        }

        var knownDownloadedBytes: Int64 = 0
        var unknownDownloadedCount = 0

        for entry in manifest.entries {
            let localURL = cacheDirectory.appendingPathComponent(entry.relativePath, isDirectory: false)
            guard
                let attrs = try? fileManager.attributesOfItem(atPath: localURL.path),
                let sizeNumber = attrs[.size] as? NSNumber
            else {
                continue
            }

            let onDiskBytes = max(Int64(0), sizeNumber.int64Value)
            if let expectedSize = entry.expectedSize, expectedSize > 0 {
                knownDownloadedBytes += min(onDiskBytes, expectedSize)
            } else {
                unknownDownloadedCount += 1
            }
        }

        let knownFraction: Double
        if manifest.totalKnownBytes > 0 {
            knownFraction = Double(knownDownloadedBytes) / Double(manifest.totalKnownBytes)
        } else {
            knownFraction = 0
        }

        let unknownFraction: Double
        if unknownEntries.isEmpty {
            unknownFraction = 1
        } else {
            unknownFraction = Double(unknownDownloadedCount) / Double(unknownEntries.count)
        }

        if manifest.totalKnownBytes > 0 {
            return min(1.0, max(0.0, (knownFraction * 0.9) + (unknownFraction * 0.1)))
        }
        return min(1.0, max(0.0, unknownFraction))
    }

    private func emitRuntimeEvent(_ event: RuntimeEvent) {
        onRuntimeEvent?(event)
    }
}
