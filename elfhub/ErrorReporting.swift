//
//  ErrorReporting.swift
//  elfhub
//
//  Turning an error elfhub hit into a GitHub issue the user can file — the
//  pure parts, all tested:
//   - ErrorReportEligibility: which errors are worth a report (a request
//     elfhub got wrong, something unexpected) and which aren't (no network,
//     a wrong key, a rate limit, the provider being down, the user stopping
//     it), and a signature so the same error is offered once per launch.
//   - ErrorReportRedactor: takes out API keys, tokens, emails, names, home
//     folders, addresses and personal numbers before anything is shown —
//     the user's own stored keys by exact value, everything else by shape.
//   - ErrorReportStackTrace: elfhub's own frames of a call stack, demangled.
//   - ErrorReportComposer: the issue's title and body (error, where it
//     happened, the model, stack, recent log, versions), and the GitHub
//     new-issue link, shortened to fit when the report is long.
//
//  Nothing here sends anything. ErrorReportPanel.swift shows the report for
//  the user to read and edit; only their Open on GitHub opens the browser,
//  and the issue is filed only when they press Submit there.
//

import Foundation

// MARK: - Setting

nonisolated enum ErrorReportSettings {
    /// Settings › General "Offer to report problems"; on unless switched off.
    static let offersReportsKey = "offersErrorReports"

    static func offersReports(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: offersReportsKey) as? Bool ?? true
    }
}

// MARK: - Which errors are offered

nonisolated enum ErrorReportEligibility {

    /// Whether an error is worth reporting as a bug in elfhub. Errors the
    /// user (or the provider) can fix, or that come and go, aren't.
    static func shouldOfferReport(for error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return !temporaryNetworkErrorCodes.contains(urlError.code)
        }
        if let languageModelProviderError = error as? LanguageModelProviderError {
            switch languageModelProviderError {
            case let .httpError(statusCode, body):
                return shouldOfferReport(forHTTPStatusCode: statusCode, body: body)
            case .missingConfiguration, .declined:
                return false
            case .invalidResponse:
                return true
            case let .streamFailed(detail):
                let lowercasedDetail = detail.lowercased()
                return !["overloaded", "rate limit", "rate_limit", "timeout", "unavailable", "capacity"]
                    .contains(where: lowercasedDetail.contains)
            }
        }
        // The ChatGPT plan's limits and sign-in, and Claude declining, are
        // about the account or the request, not elfhub.
        if error is ChatGPTPlanUsageError || error is ChatGPTPlanSignInError || error is ClaudeAPIError {
            return false
        }
        // A background task that ran out of time or room isn't a bug.
        if error is ElfAgentLoopError {
            return false
        }
        return true
    }

    /// A 400-style answer means elfhub built a request the API refuses —
    /// that's a bug. Keys (401/403), payment (402), limits (429), timeouts,
    /// an unknown model (404, usually a typo in Settings) and the provider
    /// being down (5xx, 529) aren't.
    static func shouldOfferReport(forHTTPStatusCode statusCode: Int, body: String) -> Bool {
        switch statusCode {
        case 400, 409, 413, 415, 422:
            // Some providers answer an expired or wrong key with 400.
            let lowercasedBody = body.lowercased()
            let isAboutTheKey = ["api key", "api_key", "apikey", "authentication", "unauthorized", "credit balance", "billing", "quota"]
                .contains(where: lowercasedBody.contains)
            return !isAboutTheKey
        default:
            return false
        }
    }

    static let temporaryNetworkErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
        .callIsActive, .secureConnectionFailed, .cancelled,
    ]

    /// Errors that are "the same" for offering once per launch: same type,
    /// same case, same message once numbers are taken out (ids, counts and
    /// times differ between two occurrences of one bug).
    static func signature(for error: Error) -> String {
        let messageWithoutNumbers = error.localizedDescription
            .replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
        return ErrorReportComposer.errorTypeName(for: error) + "|" + String(messageWithoutNumbers.prefix(120))
    }
}

// MARK: - Redaction

