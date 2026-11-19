//
//  SpeechAnalyzerTranscriptionProvider.swift
//  elfhub
//
//  On-device transcription with Apple's SpeechAnalyzer + SpeechTranscriber
//  (macOS 26+). Fully local and private — audio never leaves the Mac — and
//  much more accurate than the older SFSpeechRecognizer, which remains the
//  fallback on earlier macOS versions (AppleSpeechTranscriptionProvider).
//
//  The first use for a language may download Apple's on-device speech model;
//  that is handled transparently before the session starts.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26, *)
final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "On-device (Apple)"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let transcriptionLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.autoupdatingCurrent)
            ?? Locale(identifier: "en-US")
        let speechTranscriber = SpeechTranscriber(
            locale: transcriptionLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Download the on-device model for this language if it isn't installed yet.
        if let assetInstallationRequest = try await AssetInventory.assetInstallationRequest(supporting: [speechTranscriber]) {
            try await assetInstallationRequest.downloadAndInstall()
        }

        guard let analyzerAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechTranscriber]) else {
            throw AppleSpeechTranscriptionProviderError(message: "on-device transcription isn't available for this language.")
        }

        let transcriptionSession = SpeechAnalyzerTranscriptionSession(
            speechTranscriber: speechTranscriber,
            analyzerAudioFormat: analyzerAudioFormat,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        try await transcriptionSession.start()
        return transcriptionSession
    }
}

@available(macOS 26, *)
private final class SpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.5

    private let speechTranscriber: SpeechTranscriber
    private let speechAnalyzer: SpeechAnalyzer
    private let analyzerAudioFormat: AVAudioFormat
    private let analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerInputSequence: AsyncStream<AnalyzerInput>
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    /// Converts microphone buffers to the analyzer's format; created from the
    /// first buffer, since the mic format is only known then.
    private var audioConverter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var finalizedTranscriptText = ""
    private var volatileTranscriptText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechTranscriber: SpeechTranscriber,
        analyzerAudioFormat: AVAudioFormat,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.speechTranscriber = speechTranscriber
        self.speechAnalyzer = SpeechAnalyzer(modules: [speechTranscriber])
        self.analyzerAudioFormat = analyzerAudioFormat
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        (analyzerInputSequence, analyzerInputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    func start() async throws {
        resultsTask = Task { [weak self] in
            await self?.consumeTranscriptionResults()
        }
        try await speechAnalyzer.start(inputSequence: analyzerInputSequence)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        let shouldAcceptAudio = stateLock.withLock { !hasRequestedFinalTranscript }
        guard shouldAcceptAudio, let convertedBuffer = convertToAnalyzerFormat(audioBuffer) else { return }
        analyzerInputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    func requestFinalTranscript() {
        let isFirstFinalRequest = stateLock.withLock {
            guard !hasRequestedFinalTranscript else { return false }
            hasRequestedFinalTranscript = true
            return true
        }
        guard isFirstFinalRequest else { return }

        analyzerInputContinuation.finish()
        Task { [speechAnalyzer] in
            // Finalizes everything heard so far; the results stream then ends,
            // which delivers the final transcript.
            try? await speechAnalyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    func cancel() {
        analyzerInputContinuation.finish()
        resultsTask?.cancel()
        Task { [speechAnalyzer] in
            await speechAnalyzer.cancelAndFinishNow()
        }
    }

    // MARK: - Results

    private func consumeTranscriptionResults() async {
        do {
            for try await transcriptionResult in speechTranscriber.results {
                let resultText = String(transcriptionResult.text.characters)
                let currentTranscriptText = stateLock.withLock {
                    if transcriptionResult.isFinal {
                        finalizedTranscriptText += resultText
                        volatileTranscriptText = ""
                    } else {
                        volatileTranscriptText = resultText
                    }
                    return finalizedTranscriptText + volatileTranscriptText
                }
                onTranscriptUpdate(currentTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            deliverFinalTranscriptIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            let hasUsableTranscript = stateLock.withLock {
                hasRequestedFinalTranscript
                    && !(finalizedTranscriptText + volatileTranscriptText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if hasUsableTranscript {
                deliverFinalTranscriptIfNeeded()
            } else {
                onError(error)
            }
        }
    }

    private func deliverFinalTranscriptIfNeeded() {
        let finalTranscriptText: String? = stateLock.withLock {
            guard !hasDeliveredFinalTranscript else { return nil }
            hasDeliveredFinalTranscript = true
            return (finalizedTranscriptText + volatileTranscriptText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let finalTranscriptText else { return }
        onFinalTranscriptReady(finalTranscriptText)
    }

    // MARK: - Audio conversion

    private func convertToAnalyzerFormat(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = inputBuffer.format
        if inputFormat == analyzerAudioFormat {
            return inputBuffer
        }

        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: analyzerAudioFormat)
        }
        guard let audioConverter else { return nil }

        let sampleRateRatio = analyzerAudioFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerAudioFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var hasProvidedInputBuffer = false
        var conversionError: NSError?
        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInputBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInputBuffer = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionStatus != .error, conversionError == nil, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}
