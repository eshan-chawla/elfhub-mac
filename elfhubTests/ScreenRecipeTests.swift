//
//  ScreenRecipeTests.swift
//  elfhubTests
//
//  Remembering how a run did something: after a run of three or more
//  steps that ended on its own with no failures, the elf (if it takes
//  notes) keeps the request and the steps in files/screen-recipes/<app>.md,
//  newest first, the same request replaced rather than repeated, at most
//  eight per app.
//

import Foundation
import Testing
@testable import elfhub

struct ScreenRecipeTests {

    private let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyRunsThatWorkedAreRemembered() {
        #expect(ScreenRecipeNotes.shouldRemember(performedStepCount: 4, endedEarly: false, lastRoundHadFailure: false, takesNotes: true))
        #expect(!ScreenRecipeNotes.shouldRemember(performedStepCount: 2, endedEarly: false, lastRoundHadFailure: false, takesNotes: true))
        #expect(!ScreenRecipeNotes.shouldRemember(performedStepCount: 4, endedEarly: true, lastRoundHadFailure: false, takesNotes: true))
        #expect(!ScreenRecipeNotes.shouldRemember(performedStepCount: 4, endedEarly: false, lastRoundHadFailure: true, takesNotes: true))
        #expect(!ScreenRecipeNotes.shouldRemember(performedStepCount: 4, endedEarly: false, lastRoundHadFailure: false, takesNotes: false))
    }

    @Test func eachAppHasItsOwnNote() {
        #expect(ScreenRecipeNotes.notePath(forApplicationName: "System Settings") == "files/screen-recipes/system-settings.md")
        #expect(ScreenRecipeNotes.notePath(forApplicationName: "Numbers ✨") == "files/screen-recipes/numbers.md")
        #expect(ScreenRecipeNotes.notePath(forApplicationName: "✨") == "files/screen-recipes/app.md")
    }

    @Test func recipesAreKeptNewestFirstWithoutRepeats() {
        let firstNote = ScreenRecipeNotes.updatedNote(
            existingText: nil,
            applicationName: "Numbers",
            request: "export my budget\nas a PDF",
            stepDescriptions: ["click “File”", "click “Export To”", "click “PDF…”"],
            date: firstDate
        )
        #expect(firstNote.hasPrefix("# How I did things in Numbers"))
        #expect(firstNote.contains("## export my budget as a PDF"))
        #expect(firstNote.contains("1. click “File”\n2. click “Export To”\n3. click “PDF…”"))

        let secondNote = ScreenRecipeNotes.updatedNote(
            existingText: firstNote,
            applicationName: "Numbers",
            request: "add a sheet",
            stepDescriptions: ["click “+”", "type 6 characters", "press return"],
            date: firstDate.addingTimeInterval(60)
        )
        let addSheetPosition = secondNote.range(of: "## add a sheet")!.lowerBound
        let exportPosition = secondNote.range(of: "## export my budget as a PDF")!.lowerBound
        #expect(addSheetPosition < exportPosition)

        // The same request again replaces the old recipe.
        let thirdNote = ScreenRecipeNotes.updatedNote(
            existingText: secondNote,
            applicationName: "Numbers",
            request: "Export my budget as a PDF",
            stepDescriptions: ["press cmd+p", "click “PDF”", "click “Save as PDF”"],
            date: firstDate.addingTimeInterval(120)
        )
        #expect(thirdNote.components(separatedBy: "budget as a PDF").count == 2)
        #expect(thirdNote.contains("press cmd+p"))
        #expect(!thirdNote.contains("click “Export To”"))
    }

    @Test func atMostEightRecipesPerApp() {
        var noteText: String?
        for requestNumber in 1...12 {
            noteText = ScreenRecipeNotes.updatedNote(
                existingText: noteText,
                applicationName: "Safari",
                request: "task \(requestNumber)",
                stepDescriptions: ["a", "b", "c"],
                date: firstDate.addingTimeInterval(Double(requestNumber))
            )
        }
        let recipeCount = noteText!.components(separatedBy: "\n## ").count - 1
        #expect(recipeCount == ScreenRecipeNotes.maximumRecipesPerApp)
        #expect(noteText!.contains("## task 12"))
        #expect(!noteText!.contains("## task 4\n"))
    }
}
