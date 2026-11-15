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
    static let stopWords: Set<String> = ["stop", "cancel", "wait", "enough", "halt"]
    static let stopPhrases: [[String]] = [["hold", "on"], ["hang", "on"]]
    /// Words that make the next one not a command ("don't stop").
    static let negationWords: Set<String> = ["don't", "dont", "never", "not", "won't", "can't"]
    /// Words that make "stop" a noun ("the bus stop").
    static let nounMarkerWords: Set<String> = ["the", "a", "bus", "next", "last", "full", "pit", "truck", "your", "my"]

    /// Whether the newest words of a (partial) transcript are a stop command.
    static func isStopCommand(_ transcript: String, newestWordCount: Int = 4) -> Bool {
        let allWords = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let newestWords = Array(allWords.suffix(newestWordCount))
        for (position, word) in newestWords.enumerated() {
            let isStopWord = stopWords.contains(word)
            let isStopPhrase = stopPhrases.contains { phrase in
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

    /// Off unless the user switched it on.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    /// Called (on the main actor) when a stop word is heard.
    var onStopHeard: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isListening = false

    /// Starts listening, if it's switched on and speech recognition can run
    /// on this Mac. Quietly does nothing otherwise.
    func startListening() {
        guard Self.isEnabled, !isListening,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let speechRecognizer = SFSpeechRecognizer(),
              speechRecognizer.isAvailable,
              speechRecognizer.supportsOnDeviceRecognition else { return }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        // Echo cancellation: what elfhub says out loud isn't heard as the user.
        try? inputNode.setVoiceProcessingEnabled(true)
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

        self.audioEngine = audioEngine
        self.recognitionRequest = recognitionRequest
        isListening = true
        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest,
            resultHandler: Self.makeResultHandler { [weak self] transcript, isFinished in
                guard let self, self.isListening else { return }
                if SpokenStopCommand.isStopCommand(transcript) {
                    self.stopListening()
                    self.onStopHeard?()
                    return
                }
                // Recognition sessions end on their own after a while; a
                // run can be longer, so listening starts again.
                if isFinished {
                    self.stopListening()
                    self.startListening()
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
        onTranscript: @escaping @MainActor (_ transcript: String, _ isFinished: Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { recognitionResult, recognitionError in
            let transcript = recognitionResult?.bestTranscription.formattedString ?? ""
            let isFinished = (recognitionResult?.isFinal ?? false) || recognitionError != nil
            Task { @MainActor in onTranscript(transcript, isFinished) }
        }
    }

    /// Stops listening and lets go of the microphone.
    func stopListening() {
        guard isListening else { return }
        isListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
}
