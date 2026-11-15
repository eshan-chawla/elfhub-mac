//
//  ElfArchive.swift
//  elfhub
//
//  The small zip writer and reader behind .elf files, on Apple's
//  Compression framework (raw DEFLATE), with no third-party code. Writing:
//  each file stored or deflated (whichever is smaller), with its CRC-32.
//  Reading: entries are listed from the central directory first — names,
//  sizes, method, encryption and symlink flags — so an import can check
//  every entry before anything is extracted; extracting checks the size and
//  the CRC-32. Zip64 and encrypted entries aren't supported.
//

import Compression
import Foundation

nonisolated struct ElfArchiveFileToWrite: Sendable {
    let path: String
    let data: Data
}

nonisolated enum ElfArchiveCompressionMethod: Equatable, Sendable {
    case store
    case deflate
    case other(UInt16)
}

/// One entry, as the central directory describes it.
nonisolated struct ElfArchiveEntry: Equatable, Sendable {
    let path: String
    /// The name's raw bytes, for checking it's valid UTF-8.
    let rawPathBytes: Data
    let compressionMethod: ElfArchiveCompressionMethod
    let compressedSize: Int
    let uncompressedSize: Int
    let crc32: UInt32
    let localHeaderOffset: Int
    let isEncrypted: Bool
    let isSymbolicLink: Bool
    let isDirectory: Bool
    /// Sizes or offsets that need zip64 (not supported).
    let needsZip64: Bool
}

nonisolated enum ElfArchiveError: LocalizedError, Equatable {
    case notAZipFile
    case unsupportedEntry(path: String)
    case damagedEntry(path: String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAZipFile: return "This isn't a .elf file elfhub can read."
        case let .unsupportedEntry(path): return "\(path) is stored in a way elfhub doesn't read."
        case let .damagedEntry(path): return "\(path) is damaged."
        case .tooLarge: return "This file is too large."
        }
    }
}

