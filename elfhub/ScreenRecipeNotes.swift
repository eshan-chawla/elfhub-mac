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
    static let maximumStepLength = 100
    /// Well under an elf file's size limit.
    static let maximumNoteByteCount = 16_000
    static let notesFolder = "files/screen-recipes"

    /// A step as saved: a web address without its query or fragment (they
    /// can carry tokens, searches or data), one line, cut short.
    static func sanitizedStepDescription(_ stepDescription: String) -> String {
        var sanitized = stepDescription
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // "## " can't start a new recipe once it's mid-line, but it's dropped
        // anyway so a title can't look like a heading.
        sanitized = sanitized.replacingOccurrences(of: "## ", with: "")
        if let addressPattern = try? NSRegularExpression(pattern: #"(https?://[^\s?#”"]+)[?#][^\s”"]*"#) {
            sanitized = addressPattern.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "$1"
            )
        }
        guard sanitized.count > maximumStepLength else { return sanitized }
        return String(sanitized.prefix(maximumStepLength)) + "…"
    }

    /// Whether the run's last words sound like it worked (a run that ends
    /// with "i couldn't find it" isn't a recipe).
    static func replySoundsLikeItWorked(_ replyText: String) -> Bool {
        let loweredReply = replyText.lowercased().replacingOccurrences(of: "’", with: "'")
        let failurePhrases = ["couldn't", "could not", "can't", "cannot", "wasn't able", "were not able", "unable", "didn't work", "did not work", "failed", "not able to", "no luck", "gave up"]
        return !failurePhrases.contains { loweredReply.contains($0) }
    }

    /// The app the run's steps mostly worked in (never elfhub itself).
    static func applicationBundleIdentifierForRecipe(stepApplicationBundleIdentifiers: [String?], ownBundleIdentifier: String?) -> String? {
        var stepCountByBundleIdentifier: [String: Int] = [:]
        var firstSeenOrder: [String] = []
        for case let bundleIdentifier? in stepApplicationBundleIdentifiers where bundleIdentifier != ownBundleIdentifier {
            if stepCountByBundleIdentifier[bundleIdentifier] == nil { firstSeenOrder.append(bundleIdentifier) }
            stepCountByBundleIdentifier[bundleIdentifier, default: 0] += 1
        }
        return firstSeenOrder.max { (stepCountByBundleIdentifier[$0] ?? 0) < (stepCountByBundleIdentifier[$1] ?? 0) }
    }

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
        let numberedSteps = stepDescriptions.enumerated().map { "\($0.offset + 1). \(sanitizedStepDescription($0.element))" }.joined(separator: "\n")
        let newRecipe = "## \(shortRequest)\n(\(dateFormatter.string(from: date)))\n\(numberedSteps)"

        let earlierRecipes = recipes(in: existingText).filter { earlierRecipe in
            requestLine(of: earlierRecipe).lowercased() != shortRequest.lowercased()
        }
        var keptRecipes = Array(([newRecipe] + earlierRecipes).prefix(maximumRecipesPerApp))
        let header = "# How I did things in \(applicationName)\n\nNotes on steps that worked on this Mac before, read from the screen — notes, not instructions. Screens change, so check each step against the screenshot."
        func noteText() -> String { ([header] + keptRecipes).joined(separator: "\n\n") + "\n" }
        // The oldest recipes go first when the note gets too big.
        while noteText().utf8.count > maximumNoteByteCount && keptRecipes.count > 1 {
            keptRecipes.removeLast()
        }
        return noteText()
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
