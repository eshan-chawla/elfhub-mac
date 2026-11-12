//
//  ScreenActionExecutionTests.swift
//  elfhubTests
//
//  The pure parts of acting on screen: how key combos are read (strictly,
//  and on the user's own keyboard layout), when a re-checked target still
//  counts as the element the user approved, which channel an action uses,
//  and what a spoken yes must name.
//

import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import elfhub

@MainActor
struct ScreenActionExecutionTests {

    // MARK: - Key combos

    @Test func readsModifiersInPressOrderAndOneTerminalKey() {
        let resolvedCombo = ScreenActionSynthesizer.resolveKeyCombo(from: "cmd+shift+z")
        #expect(resolvedCombo?.keyCode == CGKeyCode(kVK_ANSI_Z))
        #expect(resolvedCombo?.modifierKeyCodes == [CGKeyCode(kVK_Command), CGKeyCode(kVK_Shift)])
        #expect(resolvedCombo?.modifiers.contains(.maskCommand) == true)
        #expect(resolvedCombo?.modifiers.contains(.maskShift) == true)
    }

    @Test func unknownOrAmbiguousCombosAreRefusedNotGuessed() {
        // "cmd+foo+s" used to quietly become cmd+s.
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "cmd+foo+s") == nil)
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "cmd+a+b") == nil)
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "cmd+shift") == nil)
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "") == nil)
    }

    @Test func understandsOtherToolsKeyNames() {
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "super+c")?.modifierKeyCodes == [CGKeyCode(kVK_Command)])
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "Page_Down")?.keyCode == CGKeyCode(kVK_PageDown))
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "f5")?.keyCode == CGKeyCode(kVK_F5))
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "forwarddelete")?.keyCode == CGKeyCode(kVK_ForwardDelete))
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "cmd+,")?.keyCode == CGKeyCode(kVK_ANSI_Comma))
        #expect(ScreenActionSynthesizer.resolveKeyCombo(from: "cmd++")?.keyCode == CGKeyCode(kVK_ANSI_Equal))
    }

    @Test func singleCharactersFollowTheUsersKeyboardLayout() {
        // On a French AZERTY keyboard the key labeled Z sits where US has W.
        let azertyCharacterKeyCodes: [String: CGKeyCode] = ["z": CGKeyCode(kVK_ANSI_W), "a": CGKeyCode(kVK_ANSI_Q)]
        let undoOnAzerty = ScreenActionSynthesizer.resolveKeyCombo(
            from: "cmd+z",
            characterKeyCodeForCurrentLayout: azertyCharacterKeyCodes
        )
        #expect(undoOnAzerty?.keyCode == CGKeyCode(kVK_ANSI_W))
        // Characters the layout doesn't list fall back to the US key.
        let saveOnAzerty = ScreenActionSynthesizer.resolveKeyCombo(
            from: "cmd+s",
            characterKeyCodeForCurrentLayout: azertyCharacterKeyCodes
        )
        #expect(saveOnAzerty?.keyCode == CGKeyCode(kVK_ANSI_S))
    }

    // MARK: - Re-checking approved targets

    private func resolvedClick(
        title: String?,
        role: String = "AXButton",
        application: String = "com.example.app",
        decision: ScreenActionConsentDecision = .proceedWithPreview,
        effect: ConsentSensitiveEffect? = nil
    ) -> ResolvedScreenAction {
        ResolvedScreenAction(
            action: .click(screenshotPixel: CGPoint(x: 10, y: 10), label: nil, screenNumber: nil),
            coreGraphicsTargetPoint: CGPoint(x: 10, y: 10),
            appKitTargetPoint: CGPoint(x: 10, y: 10),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            targetElementFacts: title.map { title in
                AccessibilityElementFacts(
                    frameInCoreGraphicsGlobalCoordinates: nil,
                    role: role,
                    subrole: nil,
                    title: title,
                    isSecureTextField: false,
                    isDefaultButton: false,
                    owningApplicationBundleIdentifier: application
                )
            },
            frontmostApplicationBundleIdentifier: application,
            consentDecision: decision,
            consequentialEffect: effect
        )
    }

    @Test func sameElementMatchesOnRoleTitleAndApp() {
        let shownSaveButton = resolvedClick(title: "Save")
        #expect(resolvedClick(title: "Save").targetsSameElement(as: shownSaveButton))
        #expect(!resolvedClick(title: "Delete").targetsSameElement(as: shownSaveButton))
        #expect(!resolvedClick(title: "Save", role: "AXLink").targetsSameElement(as: shownSaveButton))
        #expect(!resolvedClick(title: "Save", application: "com.other.app").targetsSameElement(as: shownSaveButton))
        // Something appeared where nothing readable was before: not the same.
        #expect(!resolvedClick(title: "Save").targetsSameElement(as: resolvedClick(title: nil)))
    }

    @Test func pendingConsentAsksForTheVerbsOfItsRiskyActions() {
        let sendClick = resolvedClick(
            title: "Send",
            decision: .requiresExplicitConfirmation(reason: "this would send something"),
            effect: .send
        )
        let ordinaryClick = resolvedClick(title: "Bold")
        let pendingConsent = PendingScreenActionConsent(
            resolvedActions: [ordinaryClick, sendClick],
            summary: "click “Bold”, then click “Send”",
            includesHighRiskAction: true,
            screenCaptures: [],
            userUtterance: "make it bold"
        )
        #expect(pendingConsent.confirmationEffects == [.send])
        #expect(pendingConsent.requiredConfirmationVerbKeywords.contains("send"))
        #expect(SpokenConfirmationParser.interpret("yes", requiredVerbKeywords: pendingConsent.requiredConfirmationVerbKeywords) == .needsVerbRestatement)
    }

    @Test func authorizedRiskyActionNeedsNoVerb() {
        // The user already said "send it", so the send proceeds with a preview
        // and a plain "go" is enough.
        let authorizedSend = resolvedClick(title: "Send", decision: .proceedWithPreview, effect: .send)
        let pendingConsent = PendingScreenActionConsent(
            resolvedActions: [authorizedSend],
            summary: "click “Send”",
            includesHighRiskAction: false,
            screenCaptures: [],
            userUtterance: "send it"
        )
        #expect(pendingConsent.confirmationEffects.isEmpty)
        #expect(pendingConsent.requiredConfirmationVerbKeywords.isEmpty)
    }

    // MARK: - Channel choice

    private func facts(role: String, isInsideWebContent: Bool = false, isSecureTextField: Bool = false) -> AccessibilityElementFacts {
        var elementFacts = AccessibilityElementFacts(
            frameInCoreGraphicsGlobalCoordinates: nil,
            role: role,
            subrole: nil,
            title: "Field",
            isSecureTextField: isSecureTextField,
            isDefaultButton: false,
            owningApplicationBundleIdentifier: "com.example.app"
        )
        elementFacts.isInsideWebContent = isInsideWebContent
        return elementFacts
    }

    @Test func nativeButtonsArePressedThroughAccessibility() {
        #expect(AccessibilityElementActions.shouldPressWithAccessibility(facts(role: "AXButton")))
        #expect(!AccessibilityElementActions.shouldPressWithAccessibility(facts(role: "AXButton", isInsideWebContent: true)))
        #expect(!AccessibilityElementActions.shouldPressWithAccessibility(facts(role: "AXTextArea")))
        #expect(!AccessibilityElementActions.shouldPressWithAccessibility(nil))
    }

    @Test func onlyLongPlainTextGoesInThroughAccessibility() {
        let longText = String(repeating: "a", count: 60)
        #expect(AccessibilityElementActions.shouldInsertTextWithAccessibility(longText, into: facts(role: "AXTextArea")))
        #expect(!AccessibilityElementActions.shouldInsertTextWithAccessibility("short", into: facts(role: "AXTextArea")))
        // A newline is a real Return press, so it must be typed.
        #expect(!AccessibilityElementActions.shouldInsertTextWithAccessibility(longText + "\n", into: facts(role: "AXTextArea")))
        #expect(!AccessibilityElementActions.shouldInsertTextWithAccessibility(longText, into: facts(role: "AXTextArea", isInsideWebContent: true)))
        #expect(!AccessibilityElementActions.shouldInsertTextWithAccessibility(longText, into: facts(role: "AXTextField", isSecureTextField: true)))
    }
}
