//
//  ElfPackageTests.swift
//  elfhubTests
//
//  .elf files: the manifest, and the checks an import makes before anything
//  touches disk — one test per way a file is refused (damaged, too big, a
//  zip bomb, paths that escape, links, duplicates, a missing or newer
//  manifest, a wrong checksum), plus junk macOS adds being ignored.
//

import CryptoKit
import Foundation
import Testing
@testable import elfhub

struct ElfPackageTests {

    // MARK: Building test packages

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let soulData = Data("# soul\n\nbe kind".utf8)

    private func manifest(entries: [(path: String, data: Data)], formatVersion: Int = ElfPackageManifest.currentFormatVersion) -> ElfPackageManifest {
        ElfPackageManifest(
            format: ElfPackageManifest.formatIdentifier,
            formatVersion: formatVersion,
            createdBy: "elfhub test",
            elf: ElfPackageIdentity(id: "juniper", name: "Juniper", emoji: "🧝", description: "helps"),
            entries: entries.map { ElfPackageEntry(path: $0.path, size: $0.data.count, sha256: sha256Hex($0.data)) },
            includesChats: false,
            includesProfile: true,
            totals: ElfPackageTotals(entryCount: entries.count, byteCount: entries.reduce(0) { $0 + $1.data.count })
        )
    }

    private func package(
        files: [(path: String, data: Data)],
        manifestEntries: [(path: String, data: Data)]? = nil,
        formatVersion: Int = ElfPackageManifest.currentFormatVersion,
        includesManifest: Bool = true,
        allowingAnyCompressionRatio: Bool = false
    ) throws -> Data {
        var archiveFiles = files.map { ElfArchiveFileToWrite(path: $0.path, data: $0.data) }
        if includesManifest {
            let manifestData = try JSONEncoder().encode(manifest(entries: manifestEntries ?? files, formatVersion: formatVersion))
            archiveFiles.insert(ElfArchiveFileToWrite(path: ElfPackageManifest.fileName, data: manifestData), at: 0)
        }
        return try ElfArchive.zipData(files: archiveFiles, allowingAnyCompressionRatio: allowingAnyCompressionRatio)
    }

