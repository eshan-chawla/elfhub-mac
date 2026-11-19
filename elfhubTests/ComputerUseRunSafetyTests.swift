//
//  ComputerUseRunSafetyTests.swift
//  elfhubTests
//
//  The stop and consent rules of a multi-step run that the review asked
//  for: Esc is watched for the whole run, touching the mouse or keyboard
//  between steps ends it, an older run's clean-up can't end a newer one, a
//  fallback model never replays steps that already ran, a drag is judged
//  where it drops, and double- or triple-clicking a form's default button
//  asks like a click.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

@MainActor
struct ComputerUseRunSafetyTests {

    private func elementFacts(title: String?, isDefaultButton: Bool = false, application: String = "com.example.app") -> AccessibilityElementFacts {
        AccessibilityElementFacts(
            frameInCoreGraphicsGlobalCoordinates: CGRect(x: 100, y: 100, width: 80, height: 24),
            role: "AXButton",
            subrole: nil,
            title: title,
            isSecureTextField: false,
            isDefaultButton: isDefaultButton,
            owningApplicationBundleIdentifier: application
        )
    }

    @Test func escIsWatchedForTheWholeRun() {
        #expect(CompanionManager.shouldListenForEscape(
            hasVisibleGuidance: false, voiceState: .idle, isChatReplyStreaming: false, isComputerUseRunActive: true
        ))
        #expect(!CompanionManager.shouldListenForEscape(
            hasVisibleGuidance: false, voiceState: .idle, isChatReplyStreaming: false, isComputerUseRunActive: false
        ))
    }

    @Test func touchingTheMouseOrKeyboardBetweenStepsEndsTheRun() {
        // The last step ended 4 s ago; the user moved the mouse 1 s ago.
        #expect(ScreenActionCoordinator.userTookOverBetweenSteps(secondsSinceLastPhysicalInput: 1, secondsSinceLastStep: 4))
        // Nothing since the last step.
        #expect(!ScreenActionCoordinator.userTookOverBetweenSteps(secondsSinceLastPhysicalInput: 10, secondsSinceLastStep: 4))
        // The tail of elfhub's own events right as the step ended doesn't count.
        #expect(!ScreenActionCoordinator.userTookOverBetweenSteps(secondsSinceLastPhysicalInput: 3.95, secondsSinceLastStep: 4))
    }

    @Test func anOlderRunsCleanUpCantEndANewerRun() {
        let screenActionCoordinator = ScreenActionCoordinator()
        let olderRunIdentifier = screenActionCoordinator.beginComputerUseRun()
        let newerRunIdentifier = screenActionCoordinator.beginComputerUseRun()
        screenActionCoordinator.finishComputerUseRun(olderRunIdentifier)
        #expect(screenActionCoordinator.isComputerUseRunActive)
        screenActionCoordinator.finishComputerUseRun(newerRunIdentifier)
        #expect(!screenActionCoordinator.isComputerUseRunActive)
    }

    @Test func aFallbackModelNeverReplaysStepsThatAlreadyRan() {
        #expect(CompanionTurnPipeline.mayRestartTurnOnFallbackModel(didActOnScreen: false))
        #expect(!CompanionTurnPipeline.mayRestartTurnOnFallbackModel(didActOnScreen: true))
    }

    @Test func aDragIsJudgedWhereItDrops() {
        let dragOntoTrash = ScreenActionConsentContext(
            action: .drag(fromScreenshotPixel: CGPoint(x: 10, y: 10), toScreenshotPixel: CGPoint(x: 900, y: 700), screenNumber: nil),
            targetElementFacts: elementFacts(title: "Quarterly report.pdf"),
            frontmostApplicationBundleIdentifier: "com.apple.finder",
            isTargetApplicationPrivacyBlocked: false,
            userUtterance: "tidy up my desktop",
            dragDropTargetElementFacts: elementFacts(title: "Trash", application: "com.apple.dock")
        )
        #expect(ConsentPolicy.consequentialEffect(of: dragOntoTrash) == .delete)
        guard case .requiresExplicitConfirmation = ConsentPolicy.evaluate(dragOntoTrash) else {
            Issue.record("dragging onto the Trash should ask first")
            return
        }
    }

    @Test func doubleOrTripleClickingADefaultButtonAsksLikeAClick() {
        for action in [
            CompanionScreenAction.withModifierKeys(["shift"], .click(screenshotPixel: CGPoint(x: 5, y: 5), label: nil, screenNumber: nil)),
            CompanionScreenAction.doubleClick(screenshotPixel: CGPoint(x: 5, y: 5), label: nil, screenNumber: nil),
            .tripleClick(screenshotPixel: CGPoint(x: 5, y: 5), label: nil, screenNumber: nil),
        ] {
            let decision = ConsentPolicy.evaluate(ScreenActionConsentContext(
                action: action,
                targetElementFacts: elementFacts(title: "Continue", isDefaultButton: true),
                frontmostApplicationBundleIdentifier: "com.example.app",
                isTargetApplicationPrivacyBlocked: false,
                userUtterance: "fill in the form"
            ))
            guard case .requiresExplicitConfirmation = decision else {
                Issue.record("\(action) on a default button should ask first, got \(decision)")
                continue
            }
        }
    }
}
