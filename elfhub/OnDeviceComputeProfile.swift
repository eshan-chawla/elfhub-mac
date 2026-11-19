//
//  OnDeviceComputeProfile.swift
//  elfhub
//
//  What this Mac can comfortably run, for recommending on-device speech
//  models. Memory decides it: on Apple silicon the GPU shares the Mac's
//  memory, and a model has to fit next to everything else the user has open
//  (a local language model in Ollama, the browser, the editor…).
//

import Foundation

nonisolated struct OnDeviceComputeProfile: Equatable, Sendable {
    /// Memory bands the recommendations are written for. The raw value is
    /// the smallest memory (in GB) of the band.
    enum ComputeTier: Int, Comparable, CaseIterable, Sendable {
        /// 8 GB Macs: small, fast models only.
        case compact = 8
        /// 16 GB: mid-size models.
        case standard = 16
        /// 24–48 GB: larger, more natural models.
        case roomy = 24
        /// 64 GB and up: the largest picks.
        case workstation = 64

        static func < (lhs: ComputeTier, rhs: ComputeTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// "Apple M3 Pro", or "Apple silicon" if the name can't be read.
    let chipName: String
    let memoryInGigabytes: Int

    var computeTier: ComputeTier {
        Self.computeTier(forMemoryInGigabytes: memoryInGigabytes)
    }

    /// "Apple M3 Pro · 36 GB"
    var summary: String {
        "\(chipName) · \(memoryInGigabytes) GB"
    }

    /// Whether a model that wants this much memory runs comfortably here.
    func canComfortablyRun(recommendedMemoryInGigabytes: Int) -> Bool {
        memoryInGigabytes >= recommendedMemoryInGigabytes
    }

    static func computeTier(forMemoryInGigabytes memoryInGigabytes: Int) -> ComputeTier {
        if memoryInGigabytes >= ComputeTier.workstation.rawValue { return .workstation }
        if memoryInGigabytes >= ComputeTier.roomy.rawValue { return .roomy }
        if memoryInGigabytes >= ComputeTier.standard.rawValue { return .standard }
        return .compact
    }

    /// This Mac.
    static var current: OnDeviceComputeProfile {
        OnDeviceComputeProfile(
            chipName: currentChipName() ?? "Apple silicon",
            memoryInGigabytes: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        )
    }

    /// The marketing chip name, e.g. "Apple M3 Pro".
    private static func currentChipName() -> String? {
        var nameByteCount = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &nameByteCount, nil, 0) == 0, nameByteCount > 0 else {
            return nil
        }
        var nameBytes = [CChar](repeating: 0, count: nameByteCount)
        guard sysctlbyname("machdep.cpu.brand_string", &nameBytes, &nameByteCount, nil, 0) == 0 else {
            return nil
        }
        let chipName = String(cString: nameBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return chipName.isEmpty ? nil : chipName
    }
}
