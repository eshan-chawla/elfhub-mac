//
//  ScreenActionApprovalTests.swift
//  elfhubTests
//
//  When an Elf asks before acting, per mode — including "Dangerously allow
//  everything", which asks nothing but a background task's first step and
//  is never saved across launches — and where the approval popup sits.
//

import CoreGraphics
import Foundation
import Testing
@testable import elfhub

struct ScreenActionApprovalTests {

    // MARK: - When a run step asks

    @Test func askFirstAsksForTheFirstStepAnotherAppAndAnythingConsequential() {
        let mode = ScreenActionExecutionMode.confirmEachAction
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: false, asksBeforeFirstStep: false, stepLeavesApprovedApplications: false))
        #expect(!mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: true, asksBeforeFirstStep: false, stepLeavesApprovedApplications: false))
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: true, asksBeforeFirstStep: false, stepLeavesApprovedApplications: true))
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: true, isRunApproved: true, asksBeforeFirstStep: false, stepLeavesApprovedApplications: false))
    }

    @Test func autoOnlyAsksForConsequentialStepsAndABackgroundTasksFirstStep() {
        let mode = ScreenActionExecutionMode.autoFire
        #expect(!mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: false, asksBeforeFirstStep: false, stepLeavesApprovedApplications: true))
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: true, isRunApproved: true, asksBeforeFirstStep: false, stepLeavesApprovedApplications: false))
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: false, asksBeforeFirstStep: true, stepLeavesApprovedApplications: false))
    }

    @Test func allowEverythingAsksNothingButABackgroundTasksFirstStep() {
        let mode = ScreenActionExecutionMode.allowEverythingWithoutAsking
        #expect(!mode.stepNeedsApproval(requiresExplicitConfirmation: true, isRunApproved: false, asksBeforeFirstStep: false, stepLeavesApprovedApplications: true))
        #expect(!mode.stepNeedsApproval(requiresExplicitConfirmation: true, isRunApproved: true, asksBeforeFirstStep: true, stepLeavesApprovedApplications: true))
        #expect(mode.stepNeedsApproval(requiresExplicitConfirmation: false, isRunApproved: false, asksBeforeFirstStep: true, stepLeavesApprovedApplications: false),
                "a background task starts while the user may not be watching")
    }

    @Test func oneShotBatchesFireWithoutAskingOnlyWhenTheModeAllows() {
        #expect(!ScreenActionExecutionMode.confirmEachAction.firesBatchWithoutAsking(includesActionNeedingExplicitConfirmation: false))
        #expect(ScreenActionExecutionMode.autoFire.firesBatchWithoutAsking(includesActionNeedingExplicitConfirmation: false))
        #expect(!ScreenActionExecutionMode.autoFire.firesBatchWithoutAsking(includesActionNeedingExplicitConfirmation: true))
        #expect(ScreenActionExecutionMode.allowEverythingWithoutAsking.firesBatchWithoutAsking(includesActionNeedingExplicitConfirmation: true))
    }

    @Test func allowEverythingIsNeverSavedForTheNextLaunch() {
        #expect(ScreenActionExecutionMode.confirmEachAction.isSavedAcrossLaunches)
        #expect(ScreenActionExecutionMode.autoFire.isSavedAcrossLaunches)
        #expect(!ScreenActionExecutionMode.allowEverythingWithoutAsking.isSavedAcrossLaunches)
    }

    @Test func thereIsAMinuteToAnswer() {
        #expect(ScreenActionCoordinator.pendingConsentTimeout == 60)
    }

    // MARK: - Popup placement

    private let visibleScreenFrame = CGRect(x: 0, y: 80, width: 1440, height: 800)
    private let panelSize = CGSize(width: ScreenActionApprovalPanelPlacement.panelWidth, height: 160)

    @Test func thePopupSitsAtTheBottomCenterByDefault() {
        let origin = ScreenActionApprovalPanelPlacement.panelOrigin(panelSize: panelSize, visibleScreenFrame: visibleScreenFrame, targetPoint: nil)
        #expect(origin.x == visibleScreenFrame.midX - panelSize.width / 2)
        #expect(origin.y == visibleScreenFrame.minY + ScreenActionApprovalPanelPlacement.screenEdgeInset)

        let originForTargetAtTheTop = ScreenActionApprovalPanelPlacement.panelOrigin(
            panelSize: panelSize, visibleScreenFrame: visibleScreenFrame, targetPoint: CGPoint(x: 700, y: 820)
        )
        #expect(originForTargetAtTheTop.y == origin.y)
    }

    @Test func thePopupMovesToTheTopWhenTheTargetIsLowOnTheScreen() {
        let origin = ScreenActionApprovalPanelPlacement.panelOrigin(
            panelSize: panelSize, visibleScreenFrame: visibleScreenFrame, targetPoint: CGPoint(x: 700, y: 150)
        )
        #expect(origin.y > visibleScreenFrame.midY)
        #expect(origin.y + panelSize.height <= visibleScreenFrame.maxY)
    }
}
