//
//  Elf.swift
//  elfhub
//
//  The elf is the agent the user talks to. Each elf has a home folder (see
//  ElfHome) holding who it is and what it knows:
//
//    elf.json      its configuration — identity, behaviour, preferred models
//    soul.md       instructions it follows forever (the user writes it; the
//                  elf can only suggest changes)
//    skills/<slug>/SKILL.md  working knowledge, one folder per skill (ElfSkill)
//    profile.md    the user's personal preferences, noted by the elf
//    files/        its own working files
//
//  elfhub runs one elf for now; homes are laid out per elf so switching the
//  main elf, and several elves side by side, can come later.
//

import Foundation

/// An elf and where it lives.
nonisolated struct Elf: Identifiable, Equatable, Sendable {
    /// Also the name of its home folder.
    let id: String
    let home: ElfHome
    var configuration: ElfConfiguration
}

// MARK: - elf.json

/// The elf's configuration, stored as elf.json and carried in exports.
/// Every field decodes with a default, so files from older or newer builds
/// still load.
nonisolated struct ElfConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var identity: Identity
    var behaviour: Behaviour
    /// The setup the elf was used with, so an imported elf can suggest it.
    /// Filled in when exporting. Never holds API keys.
    var preferredModels: PreferredModels?

    nonisolated struct Identity: Codable, Equatable, Sendable {
        var name: String
        /// One emoji the elf goes by in the app; empty for none.
        var emoji: String
        /// A line about what this elf is for.
        var description: String

        init(name: String = "elf", emoji: String = "", description: String = "") {
            self.name = name
            self.emoji = emoji
            self.description = description
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "elf"
            emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? ""
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        }
    }

    nonisolated struct Behaviour: Codable, Equatable, Sendable {
        enum ReplyLength: String, Codable, CaseIterable, Sendable {
            /// Whatever soul.md says (by default: one or two sentences,
            /// longer when asked).
            case followSoul
            case short
            case detailed

            var displayName: String {
                switch self {
                case .followSoul: return "As soul.md says"
                case .short: return "Always short"
                case .detailed: return "Detailed"
                }
            }
        }

        var replyLength: ReplyLength
        /// Free text such as "calm and encouraging"; empty for the soul's tone.
        var tone: String
        /// The language to reply in; empty to answer in the user's language.
        var language: String
        /// Whether the elf may note personal preferences in profile.md.
        var takesNotes: Bool
        /// Whether the elf may save working knowledge as skills.
        var learnsSkills: Bool
        /// Whether the elf may use files outside its home (off by default).
        var fileAccessEnabled: Bool
        /// Whether it may also change those files (off by default).
        var allowsWritingUserFiles: Bool

        init(
            replyLength: ReplyLength = .followSoul,
            tone: String = "",
            language: String = "",
            takesNotes: Bool = true,
            learnsSkills: Bool = true,
            fileAccessEnabled: Bool = false,
            allowsWritingUserFiles: Bool = false
        ) {
            self.replyLength = replyLength
            self.tone = tone
            self.language = language
            self.takesNotes = takesNotes
            self.learnsSkills = learnsSkills
            self.fileAccessEnabled = fileAccessEnabled
            self.allowsWritingUserFiles = allowsWritingUserFiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Behaviour()
            replyLength = (try? container.decodeIfPresent(ReplyLength.self, forKey: .replyLength)) ?? defaults.replyLength
            tone = try container.decodeIfPresent(String.self, forKey: .tone) ?? defaults.tone
            language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
            takesNotes = try container.decodeIfPresent(Bool.self, forKey: .takesNotes) ?? defaults.takesNotes
            learnsSkills = try container.decodeIfPresent(Bool.self, forKey: .learnsSkills) ?? defaults.learnsSkills
            fileAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .fileAccessEnabled) ?? defaults.fileAccessEnabled
            allowsWritingUserFiles = try container.decodeIfPresent(Bool.self, forKey: .allowsWritingUserFiles) ?? defaults.allowsWritingUserFiles
        }
    }

    nonisolated struct PreferredModels: Codable, Equatable, Sendable {
        /// `TranscriptionProviderChoice` raw value.
        var speechToText: String?
        /// `LanguageModelProviderCatalog` preset id, e.g. "anthropic".
        var languageModelPreset: String?
        var languageModelName: String?
        /// `SpeechOutputMode` raw value.
        var voiceOutput: String?
        /// The voice within that output, e.g. an Apple voice identifier.
        var voiceName: String?
    }

    init(
        identity: Identity = Identity(),
        behaviour: Behaviour = Behaviour(),
        preferredModels: PreferredModels? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.identity = identity
        self.behaviour = behaviour
        self.preferredModels = preferredModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        identity = try container.decodeIfPresent(Identity.self, forKey: .identity) ?? Identity()
        behaviour = try container.decodeIfPresent(Behaviour.self, forKey: .behaviour) ?? Behaviour()
        preferredModels = try container.decodeIfPresent(PreferredModels.self, forKey: .preferredModels)
    }
}
