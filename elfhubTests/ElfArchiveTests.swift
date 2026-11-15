//
//  ElfArchiveTests.swift
//  elfhubTests
//
//  The small zip writer and reader behind .elf files: what it writes opens
//  in macOS's own tools, entries are listed from the central directory
//  before anything is extracted, and damaged data is caught.
//

import Foundation
import Testing
@testable import elfhub

struct ElfArchiveTests {

    private let sampleEntries = [
        ElfArchiveFileToWrite(path: "manifest.json", data: Data(#"{"format":"com.elfhub.elf"}"#.utf8)),
        ElfArchiveFileToWrite(path: "elf/soul.md", data: Data(String(repeating: "be kind. ", count: 500).utf8)),
        ElfArchiveFileToWrite(path: "elf/files/empty.md", data: Data()),
    ]

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(ElfArchive.crc32(of: Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func entriesAreListedWithoutExtracting() throws {
        let zipData = try ElfArchive.zipData(files: sampleEntries)
        let listedEntries = try ElfArchive.entries(in: zipData)
        #expect(listedEntries.map(\.path) == ["manifest.json", "elf/soul.md", "elf/files/empty.md"])
        let soulEntry = try #require(listedEntries.first { $0.path == "elf/soul.md" })
        #expect(soulEntry.uncompressedSize == 4_500)
        #expect(soulEntry.compressedSize < soulEntry.uncompressedSize)
        #expect(soulEntry.compressionMethod == .deflate)
        #expect(!soulEntry.isEncrypted)
        #expect(!soulEntry.isSymbolicLink)
    }

    @Test func extractedEntriesMatchWhatWasWritten() throws {
        let zipData = try ElfArchive.zipData(files: sampleEntries)
        for listedEntry in try ElfArchive.entries(in: zipData) {
            let extractedData = try ElfArchive.extract(listedEntry, from: zipData)
            #expect(extractedData == sampleEntries.first { $0.path == listedEntry.path }?.data)
        }
    }

    @Test func crcMismatchIsAnError() throws {
        var zipData = try ElfArchive.zipData(files: [ElfArchiveFileToWrite(path: "a.txt", data: Data("hello there".utf8))])
        let listedEntry = try #require(try ElfArchive.entries(in: zipData).first)
        // Flip a byte of the stored content (stored: too short to deflate well).
        let contentOffset = zipData.count - 1 - 22 - 46 - "a.txt".utf8.count - 3
        zipData[contentOffset] ^= 0xFF
        #expect(throws: ElfArchiveError.self) { _ = try ElfArchive.extract(listedEntry, from: zipData) }
    }

    @Test func writtenArchivesOpenInMacOSsOwnTools() throws {
        let zipData = try ElfArchive.zipData(files: sampleEntries)
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let zipFileURL = workingDirectory.appendingPathComponent("test.zip")
        try zipData.write(to: zipFileURL)
        let unpackedDirectory = workingDirectory.appendingPathComponent("unpacked", isDirectory: true)
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-x", "-k", zipFileURL.path, unpackedDirectory.path]
        try dittoProcess.run()
        dittoProcess.waitUntilExit()
        #expect(dittoProcess.terminationStatus == 0)
        #expect(try Data(contentsOf: unpackedDirectory.appendingPathComponent("elf/soul.md")) == sampleEntries[1].data)
    }

    @Test func archivesMadeByMacOSCanBeRead() throws {
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("elf-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let sourceDirectory = workingDirectory.appendingPathComponent("source/elf", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data(String(repeating: "notes ", count: 300).utf8).write(to: sourceDirectory.appendingPathComponent("notes.md"))
        let zipFileURL = workingDirectory.appendingPathComponent("made-by-ditto.zip")
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-c", "-k", "--norsrc", workingDirectory.appendingPathComponent("source").path, zipFileURL.path]
        try dittoProcess.run()
        dittoProcess.waitUntilExit()
        let zipData = try Data(contentsOf: zipFileURL)
        let notesEntry = try #require(try ElfArchive.entries(in: zipData).first { $0.path == "elf/notes.md" })
        #expect(try ElfArchive.extract(notesEntry, from: zipData) == Data(String(repeating: "notes ", count: 300).utf8))
    }

    @Test func notAZipIsAnError() {
        #expect(throws: ElfArchiveError.self) { _ = try ElfArchive.entries(in: Data("hello".utf8)) }
    }
}
