//
//  ConsentPolicyTests.swift
//  elfhubTests
//
//  The consent rules for real screen actions, and the Accessibility snapping
//  rules that refine where actions and marks land. Both are pure and decide
//  safety-relevant behavior, so they are pinned down here.
//

import CoreGraphics
import Testing
@testable import elfhub

struct ConsentPolicyTests {

    private func elementFacts(
        title: String? = nil,
        role: String = "AXButton",
        isSecureTextField: Bool = false,
        isDefaultButton: Bool = false
    ) -> AccessibilityElementFacts {
        AccessibilityElementFacts(
            frameInCoreGraphicsGlobalCoordinates: CGRect(x: 100, y: 100, width: 80, height: 24),
            role: role,
            subrole: isSecureTextField ? "AXSecureTextField" : nil,
            title: title,
            isSecureTextField: isSecureTextField,
            isDefaultButton: isDefaultButton,
            owningApplicationBundleIdentifier: "com.example.app"
        )
    }

    private func decision(
        for action: CompanionScreenAction,
        facts: AccessibilityElementFacts? = nil,
        frontmostApplication: String? = "com.example.app",
        privacyBlocked: Bool = false,
        utterance: String
    ) -> ScreenActionConsentDecision {
        ConsentPolicy.evaluate(ScreenActionConsentContext(
            action: action,
            targetElementFacts: facts,
            frontmostApplicationBundleIdentifier: frontmostApplication,
            isTargetApplicationPrivacyBlocked: privacyBlocked,
            userUtterance: utterance
        ))
    }

    private let clickAction = CompanionScreenAction.click(screenshotPixel: CGPoint(x: 10, y: 10), label: "ok button", screenNumber: nil)

    // MARK: - User's step

    @Test func passwordFieldIsAlwaysTheUsersStep() {
        let result = decision(for: clickAction, facts: elementFacts(role: "AXTextField", isSecureTextField: true), utterance: "log me in")
        guard case .usersStep = result else {
            Issue.record("expected usersStep, got \(result)")
            return
        }
    }

    @Test func privacyBlockedAppIsAlwaysTheUsersStep() {
        let result = decision(for: clickAction, privacyBlocked: true, utterance: "click it")
        guard case .usersStep = result else {
            Issue.record("expected usersStep, got \(result)")
            return
        }
    }

    // MARK: - Scoped authorization