nonisolated enum ElfArchive {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    // MARK: Writing

    static func zipData(files: [ElfArchiveFileToWrite]) throws -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        for file in files {
            let pathBytes = Data(file.path.utf8)
            let checksum = crc32(of: file.data)
            let deflatedData = deflate(file.data)
            let usesDeflate = deflatedData.map { $0.count < file.data.count } ?? false
            let storedData = usesDeflate ? deflatedData! : file.data
            guard storedData.count < 0xFFFF_FFFF, file.data.count < 0xFFFF_FFFF, zipData.count < 0xFFFF_FFFF else {
                throw ElfArchiveError.tooLarge
            }
            let localHeaderOffset = UInt32(zipData.count)
            let compressionMethod: UInt16 = usesDeflate ? 8 : 0
            // Bit 11: the name is UTF-8.
            let generalPurposeFlags: UInt16 = 1 << 11

            zipData.appendLittleEndian(localFileHeaderSignature)
            zipData.appendLittleEndian(UInt16(20))
            zipData.appendLittleEndian(generalPurposeFlags)
            zipData.appendLittleEndian(compressionMethod)
            zipData.appendLittleEndian(UInt16(0))
            zipData.appendLittleEndian(UInt16(0x21))
            zipData.appendLittleEndian(checksum)
            zipData.appendLittleEndian(UInt32(storedData.count))
            zipData.appendLittleEndian(UInt32(file.data.count))
            zipData.appendLittleEndian(UInt16(pathBytes.count))
            zipData.appendLittleEndian(UInt16(0))
            zipData.append(pathBytes)
            zipData.append(storedData)

            centralDirectory.appendLittleEndian(centralDirectoryHeaderSignature)
            // Made by: Unix (3), spec 2.0; so the permission bits are read.
            centralDirectory.appendLittleEndian(UInt16(0x0314))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(generalPurposeFlags)
            centralDirectory.appendLittleEndian(compressionMethod)
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0x21))
            centralDirectory.appendLittleEndian(checksum)
            centralDirectory.appendLittleEndian(UInt32(storedData.count))
            centralDirectory.appendLittleEndian(UInt32(file.data.count))
            centralDirectory.appendLittleEndian(UInt16(pathBytes.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            // A plain file readable by its owner and others (0644), never executable.
            centralDirectory.appendLittleEndian(UInt32(0o100644) << 16)
            centralDirectory.appendLittleEndian(localHeaderOffset)
            centralDirectory.append(pathBytes)
        }
        guard files.count < 0xFFFF, zipData.count < 0xFFFF_FFFF else { throw ElfArchiveError.tooLarge }
        let centralDirectoryOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)
        zipData.appendLittleEndian(endOfCentralDirectorySignature)
        zipData.appendLittleEndian(UInt16(0))
        zipData.appendLittleEndian(UInt16(0))
        zipData.appendLittleEndian(UInt16(files.count))
        zipData.appendLittleEndian(UInt16(files.count))
        zipData.appendLittleEndian(UInt32(centralDirectory.count))
        zipData.appendLittleEndian(centralDirectoryOffset)
        zipData.appendLittleEndian(UInt16(0))
        return zipData
    }

    // MARK: Reading

    /// Every entry, from the central directory, without extracting any.
    static func entries(in zipData: Data) throws -> [ElfArchiveEntry] {
        guard let endRecordOffset = endOfCentralDirectoryOffset(in: zipData) else { throw ElfArchiveError.notAZipFile }
        let entryCount = Int(zipData.littleEndianUInt16(at: endRecordOffset + 10))
        let centralDirectoryOffset = Int(zipData.littleEndianUInt32(at: endRecordOffset + 16))
        guard entryCount != 0xFFFF, centralDirectoryOffset != 0xFFFF_FFFF, centralDirectoryOffset < zipData.count else {
            throw ElfArchiveError.notAZipFile
        }
        var entries: [ElfArchiveEntry] = []
        var cursor = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= zipData.count,
                  zipData.littleEndianUInt32(at: cursor) == centralDirectoryHeaderSignature else { throw ElfArchiveError.notAZipFile }
            let versionMadeBy = zipData.littleEndianUInt16(at: cursor + 4)
            let generalPurposeFlags = zipData.littleEndianUInt16(at: cursor + 8)
            let methodValue = zipData.littleEndianUInt16(at: cursor + 10)
            let crc32 = zipData.littleEndianUInt32(at: cursor + 16)
            let compressedSize = zipData.littleEndianUInt32(at: cursor + 20)
            let uncompressedSize = zipData.littleEndianUInt32(at: cursor + 24)
            let nameLength = Int(zipData.littleEndianUInt16(at: cursor + 28))
            let extraLength = Int(zipData.littleEndianUInt16(at: cursor + 30))
            let commentLength = Int(zipData.littleEndianUInt16(at: cursor + 32))
            let externalAttributes = zipData.littleEndianUInt32(at: cursor + 38)
            let localHeaderOffset = zipData.littleEndianUInt32(at: cursor + 42)
            guard cursor + 46 + nameLength <= zipData.count else { throw ElfArchiveError.notAZipFile }
            let rawPathBytes = zipData.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let path = String(decoding: rawPathBytes, as: UTF8.self)
            let madeOnUnix = (versionMadeBy >> 8) == 3
            let unixFileType = (externalAttributes >> 16) & 0o170000
            let compressionMethod: ElfArchiveCompressionMethod
            switch methodValue {
            case 0: compressionMethod = .store
            case 8: compressionMethod = .deflate
            default: compressionMethod = .other(methodValue)
            }
            entries.append(ElfArchiveEntry(
                path: path,
                rawPathBytes: rawPathBytes,
                compressionMethod: compressionMethod,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                crc32: crc32,
                localHeaderOffset: Int(localHeaderOffset),
                isEncrypted: generalPurposeFlags & 1 != 0,
                isSymbolicLink: madeOnUnix && unixFileType == 0o120000,
                isDirectory: path.hasSuffix("/") || (madeOnUnix && unixFileType == 0o040000),
                needsZip64: compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// One entry's content, decompressed, checked against its size and CRC-32.
    static func extract(_ entry: ElfArchiveEntry, from zipData: Data) throws -> Data {
        guard !entry.isEncrypted, !entry.needsZip64 else { throw ElfArchiveError.unsupportedEntry(path: entry.path) }
        let localHeaderOffset = entry.localHeaderOffset
        guard localHeaderOffset + 30 <= zipData.count,
              zipData.littleEndianUInt32(at: localHeaderOffset) == localFileHeaderSignature else {
            throw ElfArchiveError.damagedEntry(path: entry.path)
        }
        let nameLength = Int(zipData.littleEndianUInt16(at: localHeaderOffset + 26))
        let extraLength = Int(zipData.littleEndianUInt16(at: localHeaderOffset + 28))
        let contentStart = localHeaderOffset + 30 + nameLength + extraLength
        guard contentStart + entry.compressedSize <= zipData.count else { throw ElfArchiveError.damagedEntry(path: entry.path) }
        let storedContent = zipData.subdata(in: contentStart..<(contentStart + entry.compressedSize))
        let content: Data
        switch entry.compressionMethod {
        case .store:
            content = storedContent
        case .deflate:
            guard let inflatedContent = inflate(storedContent, expectedSize: entry.uncompressedSize) else {
                throw ElfArchiveError.damagedEntry(path: entry.path)
            }
            content = inflatedContent
        case .other:
            throw ElfArchiveError.unsupportedEntry(path: entry.path)
        }
        guard content.count == entry.uncompressedSize, crc32(of: content) == entry.crc32 else {
            throw ElfArchiveError.damagedEntry(path: entry.path)
        }
        return content
    }

    private static func endOfCentralDirectoryOffset(in zipData: Data) -> Int? {
        guard zipData.count >= 22 else { return nil }
        // The record is at the end, after a comment of up to 64 KB.
        let earliestOffset = max(0, zipData.count - 22 - 0xFFFF)
        var offset = zipData.count - 22
        while offset >= earliestOffset {
            if zipData.littleEndianUInt32(at: offset) == endOfCentralDirectorySignature { return offset }
            offset -= 1
        }
        return nil
    }

    // MARK: Compression

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let destinationCapacity = data.count + 1024
        var destination = Data(count: destinationCapacity)
        let compressedSize = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!, destinationCapacity,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard compressedSize > 0 else { return nil }
        return destination.prefix(compressedSize)
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        var destination = Data(count: expectedSize)
        let decompressedSize = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decompressedSize == expectedSize else { return nil }
        return destination
    }

    // MARK: CRC-32

    private static let crc32Table: [UInt32] = (0..<256).map { tableIndex in
        var crcValue = UInt32(tableIndex)
        for _ in 0..<8 {
            crcValue = crcValue & 1 != 0 ? 0xEDB8_8320 ^ (crcValue >> 1) : crcValue >> 1
        }
        return crcValue
    }

    static func crc32(of data: Data) -> UInt32 {
        var crcValue: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crcValue = crc32Table[Int((crcValue ^ UInt32(byte)) & 0xFF)] ^ (crcValue >> 8)
        }
        return crcValue ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { value, byteIndex in
            value | UInt32(self[startIndex + offset + byteIndex]) << (8 * UInt32(byteIndex))
        }
    }
}
