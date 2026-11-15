//
//  ScreenRecipeNotes.swift
//  elfhub
//
//  Remembering how a run did something on the screen. After a run of
//  three or more steps that ended on its own with no failure in its last
//  round, the elf (when it takes notes) keeps the request and the steps
//  that worked — by the real elements' names, typed text only as a length
//  — in its own folder, `files/screen-recipes/<app>.md`. The note shows up
//  in the elf's notes index, and the step-by-step instructions tell it to
//  read the recipe first next time — then still check every step against
//  the screenshot, since screens change. Nothing is replayed blindly.
//  The write goes through the change log, so it's listed under the reply
//  with Undo like any note the elf makes.
//

import Foundation

enum ScreenRecipeNotes {
    static let minimumStepCount = 3
    static let maximumRecipesPerApp = 8
    static let maximumRequestLength = 120
    static let notesFolder = "files/screen-recipes"

    static func shouldRemember(performedStepCount: Int, endedEarly: Bool, lastRoundHadFailure: Bool, takesNotes: Bool) -> Bool {
        takesNotes && !endedEarly && !lastRoundHadFailure && performedStepCount >= minimumStepCount
    }

    /// One note per app, named after it ("System Settings" →
    /// files/screen-recipes/system-settings.md).
    static func notePath(forApplicationName applicationName: String) -> String {
        let lowercasedName = applicationName.lowercased()
        var slug = ""
        for character in lowercasedName {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return "\(notesFolder)/\(slug.isEmpty ? "app" : slug).md"
    }

    /// The app's note with this recipe first; the same request replaces
    /// its old recipe; at most `maximumRecipesPerApp` kept.
    static func updatedNote(
        existingText: String?,
        applicationName: String,
        request: String,
        stepDescriptions: [String],
        date: Date
    ) -> String {
        let oneLineRequest = request
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let shortRequest = oneLineRequest.count > maximumRequestLength
            ? String(oneLineRequest.prefix(maximumRequestLength)) + "…"
            : oneLineRequest

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let numberedSteps = stepDescriptions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let newRecipe = "## \(shortRequest)\n(\(dateFormatter.string(from: date)))\n\(numberedSteps)"

        let earlierRecipes = recipes(in: existingText).filter { earlierRecipe in
            requestLine(of: earlierRecipe).lowercased() != shortRequest.lowercased()
        }
        let keptRecipes = Array(([newRecipe] + earlierRecipes).prefix(maximumRecipesPerApp))
        let header = "# How I did things in \(applicationName)\n\nSteps that worked on this Mac before. Screens change, so check each step against the screenshot."
        return ([header] + keptRecipes).joined(separator: "\n\n") + "\n"
    }

    /// The recipes in a note, each starting with its "## request" line.
    private static func recipes(in noteText: String?) -> [String] {
        guard let noteText else { return [] }
        let parts = ("\n" + noteText).components(separatedBy: "\n## ")
        return parts.dropFirst().map { "## " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func requestLine(of recipe: String) -> String {
        let firstLine = recipe.components(separatedBy: "\n").first ?? ""
        return firstLine.hasPrefix("## ") ? String(firstLine.dropFirst(3)) : firstLine
    }
}
