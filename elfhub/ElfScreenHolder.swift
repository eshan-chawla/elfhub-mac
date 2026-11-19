//
//  ElfScreenHolder.swift
//  elfhub
//
//  Which elf holds the screen — the one allowed to point, annotate and act.
//  It's whoever the user is talking to: the main elf by default, a side elf
//  for the turn it was called by name. One at a time; Esc hands the screen
//  back to the main elf. Background workers never hold it unless the user
//  lets them (phase 5).
//

import Foundation

struct ElfScreenHolder: Equatable {
    private(set) var elfIdentifier = ElfManager.mainElfIdentifier

    /// A turn starts, answered by `answeringElfIdentifier` (nil: the main
    /// elf). Returns true when the screen changed hands.
    @discardableResult
    mutating func beginTurn(answeredBy answeringElfIdentifier: String?) -> Bool {
        let newHolderIdentifier = answeringElfIdentifier ?? ElfManager.mainElfIdentifier
        guard newHolderIdentifier != elfIdentifier else { return false }
        elfIdentifier = newHolderIdentifier
        return true
    }

    /// Esc: the screen goes back to the main elf. Returns true when it
    /// changed hands.
    @discardableResult
    mutating func returnToMainElf() -> Bool {
        beginTurn(answeredBy: nil)
    }

    func mayUseGuidanceTools(elfIdentifier candidateElfIdentifier: String) -> Bool {
        candidateElfIdentifier == elfIdentifier
    }
}
