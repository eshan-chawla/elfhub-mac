//
//  ComputerUseContextPruner.swift
//  elfhub
//
//  Keeps a long run on the screen from re-sending every screenshot it ever
//  took. Each round of a run adds a screenshot (and the window's controls
//  list) to the conversation, and every later round sends the whole
//  conversation again — so without this, a run's cost grows with the
//  square of its steps and a 100-step run outgrows the model's context.
//
//  Only the newest few screenshots stay; older ones become a short note
//  (the step's text result stays, so the model still knows what each step
//  did). Pruning happens in batches — once `screenshotCountThatTriggersPruning`
//  screenshots have built up, back down to `screenshotsKeptInFull` — so
//  between prunes the start of every request stays byte-for-byte the same
//  and the provider's prompt cache keeps working. Tool calls and their
//  results are never removed, so every call stays answered.
//

import Foundation

enum ComputerUseContextPruner {
    /// Screenshots kept in full after a prune: the newest ones, which the
    /// model needs to see where things are now.
    static let screenshotsKeptInFull = 3
    /// Pruning starts once this many screenshots are in the conversation.
    static let screenshotCountThatTriggersPruning = 7

    static let removedScreenshotNote = "(this step's screenshot was removed to save space; newer screenshots follow.)"
    static let removedControlsListNote = "(this step's list of controls was removed to save space.)"
    static let removedQuestionScreenshotNote = "(the screenshot sent with the question was removed to save space; newer screenshots follow.)"

    /// How many screenshots (images in the question, or in step results)
    /// the conversation holds.
    static func screenshotCount(in messages: [LanguageModelMessage]) -> Int {
        messages.reduce(0) { runningCount, message in
            runningCount + message.content.reduce(0) { blockCount, block in
                blockCount + (blockHoldsScreenshot(block) ? 1 : 0)
            }
        }
    }

    /// The conversation with its oldest screenshots replaced by notes, when
    /// enough have built up; otherwise unchanged (so the start of the next
    /// request is the same as this one's).
    static func prunedMessages(_ messages: [LanguageModelMessage]) -> [LanguageModelMessage] {
        let currentScreenshotCount = screenshotCount(in: messages)
        guard currentScreenshotCount >= screenshotCountThatTriggersPruning else { return messages }
        var screenshotsLeftToRemove = currentScreenshotCount - screenshotsKeptInFull

        var prunedMessages: [LanguageModelMessage] = []
        prunedMessages.reserveCapacity(messages.count)
        for message in messages {
            guard screenshotsLeftToRemove > 0 else {
                prunedMessages.append(message)
                continue
            }
            var prunedContent: [LanguageModelContentBlock] = []
            prunedContent.reserveCapacity(message.content.count)
            for block in message.content {
                guard screenshotsLeftToRemove > 0, blockHoldsScreenshot(block) else {
                    prunedContent.append(block)
                    continue
                }
                screenshotsLeftToRemove -= 1
                prunedContent.append(blockWithScreenshotRemoved(block))
            }
            prunedMessages.append(LanguageModelMessage(role: message.role, content: prunedContent))
        }
        return prunedMessages
    }

    private static func blockHoldsScreenshot(_ block: LanguageModelContentBlock) -> Bool {
        switch block {
        case .image:
            return true
        case let .computerToolResult(computerToolResult):
            return computerToolResult.image != nil
        default:
            return false
        }
    }

    private static func blockWithScreenshotRemoved(_ block: LanguageModelContentBlock) -> LanguageModelContentBlock {
        switch block {
        case .image:
            return .text(removedQuestionScreenshotNote)
        case let .computerToolResult(computerToolResult):
            // The controls list described that screenshot; without it, its
            // points mean nothing and it's the biggest text in the result.
            let resultTextWithoutControls = resultTextWithControlsListRemoved(computerToolResult.resultText)
            return .computerToolResult(LanguageModelComputerToolResult(
                toolCallIdentifier: computerToolResult.toolCallIdentifier,
                toolName: computerToolResult.toolName,
                resultText: resultTextWithoutControls + "\n\n" + removedScreenshotNote,
                image: nil,
                isError: computerToolResult.isError,
                toolsetName: computerToolResult.toolsetName
            ))
        default:
            return block
        }
    }

    /// A step's text without the window's controls list
    /// (`AccessibilitySnapshotFormatter`), which is appended after a blank line.
    static func resultTextWithControlsListRemoved(_ resultText: String) -> String {
        let controlsListStart = "\n\n" + AccessibilitySnapshotFormatter.controlsListIntroduction
        guard let controlsListRange = resultText.range(of: controlsListStart) else { return resultText }
        let textBeforeControlsList = String(resultText[..<controlsListRange.lowerBound])
        return textBeforeControlsList + "\n\n" + removedControlsListNote
    }
}
