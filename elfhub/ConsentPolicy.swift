//
//  ConsentPolicy.swift
//  elfhub
//
//  Decides how much consent one screen action needs. Pure and unit-tested so
//  the rules are easy to audit.
//
//  Principles:
//   - The model never decides consent. Risk comes from the REAL target the
//     Accessibility API reports (its title, whether it's a password field or
//     a dialog's default button), the frontmost app and the web page it sits
//     on. The model's own label may only make an action MORE cautious, never
//     less, because text on screen can manipulate what the model writes.
//   - Authorization comes from the user's literal words and is scoped:
//     "fill in the form" does not authorize submitting it; "send it"
//     authorizes the send; "don't send it" authorizes nothing.
//   - Secrets and privacy-blocked apps are always the user's own step.
//   - Approval is bound to what was shown: if a re-check right before an
//     action fires finds it riskier than when the user (or auto-fire)
//     approved it, it needs a fresh approval.
//

import Foundation

/// Consequential effects that need the user's explicit say-so.
enum ConsentSensitiveEffect: String, CaseIterable {
    case send
    case delete
    case purchase
    case submit
    case closeOrQuit

    /// Plain-English verb used when asking for confirmation.
    var spokenVerb: String {
        switch self {
        case .send: return "send"
        case .delete: return "delete"
        case .purchase: return "buy"
        case .submit: return "submit"
        case .closeOrQuit: return "close"
        }
    }
}

enum ScreenActionConsentDecision: Equatable {
    /// Ordinary action the user asked for: show the target, then do it.
    case proceedWithPreview
    /// Consequential: wait for an explicit "go" / Confirm, even in auto-fire mode.
    case requiresExplicitConfirmation(reason: String)
    /// elfhub must not do this at all; hand it back to the user.
    case usersStep(reason: String)
}

struct ScreenActionConsentContext {
    let action: CompanionScreenAction
    /// The real element the action lands on: the element under the target
    /// point for click/scroll, the focused element for type/key, when known.
    let targetElementFacts: AccessibilityElementFacts?
    let frontmostApplicationBundleIdentifier: String?
    /// True when the target or frontmost app is on the privacy blocklist.
    let isTargetApplicationPrivacyBlocked: Bool
    /// What the user actually said or typed this turn.
    let userUtterance: String
    /// True while macOS Secure Event Input is on — some password field (or
    /// Terminal's "Secure Keyboard Entry") currently owns the keyboard.
    var isSecureEventInputActive: Bool = false
    /// For a drag: the element it would drop onto (the Trash makes a drag a
    /// delete), when known.
    var dragDropTargetElementFacts: AccessibilityElementFacts? = nil
}

enum ConsentPolicy {

    /// Words that, on a button/menu title, mean the action has that effect.
    static let targetTitleKeywordsByEffect: [ConsentSensitiveEffect: [String]] = [
        .send: ["send", "post", "publish", "reply", "tweet", "share", "message"],
        .delete: ["delete", "remove", "trash", "erase", "discard", "clear all", "empty trash", "uninstall"],
        .purchase: ["buy", "purchase", "pay", "checkout", "check out", "place order", "subscribe", "order now"],
        .submit: ["submit", "confirm", "sign up", "register", "apply", "accept", "agree"],
        .closeOrQuit: ["quit", "close", "log out", "sign out"]
    ]

    /// Words in the user's request that authorize that effect.
    static let utteranceKeywordsByEffect: [ConsentSensitiveEffect: [String]] = [
        .send: ["send", "post", "publish", "reply", "tweet", "share", "message"],
        .delete: ["delete", "remove", "trash", "erase", "discard", "clear", "empty", "uninstall", "get rid of"],
        .purchase: ["buy", "purchase", "pay", "checkout", "check out", "order", "subscribe"],
        .submit: ["submit", "confirm", "sign up", "register", "apply", "accept", "agree", "finish", "complete"],
        .closeOrQuit: ["quit", "close", "log out", "sign out", "exit"]
    ]

