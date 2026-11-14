//
//  ElfScreenHolderTests.swift
//  elfhubTests
//
//  One elf at a time holds the screen: whoever the user is talking to (the
//  main elf by default, a side elf called by name). Only it gets the
//  pointing and acting tools, the pill names it while it acts, and Esc
//  hands the screen back to the main elf.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
struct ElfScreenHolderTests {

    @Test func theScreenFollowsWhoTheUserIsTalkingTo() {
        var elfScreenHolder = ElfScreenHolder()
        #expect(elfScreenHolder.elfIdentifier == ElfManager.mainElfIdentifier)
        let changedToJuniper = elfScreenHolder.beginTurn(answeredBy: "juniper")
        #expect(changedToJuniper)
        #expect(elfScreenHolder.elfIdentifier == "juniper")
        let changedAgain = elfScreenHolder.beginTurn(answeredBy: "juniper")
        #expect(!changedAgain)
        let changedBackToMain = elfScreenHolder.beginTurn(answeredBy: nil)
        #expect(changedBackToMain)
        #expect(elfScreenHolder.elfIdentifier == ElfManager.mainElfIdentifier)
    }

    @Test func onlyTheScreenHolderGetsGuidanceTools() {
        var elfScreenHolder = ElfScreenHolder()
        elfScreenHolder.beginTurn(answeredBy: "juniper")
        #expect(elfScreenHolder.mayUseGuidanceTools(elfIdentifier: "juniper"))
        #expect(!elfScreenHolder.mayUseGuidanceTools(elfIdentifier: ElfManager.mainElfIdentifier))
        #expect(!elfScreenHolder.mayUseGuidanceTools(elfIdentifier: "writer"))
    }

    @Test func escReturnsTheScreenToMain() {
        var elfScreenHolder = ElfScreenHolder()
        elfScreenHolder.beginTurn(answeredBy: "juniper")
        let returned = elfScreenHolder.returnToMainElf()
        #expect(returned)
        #expect(elfScreenHolder.elfIdentifier == ElfManager.mainElfIdentifier)
        let returnedAgain = elfScreenHolder.returnToMainElf()
        #expect(!returnedAgain)
    }

    @Test func thePillNamesTheElfThatIsActing() {
        #expect(ScreenGuidanceOverlayModel.actingSummary("clicking Save", screenHolderElfName: "Juniper") == "Juniper is acting: clicking Save")
        #expect(ScreenGuidanceOverlayModel.actingSummary("clicking Save", screenHolderElfName: nil) == "clicking Save")
    }
}