nonisolated enum ErrorReportRedactor {

    /// What's put in place of each kind of thing taken out.
    enum Replacement {
        static let key = "[REDACTED KEY]"
        static let token = "[REDACTED TOKEN]"
        static let value = "[REDACTED]"
        static let email = "[REDACTED EMAIL]"
        static let name = "[REDACTED NAME]"
        static let address = "[REDACTED IP]"
        static let phoneNumber = "[REDACTED PHONE]"
        static let personalNumber = "[REDACTED NUMBER]"
        static let homeFolderUser = "[user]"
    }

    /// - Parameters:
    ///   - knownSecrets: the user's stored keys and tokens, taken out wherever
    ///     they appear, whatever their shape.
    ///   - personalStrings: the Mac user's name, full name, computer name.
    static func redacted(_ text: String, knownSecrets: [String] = [], personalStrings: [String] = []) -> String {
        var redactedText = text

        // 1. The user's own secrets, longest first so one inside another
        //    can't leave a piece behind.
        let usableKnownSecrets = Set(knownSecrets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= 8 }
            .sorted { $0.count > $1.count }
        for knownSecret in usableKnownSecrets {
            redactedText = redactedText.replacingOccurrences(of: knownSecret, with: Replacement.key)
        }

        // 2. Keys and tokens by their shape.
        redactedText = replacing(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, in: redactedText, with: Replacement.key)
        redactedText = replacing(#"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#, in: redactedText, with: Replacement.token)
        redactedText = replacing(providerKeyPattern, in: redactedText, with: Replacement.key)
        redactedText = replacing(#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, in: redactedText, with: "$1 " + Replacement.value)
        redactedText = replacing(secretFieldPattern, in: redactedText, with: "$1$2" + Replacement.value)

        // 3. People and places.
        redactedText = replacing(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: redactedText, with: Replacement.email)
        redactedText = replacing(#"/Users/(?!Shared\b)[^/\s"']+"#, in: redactedText, with: "/Users/" + Replacement.homeFolderUser)
        let usablePersonalStrings = Set(personalStrings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        for personalString in usablePersonalStrings {
            let escapedPersonalString = NSRegularExpression.escapedPattern(for: personalString)
            redactedText = replacing(#"(?i)(?<![\p{L}\p{N}])"# + escapedPersonalString + #"(?![\p{L}\p{N}])"#, in: redactedText, with: Replacement.name)
        }
        redactedText = replacing(#"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"#, in: redactedText, with: Replacement.address)
        redactedText = replacing(#"(?i)(?<![\w:])(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}(?![\w:])"#, in: redactedText, with: Replacement.address)
        redactedText = replacing(#"(?<![\w.])(?:\+\d{1,3}[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\w.])"#, in: redactedText, with: Replacement.phoneNumber)

        // 4. Card, social insurance and health card numbers, as screenshots
        //    are masked.
        for sensitiveRange in SensitiveIdentifierDetector.sensitiveRanges(in: redactedText).reversed() {
            redactedText.replaceSubrange(sensitiveRange, with: Replacement.personalNumber)
        }

        // 5. Anything else long and opaque that mixes letters and digits
        //    (a key elfhub doesn't know the shape of, a base64 blob). Swift
        //    symbols in the stack ($s6elfhub…) and request ids stay.
        redactedText = replacing(#"(?<![\w$])(?=[A-Za-z0-9_+/-]*[0-9])(?=[A-Za-z0-9_+/-]*[A-Za-z])[A-Za-z0-9_+/-]{40,}={0,2}(?![\w])"#, in: redactedText, with: Replacement.token)
        return redactedText
    }

    /// Key prefixes of the services elfhub talks to and other common ones.
    static let providerKeyPattern = #"\b(?:sk-ant-[A-Za-z0-9_-]{10,}|sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}|sk_[A-Za-z0-9]{20,}|xai-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|hf_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|fc-[A-Za-z0-9]{20,}|tvly-[A-Za-z0-9-]{16,}|oaiapp_[A-Za-z0-9_-]{10,}|xox[abpr]-[A-Za-z0-9-]{10,}|pplx-[A-Za-z0-9]{20,})"#

    /// "api_key": "…", x-api-key: …, ?key=…, password=… — the name stays,
    /// the value goes.
    static let secretFieldPattern = #"(?i)\b(authorization|proxy-authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|apikey|key|access[-_]?token|refresh[-_]?token|id[-_]?token|session[-_]?token|token|client[-_]?secret|secret|password|passwd|cookie|set-cookie)\b("?\s*[:=]\s*"?)(?!\[REDACTED|Bearer\b|Basic\b)[^\s",;&}\]]+"#

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regularExpression.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
    }

    /// Every value worth taking out from one stored Keychain item: the item
    /// itself, and — for the ones stored as JSON (the ChatGPT sign-in) —
    /// every long string inside it.
    static func secretValues(fromStoredSecret storedSecret: String) -> [String] {
        var secretValues = [storedSecret]
        if let storedSecretData = storedSecret.data(using: .utf8),
           let storedObject = try? JSONSerialization.jsonObject(with: storedSecretData) {
            collectLongStrings(in: storedObject, into: &secretValues)
        }
        return secretValues.filter { $0.count >= 12 }
    }

    private static func collectLongStrings(in jsonObject: Any, into secretValues: inout [String]) {
        switch jsonObject {
        case let stringValue as String:
            secretValues.append(stringValue)
        case let arrayValue as [Any]:
            arrayValue.forEach { collectLongStrings(in: $0, into: &secretValues) }
        case let dictionaryValue as [String: Any]:
            dictionaryValue.values.forEach { collectLongStrings(in: $0, into: &secretValues) }
        default:
            break
        }
    }
}

// MARK: - Stack trace

nonisolated enum ErrorReportStackTrace {
    static let maximumFrameCount = 20

    /// elfhub's own frames from `Thread.callStackSymbols`, demangled, without
    /// the reporting code itself — where the error was caught, and how it
    /// got there.
    static func relevantFrames(
        fromCallStackSymbols callStackSymbols: [String],
        demangle: (String) -> String? = SwiftSymbolDemangler.demangle
    ) -> [String] {
        var relevantFrames: [String] = []
        for callStackSymbol in callStackSymbols {
            // "12  elfhub.debug.dylib  0x0000000104f2c1a8 $s6elfhub…C4nameyyF + 640"
            let fields = callStackSymbol.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            let moduleName = String(fields[1])
            guard moduleName.hasPrefix("elfhub") else { continue }
            var symbolWithOffset = fields[3...].joined(separator: " ")
            var offsetSuffix = ""
            if let plusRange = symbolWithOffset.range(of: " + ", options: .backwards) {
                offsetSuffix = String(symbolWithOffset[plusRange.lowerBound...])
                symbolWithOffset = String(symbolWithOffset[..<plusRange.lowerBound])
            }
            let readableSymbol = demangle(symbolWithOffset) ?? symbolWithOffset
            if readableSymbol.contains("ErrorReport") { continue }
            relevantFrames.append(readableSymbol + offsetSuffix)
            if relevantFrames.count == maximumFrameCount { break }
        }
        return relevantFrames
    }
}

/// Swift's own demangler, looked up at run time (it's in the Swift runtime
/// every Swift app loads, just not in a public header).
nonisolated enum SwiftSymbolDemangler {
    private typealias SwiftDemangleFunction = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangleFunction: SwiftDemangleFunction? = {
        guard let runtimeHandle = dlopen(nil, RTLD_NOW),
              let demangleSymbolAddress = dlsym(runtimeHandle, "swift_demangle") else { return nil }
        return unsafeBitCast(demangleSymbolAddress, to: SwiftDemangleFunction.self)
    }()

    static func demangle(_ mangledSymbol: String) -> String? {
        guard mangledSymbol.hasPrefix("$s") || mangledSymbol.hasPrefix("_$s"),
              let swiftDemangleFunction else { return nil }
        return mangledSymbol.withCString { mangledSymbolPointer in
            guard let demangledPointer = swiftDemangleFunction(mangledSymbolPointer, strlen(mangledSymbolPointer), nil, nil, 0) else {
                return nil
            }
            defer { free(demangledPointer) }
            return String(cString: demangledPointer)
        }
    }
}

// MARK: - The issue

nonisolated struct ErrorReportContext: Sendable {
    enum Origin: String, Sendable {
        case voiceTurn
        case typedChat
        case backgroundTask

        var displayDescription: String {
            switch self {
            case .voiceTurn: return "a spoken question (push-to-talk)"
            case .typedChat: return "a typed chat message"
            case .backgroundTask: return "an Elf's background task"
            }
        }
    }

    let errorDescription: String
    let errorTypeName: String
    let origin: Origin
    /// "anthropic · claude-opus-5-5" — the preset and model, never a URL.
    var modelDescription: String?
    /// "on (Ask first)", "off".
    var screenActionsDescription: String?
    var stackFrames: [String] = []
    var recentLogLines: [String] = []
    let supportDiagnostics: SupportDiagnostics
}

nonisolated struct ErrorReport: Equatable, Sendable {
    var title: String
    var body: String
}

nonisolated enum ErrorReportComposer {
    static let maximumTitleLength = 90
    static let maximumRecentLogLineCount = 40
    /// GitHub refuses new-issue links much past 8,000 characters.
    static let maximumIssueURLLength = 7_800
    static let shortenedNote = "\n\n_(Shortened to fit in a link. The full report was copied — paste it here in place of this text.)_"

    /// "LanguageModelProviderError.httpError" — the type and, for an enum
    /// with values, its case.
    static func errorTypeName(for error: Error) -> String {
        let typeName = String(describing: type(of: error))
        // Foundation's errors (URLError and friends) arrive bridged as
        // NSError: their domain and code say more than the type.
        if typeName == "NSError" || typeName.hasPrefix("__") {
            let bridgedError = error as NSError
            return "\(bridgedError.domain) \(bridgedError.code)"
        }
        let errorCaseName = String(describing: error).prefix { $0 != "(" }
        guard !errorCaseName.isEmpty, errorCaseName != typeName, !errorCaseName.contains(" ") else { return typeName }
        return typeName + "." + errorCaseName
    }

    /// The issue, every part redacted.
    static func compose(
        _ context: ErrorReportContext,
        knownSecrets: [String] = [],
        personalStrings: [String] = []
    ) -> ErrorReport {
        func redacted(_ text: String) -> String {
            ErrorReportRedactor.redacted(text, knownSecrets: knownSecrets, personalStrings: personalStrings)
        }
        let redactedErrorDescription = redacted(context.errorDescription)

        var title = "Error: " + titleSummary(fromErrorDescription: redactedErrorDescription, errorTypeName: context.errorTypeName)
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength - 1)) + "…"
        }

        var bodyLines: [String] = [
            "### What happened",
            "<!-- What were you doing when this happened? Anything you add here helps. -->",
            "",
            "",
            "### Error",
            "```",
            redactedErrorDescription,
            "```",
            "- Error type: `\(context.errorTypeName)`",
            "- During: \(context.origin.displayDescription)",
        ]
        if let modelDescription = context.modelDescription {
            bodyLines.append("- Model: \(redacted(modelDescription))")
        }
        if let screenActionsDescription = context.screenActionsDescription {
            bodyLines.append("- Screen actions: \(screenActionsDescription)")
        }
        if !context.stackFrames.isEmpty {
            bodyLines += ["", "### Where elfhub caught it", "```"]
            bodyLines += context.stackFrames.map(redacted)
            bodyLines.append("```")
        }
        let recentLogLines = context.recentLogLines.suffix(maximumRecentLogLineCount)
        if !recentLogLines.isEmpty {
            bodyLines += ["", "### Recent log", "```"]
            bodyLines += recentLogLines.map(redacted)
            bodyLines.append("```")
        }
        bodyLines += [
            "",
            "---",
            context.supportDiagnostics.versionLine,
            "_Keys, tokens, emails, names and personal numbers were removed automatically before this was filled in._",
        ]
        return ErrorReport(title: redacted(title), body: bodyLines.joined(separator: "\n"))
    }

    /// A readable one-liner for the title: an API's JSON error body becomes
    /// its "message" ("Model API error (400): messages.16…: all content
    /// must be…"); anything else is its first line.
    static func titleSummary(fromErrorDescription errorDescription: String, errorTypeName: String) -> String {
        if let jsonStartIndex = errorDescription.firstIndex(of: "{"),
           let jsonData = String(errorDescription[jsonStartIndex...]).data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData),
           let apiMessage = firstMessage(in: jsonObject) {
            let textBeforeJSON = errorDescription[..<jsonStartIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return textBeforeJSON.isEmpty ? apiMessage : textBeforeJSON + " " + apiMessage
        }
        let firstLine = errorDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? errorTypeName : firstLine
    }

    private static func firstMessage(in jsonObject: Any) -> String? {
        if let dictionaryValue = jsonObject as? [String: Any] {
            if let message = dictionaryValue["message"] as? String, !message.isEmpty { return message }
            for nestedValue in dictionaryValue.values {
                if let nestedMessage = firstMessage(in: nestedValue) { return nestedMessage }
            }
        } else if let arrayValue = jsonObject as? [Any] {
            for nestedValue in arrayValue {
                if let nestedMessage = firstMessage(in: nestedValue) { return nestedMessage }
            }
        }
        return nil
    }

    /// The GitHub new-issue link for the report, with the bug label. A body
    /// too long for a link is cut at a line and says so; the caller copies
    /// the full text to the clipboard then.
    static func newIssueURL(for report: ErrorReport, newIssuePageURL: URL) -> (url: URL, isShortened: Bool)? {
        func issueURL(body: String) -> URL? {
            guard var urlComponents = URLComponents(url: newIssuePageURL, resolvingAgainstBaseURL: false) else { return nil }
            urlComponents.queryItems = [
                URLQueryItem(name: "title", value: report.title),
                URLQueryItem(name: "labels", value: "bug"),
                URLQueryItem(name: "body", value: body),
            ]
            return urlComponents.url
        }
        guard let fullURL = issueURL(body: report.body) else { return nil }
        if fullURL.absoluteString.count <= maximumIssueURLLength {
            return (fullURL, false)
        }
        // Drop whole lines from the end (the log goes first, the error is
        // at the top) until it fits.
        var keptLines = report.body.components(separatedBy: "\n")
        while !keptLines.isEmpty {
            keptLines.removeLast()
            let shortenedBody = keptLines.joined(separator: "\n") + shortenedNote
            if let shortenedURL = issueURL(body: shortenedBody), shortenedURL.absoluteString.count <= maximumIssueURLLength {
                return (shortenedURL, true)
            }
        }
        return issueURL(body: shortenedNote.trimmingCharacters(in: .whitespacesAndNewlines)).map { ($0, true) }
    }
}
