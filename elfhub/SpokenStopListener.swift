//
//  SpokenStopListener.swift
//  elfhub
//
//  "Stop" said out loud while elfhub acts on the screen — no push-to-talk.
//  Off by default (Settings › Modes, "Listen for “stop” while acting"),
//  because it keeps the microphone on during a run. When on, the
//  microphone runs only while a run is on the screen; speech is recognized
//  on this Mac (on-device recognition, never sent anywhere), and the
//  microphone's echo cancellation keeps elfhub's own voice out. Hearing a
//  stop word does what Esc does.
//
//  SpokenStopCommand (pure, unit-tested) decides what counts: stop,
//  cancel, wait, hold on, enough — as words on their own, among the newest
//  few words, not negated ("don't stop") and not a noun ("the bus stop").
//

import AVFoundation
import Foundation
import Speech
import os

enum SpokenStopCommand {
    static let stopWords: Set<String> = ["stop", "cancel", "wait", "halt"]
    /// While elfhub is talking, only "stop" counts: its own narration ("i'll
    /// wait for it to load", "pressing cancel") can leak past echo
    /// cancellation, since its voice doesn't play through this microphone's
    /// audio engine.
    static let stopWordsWhileElfhubIsSpeaking: Set<String> = ["stop"]
    static let stopPhrases: [[String]] = [["hold", "on"], ["hang", "on"]]
    /// Words that make the next one not a command ("don't stop").
    static let negationWords: Set<String> = ["don't", "dont", "never", "not", "won't", "can't"]
    /// Words that make "stop" a noun ("the bus stop").
    static let nounMarkerWords: Set<String> = ["the", "a", "bus", "next", "last", "full", "pit", "truck", "your", "my"]

    /// Whether the newest words of a (partial) transcript are a stop command.
    static func isStopCommand(_ transcript: String, newestWordCount: Int = 4, whileElfhubIsSpeaking: Bool = false) -> Bool {
        let allWords = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let newestWords = Array(allWords.suffix(newestWordCount))
        for (position, word) in newestWords.enumerated() {
            let isStopWord = (whileElfhubIsSpeaking ? stopWordsWhileElfhubIsSpeaking : stopWords).contains(word)
            let isStopPhrase = !whileElfhubIsSpeaking && stopPhrases.contains { phrase in
                position + phrase.count <= newestWords.count && Array(newestWords[position..<(position + phrase.count)]) == phrase
            }
            guard isStopWord || isStopPhrase else { continue }
            // The word just before it, even when that's older than the newest words.
            let indexInAllWords = allWords.count - newestWords.count + position
            let wordBefore = indexInAllWords > 0 ? allWords[indexInAllWords - 1] : nil
            if let wordBefore, negationWords.contains(wordBefore) || nounMarkerWords.contains(wordBefore) { continue }
            return true
        }
        return false
    }
}

/// Listens for a stop word while a run is on the screen.
@MainActor
final class SpokenStopListener {
    static let isEnabledKey = "listensForSpokenStopWhileActing"
    /// A run is at most a few minutes; recognition sessions end on their own
    /// after about a minute, so a few restarts cover it.
    static let maximumRestartsPerRun = 3

    /// Off unless the user switched it on.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    /// Whether on-device recognition can run: allowed, and supported here.
    static var canRecognizeOnThisMac: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let speechRecognizer = SFSpeechRecognizer() else { return false }
        return speechRecognizer.supportsOnDeviceRecognition
    }

    /// Asks for Speech Recognition when it hasn't been asked yet (people who
    /// use another service for push-to-talk were never asked). The answer
    /// arrives on a background queue, so this is outside the main actor.
    nonisolated static func requestSpeechRecognitionPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return SFSpeechRecognizer.authorizationStatus() }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }
    }

    /// Why listening for "stop" can't work here, in words, or nil when it can.
    static var unavailableReason: String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return "Speech Recognition is off for elfhub. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        case .notDetermined:
            return "elfhub needs Speech Recognition for this."
        default:
            break
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "elfhub needs the microphone for this. Turn it on in System Settings › Privacy & Security › Microphone."
        }
        guard canRecognizeOnThisMac else {
            return "On-device speech recognition isn't available on this Mac for your language, so this can't listen."
        }
        return nil
    }

    /// Called (on the main actor) when a stop word is heard.
    var onStopHeard: (() -> Void)?
    /// Whether elfhub is talking right now (then only "stop" counts).
    var isElfhubSpeaking: () -> Bool = { false }

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var isListening = false
    /// Which listening session is current; results from older ones are ignored.
    private var sessionNumber = 0
    private var restartsThisRun = 0

    /// Starts listening for a new run (restarts counted from zero).
    func startListeningForRun() {
        restartsThisRun = 0
        startListening()
    }

    /// Starts listening, if it's switched on and speech recognition can run
    /// on this Mac. Quietly does nothing otherwise.
    private func startListening() {
        guard Self.isEnabled, !isListening,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let speechRecognizer = SFSpeechRecognizer(),
              speechRecognizer.isAvailable,
              speechRecognizer.supportsOnDeviceRecognition else { return }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        // Echo cancellation for what the speakers play, without turning the
        // rest of the Mac's audio down for the whole run.
        try? inputNode.setVoiceProcessingEnabled(true)
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.contextualStrings = ["stop", "cancel", "wait", "hold on"]

        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.makeTapBlock(appendingTo: recognitionRequest))
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            companionLogger.error("Couldn't start listening for stop: \(error.localizedDescription, privacy: .public)")
            return
        }

        sessionNumber += 1
        let thisSessionNumber = sessionNumber
        self.audioEngine = audioEngine
        self.recognitionRequest = recognitionRequest
        isListening = true
        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest,
            resultHandler: Self.makeResultHandler { [weak self] transcript, isFinal, hasFailed in
                // A late result from a session that already ended is ignored.
                guard let self, self.isListening, thisSessionNumber == self.sessionNumber else { return }
                if SpokenStopCommand.isStopCommand(transcript, whileElfhubIsSpeaking: self.isElfhubSpeaking()) {
                    self.stopListening()
                    self.onStopHeard?()
                    return
                }
                if hasFailed {
                    // Recognition can't run (models missing, dictation off):
                    // no retry loop — listening ends for this run.
                    self.stopListening()
                    return
                }
                // A session that ended normally starts again, a few times a
                // run at most, since sessions end on their own.
                if isFinal {
                    self.stopListening()
                    if self.restartsThisRun < Self.maximumRestartsPerRun {
                        self.restartsThisRun += 1
                        self.startListening()
                    }
                }
            }
        )
    }

    /// The microphone tap runs on an audio thread, so it's built outside
    /// the main actor.
    nonisolated private static func makeTapBlock(appendingTo recognitionRequest: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { audioBuffer, _ in recognitionRequest.append(audioBuffer) }
    }

    /// Recognition results arrive on a background queue; each is handed to
    /// the main actor.
    nonisolated private static func makeResultHandler(
        onResult: @escaping @MainActor (_ transcript: String, _ isFinal: Bool, _ hasFailed: Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { recognitionResult, recognitionError in
            let transcript = recognitionResult?.bestTranscription.formattedString ?? ""
            let isFinal = recognitionResult?.isFinal ?? false
            let hasFailed = recognitionError != nil && !isFinal
            Task { @MainActor in onResult(transcript, isFinal, hasFailed) }
        }
    }

    /// Stops listening and lets go of the microphone.
    func stopListening() {
        guard isListening else { return }
        isListening = false
        sessionNumber += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
}
