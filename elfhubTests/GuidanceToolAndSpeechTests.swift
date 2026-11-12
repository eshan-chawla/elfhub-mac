//
//  GuidanceToolAndSpeechTests.swift
//  elfhubTests
//
//  Native guidance tool-call decoding, the tool/tag merge, streaming sentence
//  segmentation for speech, and the speech / voice choices and requests.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

struct GuidanceToolAndSpeechTests {

    private func toolCall(_ toolName: String, _ argumentsJSON: String, identifier: String = "c") -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: identifier, toolName: toolName, argumentsJSON: argumentsJSON)
    }

    // MARK: - Tool call decoding

    @Test func decodesPointAnnotationAndActionToolCalls() {
        let result = ToolCallGuidanceDecoder.decode(responseText: " here it is ", toolCalls: [
            toolCall("annotate", #"{"shape":"highlight","x":1,"y":2,"x2":30,"y2":40,"label":"total"}"#),
            toolCall("point_at", #"{"x":100,"y":200,"label":"save button","screen":2}"#),
            toolCall("perform_screen_action", #"{"action":"click","x":100,"y":200,"label":"save"}"#),
        ])
        #expect(result.spokenText == "here it is")
        #expect(result.pointCommand?.point == CGPoint(x: 100, y: 200))
        #expect(result.pointCommand?.screenNumber == 2)
        #expect(result.annotations == [ScreenAnnotation(
            shape: .highlight(firstCorner: CGPoint(x: 1, y: 2), oppositeCorner: CGPoint(x: 30, y: 40)),
            label: "total",
            screenNumber: nil
        )])
        #expect(result.actions == [.click(screenshotPixel: CGPoint(x: 100, y: 200), label: "save", screenNumber: nil)])
    }

    @Test func skipsMalformedToolCallsAndUnknownTools() {
        let result = ToolCallGuidanceDecoder.decode(responseText: "ok", toolCalls: [
            toolCall("annotate", #"{"shape":"circle","x":1,"y":2}"#),        // circle without radius
            toolCall("annotate", #"{"shape":"highlight","x":1,"y":2}"#),     // highlight without corner 2
            toolCall("perform_screen_action", #"{"action":"scroll","x":1,"y":2}"#), // no direction
            toolCall("run_shell", #"{"command":"rm -rf /"}"#),
            toolCall("point_at", "not json"),
        ])
        #expect(result.commands.isEmpty)
    }

    @Test func acceptsNumbersSentAsStrings() {
        let result = ToolCallGuidanceDecoder.decode(responseText: "", toolCalls: [
            toolCall("annotate", #"{"shape":"circle","x":"10","y":"20","radius":"5"}"#),
        ])
        #expect(result.annotations.first?.shape == .circle(center: CGPoint(x: 10, y: 20), radius: 5))
    }

    @Test func onlyOnePointerAndCappedActions() {
        let manyActions = (0..<8).map { toolCall("perform_screen_action", #"{"action":"key","keys":"tab"}"#, identifier: "a\($0)") }
        let result = ToolCallGuidanceDecoder.decode(responseText: "", toolCalls: [
            toolCall("point_at", #"{"x":1,"y":1,"label":"first"}"#),
            toolCall("point_at", #"{"x":2,"y":2,"label":"second"}"#),
        ] + manyActions)
        #expect(result.pointCommand?.label == "first")
        #expect(result.actions.count == ScreenActionParser.maximumActionsPerResponse)
    }

    @Test func screenActionToolIsOnlyOfferedInActionMode() {
        let withoutActions = GuidanceToolDefinitions.toolDefinitions(includingScreenActions: false).map(\.name)
        let withActions = GuidanceToolDefinitions.toolDefinitions(includingScreenActions: true).map(\.name)
        #expect(!withoutActions.contains("perform_screen_action"))
        #expect(withActions.contains("perform_screen_action"))
    }

    // Only the screen under the cursor is captured, so the model is never
    // told about other screens or asked for a screen number.
    @MainActor @Test func promptNoLongerMentionsOtherScreens() {
        for guidanceEncoding in [CompanionPromptBuilder.GuidanceEncoding.nativeTools, .textTags] {
            let systemPrompt = CompanionPromptBuilder.systemPrompt(
                coordinateConvention: .imagePixels,
                guidanceEncoding: guidanceEncoding,
                includesScreenActions: true
            )
            #expect(!systemPrompt.contains("screenN"))
            #expect(!systemPrompt.contains("primary focus"))
            #expect(!systemPrompt.contains("screen(s)"))
        }
    }

    @MainActor @Test func guidanceToolsHaveNoScreenParameter() {
        for toolDefinition in GuidanceToolDefinitions.toolDefinitions(includingScreenActions: true) {
            let toolProperties = toolDefinition.inputSchema["properties"] as? [String: Any]
            #expect(toolProperties?["screen"] == nil)
        }
    }

    @Test func toolModeStillStripsStrayTagsAndPrefersToolPointer() {
        let decodeResult = CompanionTurnPipeline.decodeGuidance(
            replyText: "look here [POINT:5,5:tag pointer]",
            toolCalls: [toolCall("point_at", #"{"x":9,"y":9,"label":"tool pointer"}"#)],
            usesNativeGuidanceTools: true
        )
        #expect(decodeResult.spokenText == "look here")
        #expect(decodeResult.pointCommand?.label == "tool pointer")
        #expect(decodeResult.commands.filter { if case .point = $0 { return true } else { return false } }.count == 1)
    }

    // MARK: - Sentence segmentation

    @Test func emitsSentencesAsTheyComplete() {
        var segmenter = SpokenSentenceSegmenter()
        #expect(segmenter.append("the save button is up in ").isEmpty)
        #expect(segmenter.append("the toolbar on the right. click it ").map(\.text) == ["the save button is up in the toolbar on the right."])
        #expect(segmenter.append("and you're done.").isEmpty)
        #expect(segmenter.finish().map(\.text) == ["click it and you're done."])
    }

    @Test func joinsVeryShortSentences() {
        var segmenter = SpokenSentenceSegmenter()
        let sentences = segmenter.append("sure. okay. here's the longer explanation you wanted. ").map(\.text)
        #expect(sentences == ["sure. okay. here's the longer explanation you wanted."])
    }

    @Test func neverSpeaksGuidanceTagsEvenWhenSplitAcrossChunks() {
        var segmenter = SpokenSentenceSegmenter()
        var spoken = segmenter.append("this is the button you need to press. [POI").map(\.text)
        spoken += segmenter.append("NT:100,200:save]").map(\.text)
        spoken += segmenter.finish().map(\.text)
        #expect(spoken == ["this is the button you need to press."])
        #expect(!spoken.joined().contains("POINT"))
    }

    @Test func speakableTextKeepsOrdinaryBrackets() {
        #expect(SpokenSentenceSegmenter.speakableText(fromPartialResponse: "an array [sic] here") == "an array [sic] here")
        #expect(SpokenSentenceSegmenter.speakableText(fromPartialResponse: "mark it [HIGHLIGHT:1,2,3") == "mark it ")
    }

    @Test func decimalsDoNotEndSentences() {
        var segmenter = SpokenSentenceSegmenter()
        #expect(segmenter.append("the total went from 3.5 to 4.25 percent this quarter. ").map(\.text) == ["the total went from 3.5 to 4.25 percent this quarter."])
    }

    // MARK: - Speech choices

    @Test func savedChoicesFromEarlierBuildsStillLoad() {
        // Raw values persisted by earlier builds map onto the current options.
        #expect(SpeechOutputMode(rawValue: "elevenLabsOwnKey") == .elevenLabs)
        #expect(SpeechOutputMode(rawValue: "system") == .system)
        #expect(TranscriptionProviderChoice(rawValue: "assemblyAIOwnKey") == .assemblyAI)
        #expect(TranscriptionProviderChoice.defaultChoice == .appleOnDevice)
    }

    @Test func elevenLabsRequestCarriesKeyAndVoice() throws {
        let request = try ElevenLabsTTSClient.makeRequest(apiKey: "secret", voiceIdentifier: "voice123")
        #expect(request.url?.absoluteString.contains("/v1/text-to-speech/voice123") == true)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "secret")
        #expect(request.httpMethod == "POST")
    }

    @Test func openAICompatibleSpeechRequestTargetsAudioSpeech() throws {
        let cloudRequest = try OpenAICompatibleSpeechClient.makeRequest(
            baseURL: "https://api.openai.com/v1/", apiKey: "secret", modelName: "tts-model", voiceName: "alloy", text: "hi"
        )
        #expect(cloudRequest.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(cloudRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let requestBody = try JSONSerialization.jsonObject(with: cloudRequest.httpBody ?? Data()) as? [String: Any]
        #expect(requestBody?["voice"] as? String == "alloy")
        #expect(requestBody?["input"] as? String == "hi")

        let localRequest = try OpenAICompatibleSpeechClient.makeRequest(
            baseURL: "http://localhost:8880/v1", apiKey: nil, modelName: "kokoro", voiceName: "af_heart", text: "hi"
        )
        #expect(localRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keyRequirementsByProviderKind() {
        let localOllama = ProviderConfiguration.localServer(.ollama)
        let remoteCompatible = ProviderConfiguration(kind: .openAICompatible, displayName: "r", baseURL: "https://openrouter.ai/api/v1", model: "m", supportsVision: true)
        #expect(!localOllama.requiresAPIKey)
        #expect(remoteCompatible.requiresAPIKey)
        #expect(ProviderConfiguration.directAnthropic().requiresAPIKey)
        #expect(!localOllama.supportsToolCalling)
        #expect(ProviderConfiguration.directAnthropic().supportsToolCalling)
    }
}