    private func validPackage() throws -> Data {
        try package(files: [("elf/soul.md", soulData), ("elf/elf.json", Data(#"{"identity":{"name":"Juniper"}}"#.utf8))])
    }

    /// Changes bytes in the central directory entry for `path`.
    private func patchingCentralDirectory(of zipData: Data, forPath path: String, change: (inout Data, Int) -> Void) -> Data {
        var patchedData = zipData
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        var searchStart = patchedData.startIndex
        while let signatureRange = patchedData.range(of: signature, in: searchStart..<patchedData.endIndex) {
            let headerOffset = signatureRange.lowerBound
            let nameLength = Int(patchedData[headerOffset + 28]) | Int(patchedData[headerOffset + 29]) << 8
            let name = String(decoding: patchedData[(headerOffset + 46)..<(headerOffset + 46 + nameLength)], as: UTF8.self)
            if name == path {
                change(&patchedData, headerOffset)
                return patchedData
            }
            searchStart = signatureRange.upperBound
        }
        return patchedData
    }

    private func rejection(_ packageData: Data) -> ElfImportRejection? {
        do {
            _ = try ElfImportValidator.validate(packageData: packageData)
            return nil
        } catch let importRejection as ElfImportRejection {
            return importRejection
        } catch {
            return .notAnElfFile
        }
    }

    // MARK: Manifest

    @Test func theManifestRoundTrips() throws {
        let packageManifest = manifest(entries: [("elf/soul.md", soulData)])
        #expect(try JSONDecoder().decode(ElfPackageManifest.self, from: JSONEncoder().encode(packageManifest)) == packageManifest)
    }

    // MARK: Accepted

    @Test func aValidPackageIsAccepted() throws {
        let validatedPackage = try ElfImportValidator.validate(packageData: try validPackage())
        #expect(validatedPackage.manifest.elf.name == "Juniper")
        #expect(validatedPackage.files.map(\.path).sorted() == ["elf/elf.json", "elf/soul.md"])
        #expect(validatedPackage.files.first { $0.path == "elf/soul.md" }?.data == soulData)
    }

    @Test func junkMacOSAddsIsIgnored() throws {
        let files: [(path: String, data: Data)] = [("elf/soul.md", soulData)]
        var archiveFiles = [ElfArchiveFileToWrite(path: ElfPackageManifest.fileName, data: try JSONEncoder().encode(manifest(entries: files)))]
        archiveFiles += files.map { ElfArchiveFileToWrite(path: $0.path, data: $0.data) }
        archiveFiles.append(ElfArchiveFileToWrite(path: "__MACOSX/elf/._soul.md", data: Data([0, 1])))
        archiveFiles.append(ElfArchiveFileToWrite(path: "elf/.DS_Store", data: Data([0, 1])))
        let validatedPackage = try ElfImportValidator.validate(packageData: try ElfArchive.zipData(files: archiveFiles))
        #expect(validatedPackage.files.map(\.path) == ["elf/soul.md"])
    }

    // MARK: Refused

    @Test func notAZipIsRefused() {
        #expect(rejection(Data("hello".utf8)) == .notAnElfFile)
    }

    @Test func anEarlyTestBuildExportIsRefusedClearly() throws {
        let earlyExport = try ElfArchive.zipData(files: [ElfArchiveFileToWrite(path: "elf.json", data: Data("{}".utf8))])
        #expect(rejection(earlyExport) == .madeByAnEarlyTestBuild)
    }

    @Test func aMissingManifestIsRefused() throws {
        #expect(rejection(try package(files: [("elf/soul.md", soulData)], includesManifest: false)) == .missingOrDamagedManifest)
    }

    @Test func aNewerFormatIsRefused() throws {
        #expect(rejection(try package(files: [("elf/soul.md", soulData)], formatVersion: 99)) == .madeByANewerElfhub)
    }

    @Test func pathsThatEscapeAreRefused() throws {
        for escapingPath in ["/etc/passwd", "elf/../../evil.md", "elf\\evil.md", "elf/bad\u{0007}name.md", "elf//double.md"] {
            #expect(rejection(try package(files: [(escapingPath, soulData)])) == .unsafePath(escapingPath), "\(escapingPath)")
        }
    }

    @Test func tooDeepPathsAreRefused() throws {
        let deepPath = "elf/" + Array(repeating: "d", count: 13).joined(separator: "/") + "/x.md"
        #expect(rejection(try package(files: [(deepPath, soulData)])) == .unsafePath(deepPath))
    }

    @Test func namesOutsideTheLayoutAreRefused() throws {
        #expect(rejection(try package(files: [("payload.sh", soulData)])) == .unexpectedEntry("payload.sh"))
        #expect(rejection(try package(files: [("chats/not-a-uuid.json", soulData)])) == .unexpectedEntry("chats/not-a-uuid.json"))
    }

    @Test func caseFoldDuplicatesAreRefused() throws {
        #expect(rejection(try package(files: [("elf/files/Notes.md", soulData), ("elf/files/notes.md", soulData)])) == .duplicateEntry("elf/files/notes.md"))
    }

    @Test func linksAreRefused() throws {
        let linkedPackage = patchingCentralDirectory(of: try validPackage(), forPath: "elf/soul.md") { zipData, headerOffset in
            // External attributes, high 16 bits: a symbolic link (0o120777).
            let linkAttributes = UInt32(0o120777) << 16
            for byteIndex in 0..<4 { zipData[headerOffset + 38 + byteIndex] = UInt8((linkAttributes >> (8 * UInt32(byteIndex))) & 0xFF) }
        }
        #expect(rejection(linkedPackage) == .unsupportedEntry("elf/soul.md"))
    }

    @Test func encryptedEntriesAreRefused() throws {
        let encryptedPackage = patchingCentralDirectory(of: try validPackage(), forPath: "elf/soul.md") { zipData, headerOffset in
            zipData[headerOffset + 8] |= 0x01
        }
        #expect(rejection(encryptedPackage) == .unsupportedEntry("elf/soul.md"))
    }

    @Test func zipBombsAreRefused() throws {
        let highlyCompressibleData = Data(count: 3 * 1024 * 1024)
        #expect(rejection(try package(files: [("elf/files/zeros.md", highlyCompressibleData)], allowingAnyCompressionRatio: true)) == .tooLarge)
    }

    @Test func oversizedFilesAreRefused() throws {
        var randomBytes = Data(count: ElfImportValidator.maximumFileBytes + 1)
        randomBytes.withUnsafeMutableBytes { buffer in
            for byteIndex in buffer.indices { buffer[byteIndex] = UInt8.random(in: 0...255) }
        }
        #expect(rejection(try package(files: [("elf/files/big.bin", randomBytes)])) == .tooLarge)
    }

    @Test func tooManyEntriesAreRefused() throws {
        let manyFiles = (0...ElfImportValidator.maximumEntryCount).map { fileNumber in ("elf/files/\(fileNumber).md", Data("x".utf8)) }
        #expect(rejection(try package(files: manyFiles)) == .tooManyEntries)
    }

    @Test func checksumMismatchesAreRefused() throws {
        let lyingPackage = try package(files: [("elf/soul.md", soulData)], manifestEntries: [("elf/soul.md", Data("other".utf8))])
        #expect(rejection(lyingPackage) == .checksumMismatch("elf/soul.md"))
    }

    @Test func entriesMissingFromTheManifestAreRefused() throws {
        let packageWithExtra = try package(files: [("elf/soul.md", soulData), ("elf/files/extra.md", soulData)], manifestEntries: [("elf/soul.md", soulData)])
        #expect(rejection(packageWithExtra) == .checksumMismatch("elf/files/extra.md"))
    }

    // MARK: Review fixes

    @Test func namesThatLandOnTheAppsOwnFilesAreRefused() throws {
        for trickPath in ["elf/ access.json", "elf/\u{00A0}.elfhub/tasks/x.json", "elf/acce\u{017F}s.json", "elf/acce\u{00DF}.json", "elf/access.json", "elf/.elfhub/tasks/x.json", "elf/files/ trailing /x.md"] {
            #expect(rejection(try package(files: [(trickPath, soulData)])) != nil, "\(trickPath)")
        }
        // Only the elf's own parts are allowed at the top of elf/.
        #expect(rejection(try package(files: [("elf/notes.md", soulData)])) == .unexpectedEntry("elf/notes.md"))
    }

    @Test func entriesThatOverlapOrLieAboutTheirSizeAreRefused() throws {
        let twoFilePackage = try package(files: [("elf/soul.md", soulData), ("elf/files/a.md", Data("hello".utf8))])
        let overlappingPackage = patchingCentralDirectory(of: twoFilePackage, forPath: "elf/files/a.md") { zipData, headerOffset in
            for byteIndex in 0..<4 { zipData[headerOffset + 42 + byteIndex] = 0 }
        }
        #expect(rejection(overlappingPackage) != nil)
        let lyingPackage = patchingCentralDirectory(of: twoFilePackage, forPath: "elf/files/a.md") { zipData, headerOffset in
            zipData[headerOffset + 20] = 0xFF
            zipData[headerOffset + 21] = 0xFF
        }
        #expect(rejection(lyingPackage) != nil)
    }

    @Test func namesWithJoinersAreAllowedButControlCharactersAreNot() {
        #expect(ElfImportValidator.isSafePath("elf/files/👩‍💻 notes.md"))
        #expect(!ElfImportValidator.isSafePath("elf/files/bad\u{0007}.md"))
    }

    @Test func duplicatesThatTheDiskWouldMergeAreRefused() throws {
        #expect(rejection(try package(files: [("elf/files/cafe\u{0301}.md", soulData), ("elf/files/caf\u{00E9}.md", soulData)])) != nil)
    }
}