    /// Words that, shortly before a request word in the same clause, turn
    /// it into the opposite ("don't send it", "do not delete", "never submit").
    static let negationWords: Set<String> = [
        "not", "never", "no", "without", "nor", "cannot",
        "don't", "dont", "doesn't", "doesnt", "didn't", "didnt",
        "won't", "wont", "shouldn't", "shouldnt", "can't", "cant", "mustn't", "mustnt"
    ]

    /// How many words before a request word a negation still applies to.
    static let negationReachInWords = 3

    /// Words that, right before a request word, show it's used as a noun or
    /// description rather than a command: "a reply", "the order", "it's
    /// clear", "is complete". Those don't authorize anything.
    static let wordsMarkingTheNextWordAsNotACommand: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "his", "her", "its",
        "this", "that", "these", "those", "some", "any", "in", "it", "it's",
        "is", "are", "was", "were", "be", "been"
    ]

    /// Key combos that are destructive or hard to undo, by effect.
    static let sensitiveKeyCombosByEffect: [String: ConsentSensitiveEffect] = [
        "cmd+delete": .delete, "command+delete": .delete,
        "cmd+shift+delete": .delete, "command+shift+delete": .delete,
        "cmd+q": .closeOrQuit, "command+q": .closeOrQuit,
        "cmd+w": .closeOrQuit, "command+w": .closeOrQuit
    ]

    /// Apps where any action deserves a second look (shells, mail, chat):
    /// pressing Return there often runs a command or sends a message.
    static let sensitiveFrontmostApplicationFragments = [
        "terminal", "iterm", "warp", "mail", "messages", "slack", "discord", "telegram", "whatsapp", "outlook"
    ]

    /// Web pages that are mail, chat or social apps in a browser tab. A host
    /// matches when it is one of these domains or a subdomain of one.
    static let sensitiveWebPageDomains = [
        "mail.google.com", "chat.google.com", "slack.com", "discord.com", "whatsapp.com",
        "telegram.org", "messenger.com", "teams.microsoft.com", "teams.live.com",
        "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com",
        "icloud.com", "proton.me", "x.com", "twitter.com", "linkedin.com", "facebook.com", "instagram.com"
    ]

    // MARK: - Evaluation

    static func evaluate(_ context: ScreenActionConsentContext) -> ScreenActionConsentDecision {
        if context.isTargetApplicationPrivacyBlocked {
            return .usersStep(reason: "that's in an app i keep private, so you'll need to do that part yourself.")
        }
        if context.targetElementFacts?.isSecureTextField == true {
            return .usersStep(reason: "that's a password field, so please fill it in yourself.")
        }
        if case .type = context.action, context.isSecureEventInputActive {
            return .usersStep(reason: "secure keyboard entry is on right now, usually because a password field is active, so please type that part yourself.")
        }

        let authorizedEffects = authorizedEffects(fromUserUtterance: context.userUtterance)

        if let effect = consequentialEffect(of: context) {
            if authorizedEffects.contains(effect) {
                return .proceedWithPreview
            }
            return .requiresExplicitConfirmation(reason: "this would \(effect.spokenVerb) something")
        }

        if Self.isClickOnTarget(context.action), let facts = context.targetElementFacts, facts.isDefaultButton,
           !userUtteranceNamesTarget(context.userUtterance, targetTitle: facts.title),
           !authorizedEffects.contains(.submit) {
            return .requiresExplicitConfirmation(reason: "that button finishes the form")
        }

        if let sensitiveContextReason = sensitiveContextReason(of: context) {
            return .requiresExplicitConfirmation(reason: sensitiveContextReason)
        }

        return .proceedWithPreview
    }

    /// The consequential effect this action would have (send, delete, …), or
    /// nil for an ordinary action. Exposed so a spoken confirmation can ask
    /// the user to name the effect ("yes, send it").
    static func consequentialEffect(of context: ScreenActionConsentContext) -> ConsentSensitiveEffect? {
        let isSensitiveContext = sensitiveContextReason(of: context) != nil
        switch context.action {
        case let .click(_, modelLabel, _), let .doubleClick(_, modelLabel, _),
             let .rightClick(_, modelLabel, _), let .tripleClick(_, modelLabel, _):
            // The real title wins; the model's label can only add caution.
            return sensitiveEffect(forTargetText: context.targetElementFacts?.title)
                ?? sensitiveEffect(forTargetText: modelLabel)
        case let .key(comboString):
            let normalizedCombo = comboString.lowercased().replacingOccurrences(of: " ", with: "")
            if let effect = sensitiveKeyCombosByEffect[normalizedCombo] {
                return effect
            }
            let isReturnKey = normalizedCombo == "return" || normalizedCombo == "enter"
            if isReturnKey && isSensitiveContext {
                return .send
            }
            return nil
        case let .type(text):
            // A newline is typed as a real Return press, so it has the same
            // effect as [KEY:return] — in a chat or mail app, that sends.
            let containsReturnPress = text.contains("\n") || text.contains("\r")
            if containsReturnPress && isSensitiveContext {
                return .send
            }
            return nil
        // A drag is judged where it drops (onto the Trash is a delete) and
        // by what it picks up; moving the pointer changes nothing.
        case .drag:
            return sensitiveEffect(forTargetText: context.dragDropTargetElementFacts?.title)
                ?? sensitiveEffect(forTargetText: context.targetElementFacts?.title)
        case .scroll, .moveMouse:
            return nil
        }
    }

    /// When a fresh approval is needed before firing: a re-check right before
    /// the action found it riskier than the decision that was approved (an
    /// ordinary action that now sends, or a confirmation for another reason).
    /// A user's-step result is handled separately — it always stops.
    static func requiresFreshApproval(
        approvedDecision: ScreenActionConsentDecision,
        currentDecision: ScreenActionConsentDecision
    ) -> Bool {
        guard case let .requiresExplicitConfirmation(currentReason) = currentDecision else {
            return false
        }
        if case let .requiresExplicitConfirmation(approvedReason) = approvedDecision {
            return approvedReason != currentReason
        }
        return true
    }

    /// Effects the user's own words authorize: a request word counts only
    /// when it is used as a command ("reply to him", not "draft a reply") and
    /// isn't negated in its clause ("don't send it" authorizes nothing).
    static func authorizedEffects(fromUserUtterance userUtterance: String) -> Set<ConsentSensitiveEffect> {
        Set(utteranceKeywordsByEffect.compactMap { effect, keywords in
            keywords.contains { containsAffirmedPhrase($0, in: userUtterance, mustBeUsedAsCommand: true) } ? effect : nil
        })
    }

    /// The effect a button/menu title implies, if any.
    /// Clicks of any count press what's under them (a double-click on a
    /// default button submits just like a click).
    static func isClickOnTarget(_ action: CompanionScreenAction) -> Bool {
        switch action {
        case .click, .doubleClick, .tripleClick: return true
        default: return false
        }
    }

    static func sensitiveEffect(forTargetText targetText: String?) -> ConsentSensitiveEffect? {
        guard let targetText, !targetText.isEmpty else { return nil }
        // Fixed order so overlapping words resolve deterministically.
        for effect in ConsentSensitiveEffect.allCases {
            let keywords = targetTitleKeywordsByEffect[effect] ?? []
            if keywords.contains(where: { containsWholeWord($0, in: targetText) }) {
                return effect
            }
        }
        return nil
    }

    static func isSensitiveApplication(bundleIdentifier: String?) -> Bool {
        guard let loweredBundleIdentifier = bundleIdentifier?.lowercased() else { return false }
        return sensitiveFrontmostApplicationFragments.contains { loweredBundleIdentifier.contains($0) }
    }

    /// True for mail, chat and social sites, where Return or a click often
    /// sends or posts something.
    static func isSensitiveWebPage(host: String?) -> Bool {
        guard let loweredHost = host?.lowercased(), !loweredHost.isEmpty else { return false }
        return sensitiveWebPageDomains.contains { sensitiveDomain in
            loweredHost == sensitiveDomain || loweredHost.hasSuffix("." + sensitiveDomain)
        }
    }

    // MARK: - Helpers

    /// Why every action here deserves a second look, or nil when the action
    /// isn't in a mail/chat/shell app or on a mail/chat/social web page.
    private static func sensitiveContextReason(of context: ScreenActionConsentContext) -> String? {
        if isSensitiveApplication(bundleIdentifier: context.frontmostApplicationBundleIdentifier) {
            return "you're in an app where actions can send or run things"
        }
        if isSensitiveWebPage(host: context.targetElementFacts?.webPageHost) {
            return "you're on a page where actions can send things"
        }
        return nil
    }

    private static func userUtteranceNamesTarget(_ userUtterance: String, targetTitle: String?) -> Bool {
        guard let targetTitle, !targetTitle.isEmpty else { return false }
        return containsAffirmedPhrase(targetTitle, in: userUtterance)
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: #"\b"# + escapedWord + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when `phrase` appears as whole words somewhere in `text` without a
    /// negation word in the few words before it, in the same clause. Clauses
    /// end at punctuation and at "but", so in "it's not a problem, send it"
    /// the "not" doesn't reach "send". With `mustBeUsedAsCommand`, an
    /// occurrence right after "a"/"the"/"is"… (a noun or description) doesn't
    /// count either; button names ("click the continue button") skip that rule.
    static func containsAffirmedPhrase(_ phrase: String, in text: String, mustBeUsedAsCommand: Bool = false) -> Bool {
        let phraseWords = words(in: phrase)
        guard !phraseWords.isEmpty else { return false }

        for clause in clauses(in: text) {
            let clauseWords = words(in: clause)
            guard clauseWords.count >= phraseWords.count else { continue }

            for startIndex in 0...(clauseWords.count - phraseWords.count)
            where Array(clauseWords[startIndex..<(startIndex + phraseWords.count)]) == phraseWords {
                let negationWindowStart = max(0, startIndex - negationReachInWords)
                let wordsBeforePhrase = clauseWords[negationWindowStart..<startIndex]
                let isNegated = wordsBeforePhrase.contains { negationWords.contains($0) }

                let wordRightBeforePhrase = startIndex > 0 ? clauseWords[startIndex - 1] : nil
                let isUsedAsNounOrDescription = wordRightBeforePhrase.map { wordsMarkingTheNextWordAsNotACommand.contains($0) } ?? false

                if !isNegated && !(mustBeUsedAsCommand && isUsedAsNounOrDescription) {
                    return true
                }
            }
        }
        return false
    }

    private static func words(in text: String) -> [String] {
        UtteranceWords.words(in: text)
    }

    private static func clauses(in text: String) -> [String] {
        text.replacingOccurrences(of: #"\bbut\b"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: CharacterSet(charactersIn: ",.;:!?\n"))
    }
}

// MARK: - Words of an utterance

/// Splits what the user said into comparable words. Shared by the consent
/// rules and the spoken-confirmation parser so both read words the same way.
enum UtteranceWords {

    /// Lowercased words with curly apostrophes normalized, so "Don’t" and
    /// "don't" compare equal and punctuation never sticks to a word.
    static func words(in text: String) -> [String] {
        let normalizedText = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard let wordRegex = try? NSRegularExpression(pattern: #"[a-z0-9]+(?:'[a-z]+)?"#) else { return [] }
        let fullRange = NSRange(normalizedText.startIndex..., in: normalizedText)
        return wordRegex.matches(in: normalizedText, range: fullRange).compactMap { match in
            Range(match.range, in: normalizedText).map { String(normalizedText[$0]) }
        }
    }

    /// Where the phrase's words first appear, in order and next to each
    /// other, inside `words`; nil when they don't.
    static func firstIndex(ofPhrase phrase: String, in words: [String]) -> Int? {
        let phraseWords = self.words(in: phrase)
        guard !phraseWords.isEmpty, words.count >= phraseWords.count else { return nil }
        for startIndex in 0...(words.count - phraseWords.count)
        where Array(words[startIndex..<(startIndex + phraseWords.count)]) == phraseWords {
            return startIndex
        }
        return nil
    }
}
