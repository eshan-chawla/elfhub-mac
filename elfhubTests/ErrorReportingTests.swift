//
//  ErrorReportingTests.swift
//  elfhubTests
//
//  Error reports: which errors are offered (and only once), that keys,
//  tokens, emails, names, addresses and personal numbers never reach the
//  issue while what's useful for fixing it stays, elfhub's own stack frames,
//  the issue's content, and the GitHub link (shortened to fit, saying so).
//

import Foundation
import Testing
@testable import elfhub

struct ErrorReportingTests {

    private let supportDiagnostics = SupportDiagnostics(appVersion: "0.0.2", appBuildNumber: "14", macOSVersion: "26.1.0")

    // MARK: - Which errors are offered

    /// The 400 from the real app (a failed screen step's screenshot marked
    /// as an error): a request elfhub built wrong — exactly what to report.
    private let invalidRequestError = LanguageModelProviderError.httpError(
        statusCode: 400,
        body: #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.16.content.3.tool_result: all content must be type `text` if `is_error` is true"},"request_id":"req_011Ch97VbtYa6aopJvqL9K7L"}"#
    )

    @Test func requestsElfhubGotWrongAndUnexpectedErrorsAreOffered() {
        #expect(ErrorReportEligibility.shouldOfferReport(for: invalidRequestError))
        #expect(ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.invalidResponse))
        #expect(ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.streamFailed("unexpected event type")))
        #expect(ErrorReportEligibility.shouldOfferReport(for: NSError(domain: "SomethingElse", code: 7)))
    }

