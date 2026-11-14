//
//  ElfStarterTemplates.swift
//  elfhub
//
//  Ready-made elves the user can add in onboarding or from the Elves hub's
//  "+" menu, so the main elf isn't alone: a Researcher and a Writer. Each is
//  a name, an emoji, a line about what it's for, and a soul — elfhub's
//  starter soul plus a few lines for its role.
//

import Foundation

nonisolated enum ElfStarterTemplate: String, CaseIterable, Identifiable, Sendable {
    case researcher
    case writer

    var id: String { rawValue }

    var identity: ElfConfiguration.Identity {
        switch self {
        case .researcher:
            return ElfConfiguration.Identity(
                name: "Researcher",
                emoji: "🔎",
                description: "Looks things up and comes back with what it found, and where it found it."
            )
        case .writer:
            return ElfConfiguration.Identity(
                name: "Writer",
                emoji: "✍️",
                description: "Drafts, edits and tidies writing in your voice."
            )
        }
    }

    /// elfhub's starter soul, then the role's own lines.
    var soulText: String {
        switch self {
        case .researcher:
            return ElfHome.starterSoul + """

            ## as a researcher

            - say where each fact came from. if you couldn't check something, say so plainly.
            - separate what you found from what you think.
            - keep longer findings in a file in your files folder and tell the user its name.

            """
        case .writer:
            return ElfHome.starterSoul + """

            ## as a writer

            - match the user's voice and the format they're writing in. ask once if you can't tell.
            - when editing, keep their meaning. say what you changed in a sentence.
            - keep drafts in your files folder so nothing is lost.

            """
        }
    }
}
