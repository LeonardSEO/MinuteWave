import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

@available(macOS 13.0, *)
private final class SystemAudioOutputBridge: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        handler(sampleBuffer)
    }
}

final class HybridAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private enum Constants {
        static let sampleRate = 16_000
        static let channels = 1
        static let chunkDurationMs: Int64 = 80
        static let chunkByteCount = Int((Double(sampleRate) * Double(chunkDurationMs) / 1_000.0) * Double(MemoryLayout<Int16>.size))
    }

    private let stateQueue = DispatchQueue(label: "audio.capture.engine.state")
    private let processingQueue = DispatchQueue(label: "audio.capture.engine.processing")

    private var streamPair = AsyncStream<AudioChunk>.makeStream()
    private var isRunning = false
    private var isPaused = false
    private var captureStartedAt: Date?

    private var micEngine: AVAudioEngine?
    private var systemStream: SCStream?
    private var systemOutputBridge: AnyObject?

    private var micAccumulator = Data()
    private var systemAccumulator = Data()
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    private var micConverterInputSignature: String?
    private var systemConverterInputSignature: String?
    private var didLogFirstMicChunk: Bool = false
    private var desiredCaptureMode: LocalAudioCaptureMode = .microphoneAndSystem
    private var captureMode: LocalAudioCaptureMode = .microphoneOnly
    private var captureWarning: String?

    func configure(captureMode: LocalAudioCaptureMode) {
        stateQueue.sync {
            desiredCaptureMode = captureMode
        }
    }

    func start() async throws {
        try await ensureMicrophonePermission()

        let startup = stateQueue.sync { () -> (shouldStart: Bool, desiredMode: LocalAudioCaptureMode) in
            if isRunning { return (false, desiredCaptureMode) }
            isRunning = true
            isPaused = false
            captureStartedAt = Date()
            micAccumulator.removeAll(keepingCapacity: true)
            systemAccumulator.removeAll(keepingCapacity: true)
            micConverter = nil
            systemConverter = nil
            micConverterInputSignature = nil
            systemConverterInputSignature = nil
            didLogFirstMicChunk = false
            captureMode = .microphoneOnly
            captureWarning = nil
            streamPair.continuation.finish()
            streamPair = AsyncStream<AudioChunk>.makeStream()
            return (true, desiredCaptureMode)
        }

        guard startup.shouldStart else { return }

        do {
            try startMicrophoneCapture()

            guard startup.desiredMode == .microphoneAndSystem else {
                stateQueue.sync {
                    captureMode = .microphoneOnly
                    captureWarning = nil
                }
                return
            }

            let screenPermission = await Permissions.refreshScreenCaptureState()
            guard screenPermission == .granted else {
                stateQueue.sync {
                    captureMode = .microphoneOnly
                    captureWarning = screenCapturePermissionGuidanceMessage()
                }
                NSLog("System audio capture skipped: Screen Recording permission not granted.")
                return
            }

            do {
                try await startSystemAudioCapture()
                stateQueue.sync {
                    captureMode = .microphoneAndSystem
                    captureWarning = nil
                }
            } catch {
                // System audio capture is optional for v1. If TCC is denied (or setup fails),
                // continue with microphone-only capture instead of failing the whole session.
                stateQueue.sync {
                    systemStream = nil
                    systemOutputBridge = nil
                    captureMode = .microphoneOnly
                    captureWarning = warningMessage(for: error)
                }
                NSLog("System audio capture unavailable, continuing with microphone only: \(error.localizedDescription)")
            }
        } catch {
            await stop()
            throw error
        }
    }

    func pause() async {
        stateQueue.sync {
            guard isRunning else { return }
            isPaused.toggle()
        }
    }

    func stop() async {
        let resources = stateQueue.sync { () -> (AVAudioEngine?, SCStream?) in
            guard isRunning else {
                return (nil, nil)
            }

            isRunning = false
            isPaused = false
            captureStartedAt = nil
            micAccumulator.removeAll(keepingCapacity: true)
            systemAccumulator.removeAll(keepingCapacity: true)
            micConverter = nil
            systemConverter = nil
            micConverterInputSignature = nil
            systemConverterInputSignature = nil
            didLogFirstMicChunk = false
            captureMode = .microphoneOnly
            captureWarning = nil

            let currentMicEngine = micEngine
            let currentSystemStream = systemStream
            micEngine = nil
            systemStream = nil
            systemOutputBridge = nil
            return (currentMicEngine, currentSystemStream)
        }

        if let engine = resources.0 {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        if let stream = resources.1 {
            try? await stream.stopCapture()
        }

        streamPair.continuation.finish()
    }

    func audioStream() -> AsyncStream<AudioChunk> {
        stateQueue.sync { streamPair.stream }
    }

    func captureStatusSummary() -> (mode: LocalAudioCaptureMode, warning: String?) {
        stateQueue.sync {
            (mode: captureMode, warning: captureWarning)
        }
    }

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AppError.providerUnavailable(reason: "Microphone input device is unavailable or disabled in macOS Sound settings.")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.handlePCMBuffer(buffer, source: .microphone)
            }
        }

        engine.prepare()
        try engine.start()

        stateQueue.sync {
            micEngine = engine
        }
        NSLog(
            "Microphone capture started: sampleRate=%.2f channels=%u commonFormat=%d",
            inputFormat.sampleRate,
            inputFormat.channelCount,
            inputFormat.commonFormat.rawValue
        )
    }

    private func startSystemAudioCapture() async throws {
        guard #available(macOS 13.0, *) else {
            throw AppError.providerUnavailable(reason: "System audio capture requires macOS 13+.")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw AppError.providerUnavailable(reason: systemAudioUnavailableReason(for: error))
            }
        }
        guard let display = content.displays.first else {
            throw AppError.providerUnavailable(reason: "No display found for system audio capture.")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Constants.sampleRate
        config.channelCount = Constants.channels
        config.excludesCurrentProcessAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let outputBridge = SystemAudioOutputBridge { [weak self] sampleBuffer in
            self?.handleSystemSampleBuffer(sampleBuffer)
        }

        try stream.addStreamOutput(outputBridge, type: .audio, sampleHandlerQueue: processingQueue)
        do {
            try await stream.startCapture()
        } catch {
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try await stream.startCapture()
            } catch {
                throw AppError.providerUnavailable(
                    reason: systemAudioUnavailableReason(for: error)
                )
            }
        }

        stateQueue.sync {
            systemStream = stream
            systemOutputBridge = outputBridge
        }
    }

    private func handleSystemSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = AudioConversion.pcmBuffer(from: sampleBuffer) else {
            return
        }

        handlePCMBuffer(pcmBuffer, source: .systemAudio)
    }

    private func handlePCMBuffer(_ pcmBuffer: AVAudioPCMBuffer, source: AudioChunk.Source) {
        guard pcmBuffer.frameLength > 0 else { return }
        guard let pcm16Data = convertToPCM16Mono16k(pcmBuffer, source: source) else {
            return
        }

        let chunksToEmit: [AudioChunk] = stateQueue.sync {
            guard isRunning, !isPaused, let start = captureStartedAt else {
                return []
            }

            switch source {
            case .microphone:
                micAccumulator.append(pcm16Data)
            case .systemAudio:
                systemAccumulator.append(pcm16Data)
            }

            var chunks: [AudioChunk] = []
            var accumulator = source == .microphone ? micAccumulator : systemAccumulator

            while accumulator.count >= Constants.chunkByteCount {
                let chunkData = accumulator.prefix(Constants.chunkByteCount)
                accumulator.removeFirst(Constants.chunkByteCount)

                let ts = Int64(Date().timeIntervalSince(start) * 1_000)
                chunks.append(
                    AudioChunk(
                        timestampMs: ts,
                        data: Data(chunkData),
                        sampleRate: Constants.sampleRate,
                        channels: Constants.channels,
                        source: source
                    )
                )
            }

            switch source {
            case .microphone:
                micAccumulator = accumulator
            case .systemAudio:
                systemAccumulator = accumulator
            }

            return chunks
        }

        if source == .microphone {
            let shouldLog = stateQueue.sync { () -> Bool in
                if didLogFirstMicChunk {
                    return false
                }
                didLogFirstMicChunk = true
                return true
            }
            if shouldLog {
                NSLog("Microphone first chunk emitted (%d bytes).", pcm16Data.count)
            }
        }

        for chunk in chunksToEmit {
            streamPair.continuation.yield(chunk)
        }
    }

    private func convertToPCM16Mono16k(_ inputBuffer: AVAudioPCMBuffer, source: AudioChunk.Source) -> Data? {
        let inputFormat = inputBuffer.format
        let signature = formatSignature(inputFormat)

        let converter: AVAudioConverter? = {
            switch source {
            case .microphone:
                if micConverter == nil || micConverterInputSignature != signature {
                    micConverter = AVAudioConverter(from: inputFormat, to: AudioConversion.targetFormat)
                    micConverterInputSignature = signature
                }
                return micConverter
            case .systemAudio:
                if systemConverter == nil || systemConverterInputSignature != signature {
                    systemConverter = AVAudioConverter(from: inputFormat, to: AudioConversion.targetFormat)
                    systemConverterInputSignature = signature
                }
                return systemConverter
            }
        }()

        guard let converter else { return nil }

        let ratio = AudioConversion.targetSampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioConversion.targetFormat, frameCapacity: outputFrames) else {
            return nil
        }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard error == nil else { return nil }
        guard status == .haveData || status == .endOfStream else { return nil }
        guard let channel = outputBuffer.int16ChannelData?[0] else { return nil }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel, count: byteCount)
    }

    private func formatSignature(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved ? 1 : 0)"
    }

    private func ensureMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }

            guard granted else {
                throw AppError.providerUnavailable(reason: "Microphone permission was not granted.")
            }
        case .denied, .restricted:
            throw AppError.providerUnavailable(reason: "Microphone permission denied. Enable it in macOS Settings > Privacy & Security.")
        @unknown default:
            throw AppError.providerUnavailable(reason: "Unknown microphone authorization state.")
        }
    }

    private func warningMessage(for error: Error) -> String {
        if case let AppError.providerUnavailable(reason) = error {
            return reason
        }
        return error.localizedDescription
    }

    private func systemAudioUnavailableReason(for error: Error) -> String {
        let description = error.localizedDescription
        let lowercased = description.lowercased()
        let appearsPermissionRelated = lowercased.contains("permission")
            || lowercased.contains("not authorized")
            || lowercased.contains("not permitted")
            || lowercased.contains("denied")
            || lowercased.contains("declined")

        if appearsPermissionRelated {
            return screenCapturePermissionGuidanceMessage()
        }

        return "Systeemaudio kon niet starten (\(description)). De opname gaat verder met microfoon-only."
    }

    private func screenCapturePermissionGuidanceMessage() -> String {
        "Systeemaudio is niet beschikbaar door Screen Recording permissie. Controleer macOS Settings > Privacy & Security > Screen Recording. Na inschakelen: herstart MinuteWave eenmalig, of kies 'Microfoon alleen'."
    }
}
