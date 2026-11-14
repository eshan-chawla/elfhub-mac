//
//  MainAppNavigationTests.swift
//  elfhubTests
//
//  The main window opens on chat (the sidebar lists every chat); Settings
//  swaps the sidebar to its categories and "Back" returns to wherever the
//  user came from — the chat or the running tutorial.
//

import Testing
@testable import elfhub

@MainActor
struct MainAppNavigationTests {

    @Test func opensOnChat() {
        #expect(MainAppNavigation().selectedSection == .chat)
    }

    @Test func settingsRemembersWhereYouCameFrom() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.open(.tutorial)
        mainAppNavigation.open(.settings(.privacy))
        #expect(mainAppNavigation.selectedSection == .settings(.privacy))
        #expect(mainAppNavigation.isShowingSettings)

        mainAppNavigation.leaveSettings()
        #expect(mainAppNavigation.selectedSection == .tutorial)
        #expect(!mainAppNavigation.isShowingSettings)
    }

    @Test func leavingSettingsWithoutHistoryGoesToChat() {
        var mainAppNavigation = MainAppNavigation(selectedSection: .settings(.general))
        mainAppNavigation.leaveSettings()
        #expect(mainAppNavigation.selectedSection == .chat)
    }

    @Test func switchingCategoriesKeepsTheReturnPoint() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.open(.settings(.models))
        mainAppNavigation.open(.settings(.modes))
        mainAppNavigation.leaveSettings()
        #expect(mainAppNavigation.selectedSection == .chat)
    }

    @Test func everyCategoryHasATitleAndIcon() {
        let categoryTitles = SettingsCategory.allCases.map(\.displayTitle)
        let categoryIcons = SettingsCategory.allCases.map(\.systemImageName)
        #expect(categoryTitles.allSatisfy { !$0.isEmpty })
        #expect(Set(categoryTitles).count == categoryTitles.count)
        #expect(Set(categoryIcons).count == categoryIcons.count)
        #expect(SettingsCategory.allCases.allSatisfy { !$0.subtitle.isEmpty })
    }

    @Test func settingsBackReturnsToTheElfPage() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.open(.elf("ada"))
        mainAppNavigation.open(.settings(.models))
        mainAppNavigation.leaveSettings()
        #expect(mainAppNavigation.selectedSection == .elf("ada"))
    }

    @Test func anElfPageWhoseElfIsGoneFallsBackToMain() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.open(.elf("ada"))
        mainAppNavigation.showMainElfIfElfIsGone(existingElfIdentifiers: ["main"])
        #expect(mainAppNavigation.selectedSection == .elf("main"))
    }

    @Test func settingsBackDoesNotReturnToAnElfThatIsGone() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.open(.elf("ada"))
        mainAppNavigation.open(.settings(.models))
        mainAppNavigation.showMainElfIfElfIsGone(existingElfIdentifiers: ["main"])
        mainAppNavigation.leaveSettings()
        #expect(mainAppNavigation.selectedSection == .elf("main"))
    }

    @Test func otherPagesAreLeftAloneWhenAnElfIsGone() {
        var mainAppNavigation = MainAppNavigation()
        mainAppNavigation.showMainElfIfElfIsGone(existingElfIdentifiers: ["main"])
        #expect(mainAppNavigation.selectedSection == .chat)
    }

    @Test func settingsNoLongerHasAnElfCategory() {
        #expect(SettingsCategory.allCases.first == .models)
        #expect(!SettingsCategory.allCases.map(\.rawValue).contains("elf"))
    }
}