    @Test func errorsTheUserOrTheProviderCanFixAreNotOffered() {
        #expect(!ErrorReportEligibility.shouldOfferReport(for: CancellationError()))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: URLError(.notConnectedToInternet)))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: URLError(.timedOut)))
        for statusCode in [401, 402, 403, 404, 408, 429, 500, 502, 503, 529] {
            #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.httpError(statusCode: statusCode, body: "")),
                    "HTTP \(statusCode) isn't elfhub's bug")
        }
        #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.httpError(statusCode: 400, body: "API key not valid. Please pass a valid API key.")),
                "some providers answer a wrong key with 400")
        #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.httpError(statusCode: 400, body: "Your credit balance is too low")))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.missingConfiguration("no key")))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.streamFailed("Overloaded")))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: ChatGPTPlanUsageError.usageLimitReached))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: ClaudeAPIError.refused))
    }

    @Test func aModelDecliningOrATaskRunningOutOfRoomIsNotOffered() {
        #expect(!ErrorReportEligibility.shouldOfferReport(for: LanguageModelProviderError.declined(providerName: "Gemini")))
        #expect(!ErrorReportEligibility.shouldOfferReport(for: ElfAgentLoopError.budgetExceeded))
    }

    @Test func anEmptyReplyStoppedByTheModelsFilterIsAnError() {
        #expect(throws: LanguageModelProviderError.self) {
            try LanguageModelProviderError.throwIfDeclinedWithoutAnswer(stopReason: .refusal, text: "  ", toolCalls: [], providerName: "Gemini")
        }
        // Text that arrived before the filter is kept as the reply.
        #expect(throws: Never.self) {
            try LanguageModelProviderError.throwIfDeclinedWithoutAnswer(stopReason: .refusal, text: "Here's part", toolCalls: [], providerName: "Gemini")
        }
        #expect(throws: Never.self) {
            try LanguageModelProviderError.throwIfDeclinedWithoutAnswer(stopReason: .endOfTurn, text: "", toolCalls: [], providerName: "Gemini")
        }
    }

    @Test func theSameErrorIsOfferedOncePerLaunch() {
        let firstOccurrence = LanguageModelProviderError.httpError(statusCode: 400, body: "messages.16.content.3: bad request_id req_111")
        let secondOccurrence = LanguageModelProviderError.httpError(statusCode: 400, body: "messages.22.content.1: bad request_id req_222")
        #expect(ErrorReportEligibility.signature(for: firstOccurrence) == ErrorReportEligibility.signature(for: secondOccurrence),
                "only numbers differ")
        #expect(ErrorReportEligibility.signature(for: firstOccurrence) != ErrorReportEligibility.signature(for: LanguageModelProviderError.invalidResponse))

        let signature = ErrorReportEligibility.signature(for: invalidRequestError)
        #expect(ErrorReportPresenter.shouldOffer(error: invalidRequestError, offersReports: true, alreadyOfferedSignatures: [], isShowingAReport: false))
        #expect(!ErrorReportPresenter.shouldOffer(error: invalidRequestError, offersReports: true, alreadyOfferedSignatures: [signature], isShowingAReport: false))
        #expect(!ErrorReportPresenter.shouldOffer(error: invalidRequestError, offersReports: true, alreadyOfferedSignatures: [], isShowingAReport: true),
                "one report window at a time")
        #expect(!ErrorReportPresenter.shouldOffer(error: invalidRequestError, offersReports: false, alreadyOfferedSignatures: [], isShowingAReport: false),
                "the setting switches it off")
    }

    @Test func offeringIsOnUntilSwitchedOff() throws {
        let userDefaultsSuiteName = "ErrorReportingTests-\(UUID().uuidString)"
        let isolatedUserDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        defer { isolatedUserDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        #expect(ErrorReportSettings.offersReports(userDefaults: isolatedUserDefaults))
        isolatedUserDefaults.set(false, forKey: ErrorReportSettings.offersReportsKey)
        #expect(!ErrorReportSettings.offersReports(userDefaults: isolatedUserDefaults))
    }

    // MARK: - Redaction

    @Test func theUsersOwnStoredKeysAreTakenOutWhateverTheirShape() {
        let unusualKey = "my-local-server-password-77"
        let redactedText = ErrorReportRedactor.redacted("connecting with \(unusualKey) failed", knownSecrets: [unusualKey, "short"])
        #expect(!redactedText.contains(unusualKey))
        #expect(redactedText == "connecting with [REDACTED KEY] failed")
        #expect(ErrorReportRedactor.redacted("short story", knownSecrets: ["short"]) == "short story", "too short to be a key")
    }

    @Test func secretsStoredAsJSONGiveUpEveryLongValue() {
        let storedSignIn = #"{"accessToken":"at-0123456789abcdef","refreshToken":"rt-abcdefghijklmnop","nested":{"idToken":"idt-zyxwvutsrqponm"},"expiry":12}"#
        let secretValues = ErrorReportRedactor.secretValues(fromStoredSecret: storedSignIn)
        #expect(secretValues.contains("at-0123456789abcdef"))
        #expect(secretValues.contains("rt-abcdefghijklmnop"))
        #expect(secretValues.contains("idt-zyxwvutsrqponm"))
        #expect(ErrorReportRedactor.secretValues(fromStoredSecret: "sk-plain-key-123456") == ["sk-plain-key-123456"])
    }

    @Test func keysAndTokensAreTakenOutByTheirShape() {
        let samples = [
            "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx",
            "sk-proj-AbCdEfGhIjKlMnOpQrStUvWx12",
            "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz0123456",
            "xai-AbCdEfGhIjKlMnOpQrStUvWx",
            "gsk_AbCdEfGhIjKlMnOpQrStUvWx",
            "ghp_AbCdEfGhIjKlMnOpQrStUvWx1234",
            "sk_0123456789abcdef0123456789abcdef0123abcd",
            "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.c2lnbmF0dXJlMTIzNDU",
        ]
        for sample in samples {
            let redactedText = ErrorReportRedactor.redacted("failed with \(sample) here")
            #expect(!redactedText.contains(sample), "\(sample.prefix(8))… was left in")
            #expect(redactedText.hasPrefix("failed with [REDACTED"))
        }
    }

    @Test func headersAndFieldsKeepTheirNameButLoseTheirValue() {
        #expect(ErrorReportRedactor.redacted("Authorization: Bearer abc.def-ghi_jkl") == "Authorization: Bearer [REDACTED]")
        #expect(ErrorReportRedactor.redacted("xi-api-key: 0f9e8d7c6b5a") == "xi-api-key: [REDACTED]")
        #expect(ErrorReportRedactor.redacted(#"{"api_key": "hunter2hunter2"}"#) == #"{"api_key": "[REDACTED]"}"#)
        #expect(ErrorReportRedactor.redacted("GET /v1beta/models?key=plainvalue&alt=sse") == "GET /v1beta/models?key=[REDACTED]&alt=sse")
        #expect(ErrorReportRedactor.redacted("password=letmein123") == "password=[REDACTED]")
    }

    @Test func peopleAndPlacesAreTakenOut() {
        let redactedText = ErrorReportRedactor.redacted(
            "Eshan Chawla (eshan.chawla@example.com) at /Users/eshanchawla/Library/elfhub on Eshans-MacBook-Pro from 192.168.1.20, call +1 416-555-0199",
            personalStrings: ["eshanchawla", "Eshan Chawla", "Eshan", "Chawla", "Eshans-MacBook-Pro"]
        )
        #expect(!redactedText.localizedCaseInsensitiveContains("eshan"))
        #expect(!redactedText.localizedCaseInsensitiveContains("chawla"))
        #expect(!redactedText.contains("@example.com"))
        #expect(redactedText.contains("/Users/[user]/Library/elfhub"))
        #expect(!redactedText.contains("192.168.1.20"))
        #expect(!redactedText.contains("555-0199"))
        // A name is only taken out as a whole word.
        #expect(ErrorReportRedactor.redacted("Annotations", personalStrings: ["Ann"]) == "Annotations")
    }

    @Test func personalNumbersAreTakenOutAsInScreenshots() {
        let redactedText = ErrorReportRedactor.redacted("card 4111 1111 1111 1111 and SSN 123-45-6789")
        #expect(!redactedText.contains("4111 1111 1111 1111"))
        #expect(!redactedText.contains("123-45-6789"))
        #expect(redactedText.contains("[REDACTED NUMBER]"))
    }

    @Test func whatHelpsFixTheBugStays() {
        // The real 400 has nothing personal in it: it comes through whole.
        let realErrorText = invalidRequestError.localizedDescription
        #expect(ErrorReportRedactor.redacted(realErrorText) == realErrorText)
        let usefulText = """
        elfhub 0.0.2 (14) · macOS 26.1.0; HTTP 400; max_tokens 8192; 12:14:03.120
        $s6elfhub16ComputerUseSessionC11finishRoundAA0bC10StepResultVyYaF + 412
        file ComputerUseSession.swift:325; request_id req_011Ch97VbtYa6aopJvqL9K7L
        """
        #expect(ErrorReportRedactor.redacted(usefulText) == usefulText)
    }

    @Test func longOpaqueBlobsAreTakenOut() {
        let base64Blob = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        #expect(ErrorReportRedactor.redacted("image: \(base64Blob)") == "image: [REDACTED TOKEN]")
    }

    // MARK: - Stack

    @Test func onlyElfhubsOwnFramesAreKeptWithoutTheReportingCode() {
        let callStackSymbols = [
            "0   elfhub.debug.dylib                  0x0000000104f2c1a8 $s6elfhub20ErrorReportPresenterC05offerB0yyF + 120",
            "1   elfhub.debug.dylib                  0x0000000104f2c2b8 $s6elfhub16CompanionManagerC6handleyyF + 640",
            "2   libswift_Concurrency.dylib          0x000000019a1b2c3d swift_task_switch + 20",
            "3   elfhub                              0x0000000104f2c3c8 main + 12",
        ]
        let frames = ErrorReportStackTrace.relevantFrames(
            fromCallStackSymbols: callStackSymbols,
            demangle: { mangledSymbol in
                switch mangledSymbol {
                case "$s6elfhub20ErrorReportPresenterC05offerB0yyF": return "elfhub.ErrorReportPresenter.offer() -> ()"
                case "$s6elfhub16CompanionManagerC6handleyyF": return "elfhub.CompanionManager.handle() -> ()"
                default: return nil
                }
            }
        )
        #expect(frames == ["elfhub.CompanionManager.handle() -> () + 640", "main + 12"])
    }

    @Test func swiftSymbolsAreDemangled() {
        #expect(SwiftSymbolDemangler.demangle("$sSi") == "Swift.Int")
        #expect(SwiftSymbolDemangler.demangle("not_a_swift_symbol") == nil)
    }

    // MARK: - The issue

    private func context(errorDescription: String, recentLogLines: [String] = []) -> ErrorReportContext {
        ErrorReportContext(
            errorDescription: errorDescription,
            errorTypeName: "LanguageModelProviderError.httpError",
            origin: .typedChat,
            modelDescription: "anthropic · claude-opus-5-5",
            screenActionsDescription: "on (Ask first)",
            stackFrames: ["elfhub.CompanionManager.handle() -> () + 640"],
            recentLogLines: recentLogLines,
            supportDiagnostics: supportDiagnostics
        )
    }

    @Test func theIssueHasTheErrorWhereItHappenedTheStackLogAndVersions() {
        let report = ErrorReportComposer.compose(
            context(errorDescription: invalidRequestError.localizedDescription, recentLogLines: ["12:14:03.120 [companion] Computer use step 1: 2 calls"])
        )
        #expect(report.title.hasPrefix("Error: Model API error (400): messages.16.content.3.tool_result: all content must be"),
                "the API's message, not its JSON")
        #expect(report.title.count <= ErrorReportComposer.maximumTitleLength)
        #expect(report.body.contains("### What happened"))
        #expect(report.body.contains("all content must be type `text` if `is_error` is true"))
        #expect(report.body.contains("Error type: `LanguageModelProviderError.httpError`"))
        #expect(report.body.contains("During: a typed chat message"))
        #expect(report.body.contains("Model: anthropic · claude-opus-5-5"))
        #expect(report.body.contains("Screen actions: on (Ask first)"))
        #expect(report.body.contains("elfhub.CompanionManager.handle() -> () + 640"))
        #expect(report.body.contains("Computer use step 1: 2 calls"))
        #expect(report.body.contains("elfhub 0.0.2 (14) · macOS 26.1.0"))
    }

    @Test func nothingSecretOrPersonalReachesTheIssue() {
        let report = ErrorReportComposer.compose(
            context(
                errorDescription: "Model API error (400): bad key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx for jane@example.com",
                recentLogLines: ["12:00:00.000 [companion] loading /Users/janedoe/Library/thing with token=abc123secret"]
            ),
            knownSecrets: ["custom-secret-value-42"],
            personalStrings: ["janedoe"]
        )
        let wholeIssue = report.title + "\n" + report.body
        #expect(!wholeIssue.contains("sk-ant-api03"))
        #expect(!wholeIssue.contains("jane@example.com"))
        #expect(!wholeIssue.contains("janedoe"))
        #expect(!wholeIssue.contains("abc123secret"))
        #expect(wholeIssue.contains("[REDACTED KEY]"))
    }

    @Test func titlesReadLikeASentence() {
        #expect(ErrorReportComposer.titleSummary(
            fromErrorDescription: #"Model API error (400): {"error":{"code":400,"message":"Invalid JSON payload","status":"INVALID_ARGUMENT"}}"#,
            errorTypeName: "x"
        ) == "Model API error (400): Invalid JSON payload")
        #expect(ErrorReportComposer.titleSummary(fromErrorDescription: "first line\nsecond line", errorTypeName: "x") == "first line")
        #expect(ErrorReportComposer.titleSummary(fromErrorDescription: "", errorTypeName: "SomeError") == "SomeError")
        #expect(ErrorReportComposer.titleSummary(fromErrorDescription: "Model API error (500): {not json", errorTypeName: "x") == "Model API error (500): {not json")
    }

    @Test func aLongTitleIsCut() {
        let report = ErrorReportComposer.compose(context(errorDescription: String(repeating: "very long error text ", count: 20)))
        #expect(report.title.count == ErrorReportComposer.maximumTitleLength)
        #expect(report.title.hasSuffix("…"))
    }

    @Test func errorTypesNameTheirCase() {
        #expect(ErrorReportComposer.errorTypeName(for: invalidRequestError) == "LanguageModelProviderError.httpError")
        #expect(ErrorReportComposer.errorTypeName(for: LanguageModelProviderError.invalidResponse) == "LanguageModelProviderError.invalidResponse")
        #expect(ErrorReportComposer.errorTypeName(for: URLError(.badURL)) == "NSURLErrorDomain -1000",
                "Foundation errors are named by domain and code")
    }

    // MARK: - The GitHub link

    private let newIssuePageURL = URL(string: "https://github.com/eshan-chawla/elfhub-mac/issues/new")!

    private func queryValue(_ queryItemName: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == queryItemName }?.value
    }

    @Test func theLinkFillsInTheEditedTitleAndBodyWithTheBugLabel() throws {
        let editedReport = ErrorReport(title: "Error: my edited title", body: "What I did: asked it to open Mail.\n\nmore")
        let (issueURL, isShortened) = try #require(ErrorReportComposer.newIssueURL(for: editedReport, newIssuePageURL: newIssuePageURL))
        #expect(!isShortened)
        #expect(issueURL.host == "github.com")
        #expect(issueURL.path == "/eshan-chawla/elfhub-mac/issues/new")
        #expect(queryValue("title", in: issueURL) == "Error: my edited title")
        #expect(queryValue("labels", in: issueURL) == "bug")
        #expect(queryValue("body", in: issueURL) == editedReport.body)
    }

    @Test func aReportTooLongForALinkIsCutFromTheEndAndSaysSo() throws {
        let logLines = (0..<400).map { "12:00:00.\($0) [companion] a log line that goes on for a while, number \($0)" }
        let report = ErrorReportComposer.compose(context(errorDescription: "Model API error (400): something", recentLogLines: logLines))
        let longReport = ErrorReport(title: report.title, body: report.body + "\n" + logLines.joined(separator: "\n"))
        let (issueURL, isShortened) = try #require(ErrorReportComposer.newIssueURL(for: longReport, newIssuePageURL: newIssuePageURL))
        #expect(isShortened)
        #expect(issueURL.absoluteString.count <= ErrorReportComposer.maximumIssueURLLength)
        let shortenedBody = try #require(queryValue("body", in: issueURL))
        #expect(shortenedBody.hasPrefix("### What happened"), "the top — the error — is kept")
        #expect(shortenedBody.contains("Model API error (400): something"))
        #expect(shortenedBody.hasSuffix(ErrorReportComposer.shortenedNote))
    }
}
