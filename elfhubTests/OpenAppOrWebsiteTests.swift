//
//  OpenAppOrWebsiteTests.swift
//  elfhubTests
//
//  The direct way to open things during a run: an app by name (found in
//  the Applications folders, ignoring case and ".app") or a web address
//  (http and https only); described plainly for the card and the pill.
//

import Foundation
import Testing
@testable import elfhub

struct OpenAppOrWebsiteTests {

    private func openCall(_ argumentsJSON: String) -> LanguageModelToolCall {
        LanguageModelToolCall(toolCallIdentifier: "call_open", toolName: GuidanceToolDefinitions.openAppOrWebsiteToolName, argumentsJSON: argumentsJSON)
    }

    private func command(_ toolCall: LanguageModelToolCall) -> ComputerUseStepCommand {
        ComputerUseToolCallTranslator.command(for: toolCall, convention: .imagePixels, sentImageSize: CGSize(width: 1280, height: 800))
    }

    @Test func appsAndWebsitesBecomeOpenSteps() throws {
        #expect(ComputerUseToolCallTranslator.isComputerUseCall(openCall("{}")))
        #expect(command(openCall(#"{"app":"Numbers"}"#)) == .act(.openApplication(name: "Numbers"), repeatCount: 1))
        let exampleURL = try #require(URL(string: "https://example.com/pricing"))
        #expect(command(openCall(#"{"website":"https://example.com/pricing"}"#)) == .act(.openWebsite(url: exampleURL), repeatCount: 1))
        // A bare address is taken as https.
        let bareAddressURL = try #require(URL(string: "https://example.com"))
        #expect(command(openCall(#"{"website":"example.com"}"#)) == .act(.openWebsite(url: bareAddressURL), repeatCount: 1))
    }

    @Test func onlyWebAddressesAndOneThingAtATime() {
        func isRefused(_ stepCommand: ComputerUseStepCommand) -> Bool {
            if case .refuse = stepCommand { return true }
            return false
        }
        #expect(isRefused(command(openCall(#"{"website":"file:///etc/passwd"}"#))))
        #expect(isRefused(command(openCall(#"{"website":"javascript:alert(1)"}"#))))
        #expect(isRefused(command(openCall(#"{"app":"Numbers","website":"https://example.com"}"#))))
        #expect(isRefused(command(openCall("{}"))))
    }

    @Test func appsAreFoundByNameInTheApplicationsFolders() throws {
        let applicationsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationsFolder) }
        try FileManager.default.createDirectory(at: applicationsFolder.appendingPathComponent("Visual Studio Code.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationsFolder.appendingPathComponent("Utilities/Terminal.app"), withIntermediateDirectories: true)
        #expect(ApplicationLocator.applicationURL(named: "visual studio code", in: [applicationsFolder])?.lastPathComponent == "Visual Studio Code.app")
        #expect(ApplicationLocator.applicationURL(named: "Terminal.app", in: [applicationsFolder])?.lastPathComponent == "Terminal.app")
        #expect(ApplicationLocator.applicationURL(named: "Pages", in: [applicationsFolder]) == nil)
    }

    @Test func openStepsAreDescribedPlainly() throws {
        #expect(CompanionScreenAction.openApplication(name: "Numbers").humanReadableDescription == "open Numbers")
        let exampleURL = try #require(URL(string: "https://example.com/pricing"))
        // The whole address, so the card shows exactly what would be opened.
        #expect(CompanionScreenAction.openWebsite(url: exampleURL).humanReadableDescription == "open https://example.com/pricing")
    }
}
