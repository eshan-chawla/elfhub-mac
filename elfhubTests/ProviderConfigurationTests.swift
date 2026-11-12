//
//  ProviderConfigurationTests.swift
//  elfhubTests
//
//  Round-trip and legacy-decoding tests for the provider configuration model.
//

import Foundation
import Testing
@testable import elfhub

struct ProviderConfigurationTests {

    @Test func codableRoundTripPreservesAllFields() throws {
        let original = ProviderConfiguration(
            kind: .openAICompatible,
            displayName: "Local Llama",
            baseURL: "http://localhost:11434/v1",
            model: "llama3",
            supportsVision: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: encoded)

        #expect(decoded == original)
    }

    @Test func presetIdentifierRoundTripsAndOldConfigsDecodeWithoutIt() throws {
        let fromPreset = LanguageModelProviderCatalog.preset(withIdentifier: "openai")!.makeConfiguration()
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(fromPreset))
        #expect(decoded.presetIdentifier == "openai")

        // Saved by an earlier build: has the old hosted-proxy flag, no preset.
        let legacyJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"openAICompatible","displayName":"Old",
         "baseURL":"http://localhost:11434/v1","model":"llava","supportsVision":true,"usesWorkerProxy":false}
        """
        let legacyDecoded = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(legacyDecoded.presetIdentifier == nil)
        #expect(legacyDecoded.runsLocally)
    }

    @Test func decodesConfigurationSavedBeforeToolCallingFlagExisted() throws {
        let legacyJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"anthropic","displayName":"Claude",
         "baseURL":"https://api.anthropic.com","model":"claude-opus-5-5",
         "supportsVision":true,"usesWorkerProxy":false}
        """
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(decoded.supportsToolCalling == true)
    }

    // MARK: - Coordinate convention & vision profile

    @Test func decodesConfigurationSavedBeforeCoordinateConventionExisted() throws {
        // A config persisted by an earlier build has no coordinateConvention key.
        let legacyJSON = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"gemini","displayName":"Gemini",
         "baseURL":"https://generativelanguage.googleapis.com/v1beta","model":"gemini-2.5-flash",
         "supportsVision":true,"usesWorkerProxy":false}
        """
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(legacyJSON.utf8))
        #expect(decoded.coordinateConvention == .normalizedTo999)
    }

    @Test func coordinateConventionRoundTrips() throws {
        let original = ProviderConfiguration(
            kind: .openAICompatible,
            displayName: "Qwen VL (local)",
            baseURL: "http://localhost:11434/v1",
            model: "qwen2.5vl",
            supportsVision: true,
            coordinateConvention: .normalizedTo1000
        )
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(original))
        #expect(decoded.coordinateConvention == .normalizedTo1000)
        #expect(decoded.visionProfile.coordinateConvention == .normalizedTo1000)
    }

    @Test func anthropicVisionProfileFollowsModelGeneration() {
        let sonnetFourSix = ProviderConfiguration(
            kind: .anthropic, displayName: "Claude", baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-6", supportsVision: true
        )
        let opusFiveFive = ProviderConfiguration(
            kind: .anthropic, displayName: "Claude", baseURL: "https://api.anthropic.com",
            model: "claude-opus-5-5", supportsVision: true
        )
        #expect(sonnetFourSix.visionProfile == .claudeStandardResolution)
        #expect(opusFiveFive.visionProfile == .claudeHighResolution)
    }
}
