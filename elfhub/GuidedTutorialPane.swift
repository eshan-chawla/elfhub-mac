//
//  GuidedTutorialPane.swift
//  elfhub
//
//  The optional walkthrough's page in the main window (GuidedTutorialController
//  runs it): one real thing to try per step, completed automatically when
//  elfhub sees it happen, skippable at every point.
//

import SwiftUI

// MARK: - Guided Tutorial Pane

/// The optional walkthrough: one real thing to try per step, completed
/// automatically when elfhub sees it happen. Skippable at every point.
struct GuidedTutorialPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var guidedTutorialController: GuidedTutorialController
    var onSelectSection: (MainAppSection) -> Void

    var body: some View {
        MainAppPage {
            HStack {
                // A page title, like every other page's (MainAppPage).
                Text("Tutorial")
                    .font(DS.Typography.headingLarge)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("End tutorial") { guidedTutorialController.endTutorial() }
                    .pointerCursor()
            }

            progressIndicator

            // The natural voice chosen in onboarding may still be downloading.
            NaturalVoiceDownloadStatusRow(
                onDeviceVoiceModelStore: OnDeviceVoiceModelLayers.shared.store,
                onTryAgain: {
                    let naturalVoiceIdentifier = OnDeviceVoiceModelLayers.shared.store
                        .voiceIdentifier(forModelIdentifier: OnboardingNaturalVoice.modelIdentifier)
                        ?? OnboardingNaturalVoice.defaultVoiceIdentifier
                    companionManager.startNaturalVoiceDownload(voiceIdentifier: naturalVoiceIdentifier)
                }
            )

            if guidedTutorialController.isFinished {
                finishedCard
            } else if let currentStep = guidedTutorialController.currentStep {
                stepCard(currentStep)
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(guidedTutorialController.steps.enumerated()), id: \.element) { stepIndex, tutorialStep in
                Capsule()
                    .fill(progressColor(stepIndex: stepIndex, tutorialStep: tutorialStep))
                    .frame(height: 4)
            }
        }
    }

    private func progressColor(stepIndex: Int, tutorialStep: GuidedTutorialStep) -> Color {
        if guidedTutorialController.completedSteps.contains(tutorialStep) {
            return DS.Colors.success
        }
        if stepIndex == guidedTutorialController.currentStepIndex && !guidedTutorialController.isFinished {
            return DS.Colors.accent
        }
        return DS.Colors.contrastTint.opacity(0.1)
    }

    private func stepCard(_ tutorialStep: GuidedTutorialStep) -> some View {
        let isComplete = guidedTutorialController.isCurrentStepComplete
        return VStack(alignment: .leading, spacing: 14) {
            Text("Step \(guidedTutorialController.currentStepIndex + 1) of \(guidedTutorialController.steps.count)")
                .font(DS.Typography.interface(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text(tutorialStep.title)
                .font(DS.Typography.interface(size: 17, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(tutorialStep.instruction(pushToTalkShortcutText: companionManager.pushToTalkShortcutOption.displayText))
                .font(DS.Typography.interface(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if tutorialStep == .pushToTalk {
                HStack(spacing: 4) {
                    ForEach(companionManager.pushToTalkShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                        KeyCapsule(keyLabel: keyLabel)
                    }
                }
            }

            if !tutorialStep.completesOnAcknowledgement {
                HStack(spacing: 6) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DS.Colors.success)
                        Text("Nice — that worked.")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to try it…")
                    }
                }
                .font(DS.Typography.interface(size: 12, weight: .medium))
                .foregroundColor(isComplete ? DS.Colors.success : DS.Colors.textTertiary)
            }

            HStack {
                if tutorialStep == .textChat {
                    Button("Open chat") { onSelectSection(.chat) }
                        .pointerCursor()
                }
                if tutorialStep == .screenActions {
                    Button("Open Settings › Tools & capabilities") { onSelectSection(.settings(.tools)) }
                        .dsSecondaryButtonStyle()
                }
                Spacer()
                if !isComplete && !tutorialStep.completesOnAcknowledgement {
                    Button("Skip this step") { guidedTutorialController.skipCurrentStep() }
                        .dsGhostButtonStyle()
                }
                if tutorialStep.completesOnAcknowledgement {
                    Button("Got it") { guidedTutorialController.acknowledgeCurrentStep() }
                        .dsPrimaryButtonStyle()
                } else {
                    Button("Next step") { guidedTutorialController.goToNextStep() }
                        .dsPrimaryButtonStyle()
                        .disabled(!isComplete)
                }
            }
        }
        .mainAppCard()
    }

    private var finishedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're all set.")
                .font(DS.Typography.interface(size: 17, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold \(companionManager.pushToTalkShortcutOption.displayText) anytime to talk, or use Chat. You can replay this tutorial from Settings › General.")
                .font(DS.Typography.interface(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("End tutorial") { guidedTutorialController.endTutorial() }
                    .dsPrimaryButtonStyle()
            }
        }
        .mainAppCard()
    }
}