    @Test func realSendButtonNeedsExplicitYesWhenUserDidNotSaySend() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Send"), utterance: "fill in the email for me")
        #expect(result == .requiresExplicitConfirmation(reason: "this would send something"))
    }

    @Test func userSayingSendAuthorizesTheSend() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Send"), utterance: "okay send it")
        #expect(result == .proceedWithPreview)
    }

    @Test func realTitleOverridesAnInnocentModelLabel() {
        // An injected page could make the model call a Delete button "ok button";
        // the real Accessibility title still escalates it.
        let result = decision(for: clickAction, facts: elementFacts(title: "Delete Account"), utterance: "click ok")
        #expect(result == .requiresExplicitConfirmation(reason: "this would delete something"))
    }

    @Test func modelLabelCanOnlyAddCaution() {
        let riskyLabelClick = CompanionScreenAction.click(screenshotPixel: .zero, label: "delete button", screenNumber: nil)
        let result = decision(for: riskyLabelClick, facts: nil, utterance: "click that")
        #expect(result == .requiresExplicitConfirmation(reason: "this would delete something"))
    }

    @Test func fillingInDoesNotAuthorizeADefaultSubmitButton() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Continue", isDefaultButton: true), utterance: "fill in the form")
        #expect(result == .requiresExplicitConfirmation(reason: "that button finishes the form"))
    }

    @Test func namingTheDefaultButtonAuthorizesIt() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Continue", isDefaultButton: true), utterance: "click continue")
        #expect(result == .proceedWithPreview)
    }

    @Test func ordinaryClickProceeds() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Bold"), utterance: "make it bold")
        #expect(result == .proceedWithPreview)
    }

    // MARK: - Keys and sensitive apps

    @Test func quitShortcutNeedsConfirmationUnlessAsked() {
        let quitKey = CompanionScreenAction.key(comboString: "cmd+q")
        #expect(decision(for: quitKey, utterance: "save my work") == .requiresExplicitConfirmation(reason: "this would close something"))
        #expect(decision(for: quitKey, utterance: "quit the app") == .proceedWithPreview)
    }

    @Test func returnInMessagingAppCountsAsSending() {
        let returnKey = CompanionScreenAction.key(comboString: "return")
        let result = decision(for: returnKey, frontmostApplication: "com.tinyspeck.slackmacgap", utterance: "type hello")
        #expect(result == .requiresExplicitConfirmation(reason: "this would send something"))
    }

    @Test func anyActionInTerminalNeedsConfirmation() {
        let typeAction = CompanionScreenAction.type(text: "ls")
        let result = decision(for: typeAction, frontmostApplication: "com.apple.Terminal", utterance: "type ls")
        #expect(result == .requiresExplicitConfirmation(reason: "you're in an app where actions can send or run things"))
    }

    @Test func authorizationMatchesWholeWordsOnly() {
        // "resend" and "sender" must not count as saying "send".
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "who is the sender, resend later").contains(.send))
        #expect(ConsentPolicy.authorizedEffects(fromUserUtterance: "Send it now").contains(.send))
    }

    // MARK: - Negation

    @Test func negatedRequestDoesNotAuthorizeTheEffect() {
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "write the reply but don't send it").contains(.send))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "do not delete anything").contains(.delete))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "make sure you never submit it").contains(.submit))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "Don’t send it yet").contains(.send))
    }

    @Test func negationOnlyCoversItsOwnClause() {
        // "not" belongs to the first clause; the second clause asks to send.
        #expect(ConsentPolicy.authorizedEffects(fromUserUtterance: "it's not a problem, send it").contains(.send))
        let mixedRequest = ConsentPolicy.authorizedEffects(fromUserUtterance: "send it and don't delete the draft")
        #expect(mixedRequest.contains(.send))
        #expect(!mixedRequest.contains(.delete))
    }

    @Test func requestWordsUsedAsNounsDoNotAuthorize() {
        // "a reply" / "a message" / "the order" name things; they don't ask to send or buy.
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "draft a reply to sam").contains(.send))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "type a message saying hi").contains(.send))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "check the order status").contains(.purchase))
        #expect(!ConsentPolicy.authorizedEffects(fromUserUtterance: "the form is complete now").contains(.submit))
        #expect(ConsentPolicy.authorizedEffects(fromUserUtterance: "reply to him with thanks").contains(.send))
        #expect(ConsentPolicy.authorizedEffects(fromUserUtterance: "message sam that i'm late").contains(.send))
    }

    @Test func namingAButtonWithTheStillAuthorizesIt() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Continue", isDefaultButton: true), utterance: "click the continue button")
        #expect(result == .proceedWithPreview)
    }

    @Test func negatedSendLeavesARealSendButtonNeedingConfirmation() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Send"), utterance: "draft it, don't send it")
        #expect(result == .requiresExplicitConfirmation(reason: "this would send something"))
    }

    @Test func negatedButtonNameDoesNotAuthorizeTheDefaultButton() {
        let result = decision(for: clickAction, facts: elementFacts(title: "Continue", isDefaultButton: true), utterance: "don't click continue yet")
        #expect(result == .requiresExplicitConfirmation(reason: "that button finishes the form"))
    }

    // MARK: - Typed newlines are Return presses

    @Test func typedNewlineInMessagingAppCountsAsSending() {
        let typeWithNewline = CompanionScreenAction.type(text: "see you soon\n")
        let result = decision(for: typeWithNewline, frontmostApplication: "com.tinyspeck.slackmacgap", utterance: "type see you soon")
        #expect(result == .requiresExplicitConfirmation(reason: "this would send something"))
    }

    @Test func typedNewlineIsAllowedWhenTheUserAskedToSend() {
        let typeWithNewline = CompanionScreenAction.type(text: "see you soon\n")
        let result = decision(for: typeWithNewline, frontmostApplication: "com.tinyspeck.slackmacgap", utterance: "send see you soon")
        #expect(result == .proceedWithPreview)
    }

    @Test func typedNewlineInAnOrdinaryAppProceeds() {
        let typeWithNewline = CompanionScreenAction.type(text: "first line\nsecond line")
        #expect(decision(for: typeWithNewline, frontmostApplication: "com.apple.TextEdit", utterance: "type two lines") == .proceedWithPreview)
    }

    // MARK: - Web pages inside browsers

    @Test func sensitiveWebPagesAreRecognizedByHost() {
        #expect(ConsentPolicy.isSensitiveWebPage(host: "mail.google.com"))
        #expect(ConsentPolicy.isSensitiveWebPage(host: "app.slack.com"))
        #expect(ConsentPolicy.isSensitiveWebPage(host: "web.whatsapp.com"))
        #expect(ConsentPolicy.isSensitiveWebPage(host: "outlook.office.com"))
        #expect(!ConsentPolicy.isSensitiveWebPage(host: "en.wikipedia.org"))
        #expect(!ConsentPolicy.isSensitiveWebPage(host: "notslack.com"))
        #expect(!ConsentPolicy.isSensitiveWebPage(host: nil))
    }

    @Test func typedNewlineOnAWebMailPageCountsAsSending() {
        var focusedComposeField = elementFacts(title: "Message Body", role: "AXTextArea")
        focusedComposeField.webPageHost = "mail.google.com"
        let typeWithNewline = CompanionScreenAction.type(text: "thanks!\n")
        let result = decision(for: typeWithNewline, facts: focusedComposeField, frontmostApplication: "com.google.Chrome", utterance: "type thanks")
        #expect(result == .requiresExplicitConfirmation(reason: "this would send something"))
    }

    @Test func anyActionOnAWebChatPageNeedsConfirmation() {
        var channelLink = elementFacts(title: "general", role: "AXLink")
        channelLink.webPageHost = "app.slack.com"
        let result = decision(for: clickAction, facts: channelLink, frontmostApplication: "com.apple.Safari", utterance: "open general")
        #expect(result == .requiresExplicitConfirmation(reason: "you're on a page where actions can send things"))
    }

    // MARK: - Secure keyboard entry

    @Test func typingWhileSecureInputIsOnIsTheUsersStep() {
        let result = ConsentPolicy.evaluate(ScreenActionConsentContext(
            action: .type(text: "hunter2"),
            targetElementFacts: nil,
            frontmostApplicationBundleIdentifier: "com.apple.TextEdit",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "type it in",
            isSecureEventInputActive: true
        ))
        guard case .usersStep = result else {
            Issue.record("expected usersStep, got \(result)")
            return
        }
    }

    @Test func clickingWhileSecureInputIsOnIsUnaffected() {
        let result = ConsentPolicy.evaluate(ScreenActionConsentContext(
            action: clickAction,
            targetElementFacts: elementFacts(title: "Bold"),
            frontmostApplicationBundleIdentifier: "com.example.app",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "make it bold",
            isSecureEventInputActive: true
        ))
        #expect(result == .proceedWithPreview)
    }

    // MARK: - Re-approval when the screen changes

    @Test func escalatedDecisionNeedsFreshApproval() {
        let ordinary = ScreenActionConsentDecision.proceedWithPreview
        let sending = ScreenActionConsentDecision.requiresExplicitConfirmation(reason: "this would send something")
        let deleting = ScreenActionConsentDecision.requiresExplicitConfirmation(reason: "this would delete something")
        #expect(ConsentPolicy.requiresFreshApproval(approvedDecision: ordinary, currentDecision: sending))
        #expect(ConsentPolicy.requiresFreshApproval(approvedDecision: sending, currentDecision: deleting))
        #expect(!ConsentPolicy.requiresFreshApproval(approvedDecision: sending, currentDecision: sending))
        #expect(!ConsentPolicy.requiresFreshApproval(approvedDecision: sending, currentDecision: ordinary))
        #expect(!ConsentPolicy.requiresFreshApproval(approvedDecision: ordinary, currentDecision: ordinary))
    }

    @Test func consequentialEffectIsExposedForConfirmationWording() {
        let context = ScreenActionConsentContext(
            action: clickAction,
            targetElementFacts: elementFacts(title: "Move to Trash"),
            frontmostApplicationBundleIdentifier: "com.apple.finder",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "click it"
        )
        #expect(ConsentPolicy.consequentialEffect(of: context) == .delete)
    }

    // MARK: - Accessibility snapping

    @Test func containersAndHugeElementsAreNotSnapped() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(!AccessibilitySnapping.isElementUsableForSnapping(
            elementFrame: CGRect(x: 0, y: 0, width: 400, height: 300), role: "AXGroup", displayBounds: displayBounds))
        #expect(!AccessibilitySnapping.isElementUsableForSnapping(
            elementFrame: CGRect(x: 0, y: 0, width: 1400, height: 30), role: "AXButton", displayBounds: displayBounds))
        #expect(AccessibilitySnapping.isElementUsableForSnapping(
            elementFrame: CGRect(x: 0, y: 0, width: 80, height: 24), role: "AXButton", displayBounds: displayBounds))
    }

    @Test func clickSnapsToButtonCenterOnlyWhenInside() {
        let buttonFrame = CGRect(x: 100, y: 100, width: 80, height: 24)
        #expect(AccessibilitySnapping.snappedTargetPoint(
            modelPoint: CGPoint(x: 105, y: 103), elementFrame: buttonFrame, role: "AXButton") == CGPoint(x: 140, y: 112))
        #expect(AccessibilitySnapping.snappedTargetPoint(
            modelPoint: CGPoint(x: 50, y: 50), elementFrame: buttonFrame, role: "AXButton") == nil)
        #expect(AccessibilitySnapping.snappedTargetPoint(
            modelPoint: CGPoint(x: 105, y: 103), elementFrame: buttonFrame, role: "AXTextArea") == nil)
    }

    @Test func highlightSnapsOnlyWhenBoxesAgree() {
        let elementFrame = CGRect(x: 100, y: 100, width: 80, height: 24)
        let closeModelBox = CGRect(x: 96, y: 98, width: 90, height: 28)
        let farModelBox = CGRect(x: 400, y: 400, width: 90, height: 28)
        #expect(AccessibilitySnapping.snappedHighlightFrame(modelFrame: closeModelBox, elementFrame: elementFrame)
                == elementFrame.insetBy(dx: -4, dy: -4))
        #expect(AccessibilitySnapping.snappedHighlightFrame(modelFrame: farModelBox, elementFrame: elementFrame) == nil)
    }
}
