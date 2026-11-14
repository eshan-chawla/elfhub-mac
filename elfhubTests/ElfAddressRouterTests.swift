//
//  ElfAddressRouterTests.swift
//  elfhubTests
//
//  Which elf the user is talking to. Calling an elf by name — "Juniper, …",
//  "hey Juniper", "ask Juniper to …", "…, Juniper?" or just "Juniper" —
//  goes to that elf; a name mid-sentence, a possessive, or a name that's
//  also an everyday word said without a comma or "hey" stays with main.
//

import Foundation
import Testing
@testable import elfhub

struct ElfAddressRouterTests {

    private let elves: [Elf] = {
        func elf(_ elfIdentifier: String, _ name: String, aliases: [String] = []) -> Elf {
            Elf(
                id: elfIdentifier,
                home: ElfHome(directory: URL(fileURLWithPath: "/tmp/elves-router-tests/\(elfIdentifier)")),
                configuration: ElfConfiguration(identity: .init(name: name, aliases: aliases))
            )
        }
        return [
            elf("main", "Pip"),
            elf("juniper", "Juniper", aliases: ["June"]),
            elf("will", "Will"),
            elf("will-smith", "Will Smith"),
            elf("jose", "José"),
            elf("writer", "Writer"),
            elf("atlas", "Atlas"),
            elf("r2-d2", "R2-D2"),
            elf("doctor", "Dr. Who"),
            elf("darcy", "D’Arcy"),
            elf("computer", "Hal", aliases: ["Computer"]),
        ]
    }()

    private func routedElfIdentifier(_ transcript: String) -> String? {
        ElfAddressRouter.route(transcript: transcript, elves: elves)?.elfIdentifier
    }

    @Test func aLeadingNameWithACommaRoutes() {
        let route = ElfAddressRouter.route(transcript: "Juniper, what's this button?", elves: elves)
        #expect(route?.elfIdentifier == "juniper")
        #expect(route?.textForElf == "what's this button?")
    }

    @Test func aLeadingUncommonNameWithoutACommaRoutes() {
        #expect(routedElfIdentifier("Juniper what's this button") == "juniper")
    }

    @Test func heyNameRoutes() {
        let route = ElfAddressRouter.route(transcript: "hey Juniper can you look at this", elves: elves)
        #expect(route?.elfIdentifier == "juniper")
        #expect(route?.textForElf == "can you look at this")
    }

    @Test func askOrTellNameRoutes() {
        let askRoute = ElfAddressRouter.route(transcript: "ask Juniper to find flights to Lisbon", elves: elves)
        #expect(askRoute?.elfIdentifier == "juniper")
        #expect(askRoute?.textForElf == "find flights to Lisbon")
        #expect(routedElfIdentifier("tell the writer about the launch post") == "writer")
    }

    @Test func aTrailingNameRoutes() {
        let route = ElfAddressRouter.route(transcript: "what's the weather tomorrow, Juniper?", elves: elves)
        #expect(route?.elfIdentifier == "juniper")
        #expect(route?.textForElf == "what's the weather tomorrow?")
    }

    @Test func theNameAloneRoutes() {
        #expect(routedElfIdentifier("Juniper") == "juniper")
        #expect(routedElfIdentifier("Juniper?") == "juniper")
    }

    @Test func fillersBeforeTheNameAreSkipped() {
        #expect(routedElfIdentifier("um, okay Juniper, what's this?") == "juniper")
    }

    @Test func aNameMidSentenceStaysWithMain() {
        #expect(routedElfIdentifier("I think Juniper already did this") == nil)
    }

    @Test func aPossessiveStaysWithMain() {
        #expect(routedElfIdentifier("Juniper's notes are wrong") == nil)
    }

    @Test func commonWordNamesNeedACommaOrHey() {
        #expect(routedElfIdentifier("will you open the file") == nil)
        #expect(routedElfIdentifier("writer draft this") == nil)
        #expect(routedElfIdentifier("Will, open the file") == "will")
        #expect(routedElfIdentifier("hey will open the file") == "will")
    }

    @Test func longestNameWins() {
        #expect(routedElfIdentifier("Will Smith, what's this?") == "will-smith")
        #expect(routedElfIdentifier("hey Will Smith what's this") == "will-smith")
    }

    @Test func aliasesRoute() {
        #expect(routedElfIdentifier("June, what's this?") == "juniper")
    }

    @Test func accentsAndCaseDoNotMatter() {
        #expect(routedElfIdentifier("jose, what's this?") == "jose")
        #expect(routedElfIdentifier("JUNIPER, what's this?") == "juniper")
    }

    @Test func mainsOwnNameStaysWithMain() {
        #expect(routedElfIdentifier("Pip, what's this?") == nil)
        #expect(routedElfIdentifier("what's this button?") == nil)
        #expect(routedElfIdentifier("") == nil)
    }

    @Test func dictationHearsEveryElfsNamesAndAliases() {
        #expect(ElfAddressRouter.dictationKeyterms(for: elves).prefix(7) == ["Pip", "Juniper", "June", "Will", "Will Smith", "José", "Writer"])
    }

    @Test func ordinarySentencesThatStartWithAGreetingStayWithMain() {
        #expect(routedElfIdentifier("Hey, will you open Safari?") == nil)
        #expect(routedElfIdentifier("Hi, may I ask something?") == nil)
        #expect(routedElfIdentifier("Hey, will, open Safari") == "will")
    }

    @Test func talkingAboutAnElfStaysWithMain() {
        #expect(routedElfIdentifier("Juniper is slow today, can you fix her notes?") == nil)
        #expect(routedElfIdentifier("Juniper got it wrong") == nil)
        #expect(routedElfIdentifier("Computer is slow today") == nil)
        #expect(routedElfIdentifier("Atlas Shrugged is a book I like") == nil)
        #expect(routedElfIdentifier("Juniper tells me it's done") == nil)
        #expect(routedElfIdentifier("hey, Juniper got it wrong") == nil)
        #expect(routedElfIdentifier("Juniper open my notes") == "juniper")
    }

    @Test func askOrTellNeedsWhatToAskAbout() {
        #expect(routedElfIdentifier("tell Will I said hi") == nil)
        #expect(routedElfIdentifier("ask Will to check the build") == "will")
        #expect(routedElfIdentifier("ask Juniper whether it's done") == "juniper")
    }

    @Test func aTrailingEverydayWordIsNotAName() {
        #expect(routedElfIdentifier("Is the meeting in May, June?") == nil)
        #expect(routedElfIdentifier("what's this, Juniper?") == "juniper")
    }

    @Test func namesWithPunctuationCanBeCalled() {
        #expect(routedElfIdentifier("R2-D2, open mail") == "r2-d2")
        #expect(routedElfIdentifier("Dr. Who, open mail") == "doctor")
        #expect(routedElfIdentifier("D'Arcy, what's this?") == "darcy")
        #expect(routedElfIdentifier("D’Arcy, what's this?") == "darcy")
    }
}
