//
//  ElfAvatar.swift
//  elfhub
//
//  How an Elf and a person are drawn (brand chapter 07): an Elf is a rounded
//  square with white initials — the main Elf always on Igloo Blue, the
//  brand's and the app icon's blue, a side Elf on one of six avatar colors —
//  or a picture the user chose for it, cut to the same rounded square; a
//  person is a circle on the one neutral person color. The shape tells you
//  at a glance who in a conversation is an agent, and the name is always
//  shown too, so shape is never the only signal.
//

import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The pure rules behind an Elf's avatar: which fill and which initials.
nonisolated enum ElfAvatarAppearance {
    /// How many brand avatar fills side Elfs choose from (`DS.Colors.elfAvatarFills`).
    static let fillCount = 6

    /// The main Elf is always drawn on Igloo Blue (`DS.Colors.mainElfAvatarFill`),
    /// whatever its elf.json says, so the Elf in charge always wears the
    /// brand's color; a picture is the way to give it a face.
    static func usesBrandBlue(elfIdentifier: String) -> Bool {
        elfIdentifier == ElfManager.mainElfIdentifier
    }

    /// Any integer, wrapped into 0..<fillCount.
    static func normalizedFillIndex(_ proposedFillIndex: Int) -> Int {
        ((proposedFillIndex % fillCount) + fillCount) % fillCount
    }

    /// The fill a side Elf's avatar uses: the one the user picked, or one
    /// chosen from its id so it stays the same on every launch and every Mac.
    static func fillIndex(forElfIdentifier elfIdentifier: String, avatarColorIndex: Int?) -> Int {
        if let avatarColorIndex {
            return normalizedFillIndex(avatarColorIndex)
        }
        return normalizedFillIndex(Int(stableHash(of: elfIdentifier) % UInt64(fillCount)))
    }

    /// Up to two initials from a name: the first letter of the first two
    /// words ("Juniper" → "J", "Dr Who" → "DW", "r2-d2" → "RD"). Names
    /// without letters or digits fall back to "E", for Elf.
    static func initials(forName name: String) -> String {
        let nameWords = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let initialLetters = nameWords.prefix(2).compactMap { $0.first }
        guard !initialLetters.isEmpty else { return "E" }
        return String(initialLetters).uppercased()
    }

    /// FNV-1a over the UTF-8 bytes: unlike `hashValue`, the same on every
    /// launch.
    private static func stableHash(of text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - Picture

nonisolated enum ElfAvatarPictureError: LocalizedError, Equatable {
    case unreadableImage
    case fileTooLarge(byteLimit: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That file isn't a picture elfhub can open. Try a PNG, JPEG or HEIC image."
        case let .fileTooLarge(byteLimit):
            return "That picture is larger than \(byteLimit / 1_000_000) MB. Pick a smaller one."
        }
    }
}

/// Turns any picture the user picks into the small square PNG an avatar
/// shows: turned upright, the middle square cut out, scaled to
/// `sideLengthInPixels`. Only that copy is kept, so a huge photo never sits
/// in the Elf's folder or gets decoded at full size for a 22 pt avatar.
nonisolated enum ElfAvatarPicture {
    /// Sharp at the largest avatar (56 pt) on a Retina screen, with room to spare.
    static let sideLengthInPixels = 512
    static let maximumSourceFileByteCount = 50_000_000
    /// The longest side decoded from the source, so a very long panorama
    /// can't make the crop step decode an enormous image.
    private static let maximumDecodedLongSideInPixels = 4_096

    static func squarePNGData(fromImageAt sourceURL: URL) throws -> Data {
        let sourceFileByteCount = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard sourceFileByteCount <= maximumSourceFileByteCount else {
            throw ElfAvatarPictureError.fileTooLarge(byteLimit: maximumSourceFileByteCount)
        }
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ElfAvatarPictureError.unreadableImage
        }
        return try squarePNGData(from: imageSource)
    }

    static func squarePNGData(fromImageData imageData: Data) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw ElfAvatarPictureError.unreadableImage
        }
        return try squarePNGData(from: imageSource)
    }

    private static func squarePNGData(from imageSource: CGImageSource) throws -> Data {
        guard CGImageSourceGetCount(imageSource) > 0,
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let sourcePixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let sourcePixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
              sourcePixelWidth > 0, sourcePixelHeight > 0 else {
            throw ElfAvatarPictureError.unreadableImage
        }

        // Decode just big enough that the middle square is still at least
        // `sideLengthInPixels` wide: the long side scaled by long/short.
        // The thumbnail is turned upright (EXIF orientation) on the way.
        let longSide = Double(max(sourcePixelWidth, sourcePixelHeight))
        let shortSide = Double(min(sourcePixelWidth, sourcePixelHeight))
        let decodedLongSide = min(
            Double(maximumDecodedLongSideInPixels),
            min(longSide, (Double(sideLengthInPixels) * longSide / shortSide).rounded(.up))
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(decodedLongSide),
        ]
        guard let uprightImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            throw ElfAvatarPictureError.unreadableImage
        }

        let squareSideInDecodedPixels = min(uprightImage.width, uprightImage.height)
        let middleSquare = CGRect(
            x: (uprightImage.width - squareSideInDecodedPixels) / 2,
            y: (uprightImage.height - squareSideInDecodedPixels) / 2,
            width: squareSideInDecodedPixels,
            height: squareSideInDecodedPixels
        )
        guard let croppedImage = uprightImage.cropping(to: middleSquare) else {
            throw ElfAvatarPictureError.unreadableImage
        }

        // Small pictures are kept at their own size rather than blown up.
        let outputSideLength = min(sideLengthInPixels, squareSideInDecodedPixels)
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let drawingContext = CGContext(
                data: nil,
                width: outputSideLength,
                height: outputSideLength,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: sRGBColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ElfAvatarPictureError.unreadableImage
        }
        drawingContext.interpolationQuality = .high
        drawingContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: outputSideLength, height: outputSideLength))
        guard let squareImage = drawingContext.makeImage() else {
            throw ElfAvatarPictureError.unreadableImage
        }

        let pngData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(pngData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ElfAvatarPictureError.unreadableImage
        }
        CGImageDestinationAddImage(imageDestination, squareImage, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ElfAvatarPictureError.unreadableImage
        }
        return pngData as Data
    }
}

/// The pictures Elfs wear, read from each Elf's folder once and kept in
/// memory, so every avatar on screen (sidebar, chat, approval popup) shows
/// a new picture the moment it's chosen without reading the file per frame.
@MainActor
final class ElfAvatarPictureStore: ObservableObject {
    static let shared = ElfAvatarPictureStore()

    /// Bumped whenever a picture is chosen or removed, so every avatar
    /// watching the store draws again.
    @Published private(set) var revision = 0

    /// Keyed by the picture file's path; nil remembers "no picture" so a
    /// missing file isn't looked for again on every redraw. Not published:
    /// avatars fill it lazily while they draw.
    private var cachedPicturesByFilePath: [String: NSImage?] = [:]

    func picture(for home: ElfHome) -> NSImage? {
        let pictureFilePath = home.avatarPictureURL.path
        if let cachedPicture = cachedPicturesByFilePath[pictureFilePath] {
            return cachedPicture
        }
        let loadedPicture = NSImage(contentsOf: home.avatarPictureURL)
        cachedPicturesByFilePath[pictureFilePath] = loadedPicture
        return loadedPicture
    }

    func pictureDidChange(for home: ElfHome) {
        cachedPicturesByFilePath[home.avatarPictureURL.path] = nil
        revision += 1
    }
}

// MARK: - Views

/// An Elf's avatar: its picture, or white initials on Igloo Blue (the main
/// Elf) or one of six brand avatar colors (side Elfs), on a rounded square.
/// Sizes are 24, 32 (the default) and 48 pt and up.
struct ElfAvatar: View {
    let name: String
    let fillColor: Color
    /// Where the Elf's picture would be; nil for avatars of Elfs that don't
    /// exist yet (a starter template, a new Elf being named).
    let homeWithPicture: ElfHome?
    var size: CGFloat = 32

    @ObservedObject private var pictureStore = ElfAvatarPictureStore.shared

    /// A side Elf's initials on one of the six fills, without a picture.
    init(name: String, fillIndex: Int, size: CGFloat = 32) {
        self.name = name
        self.fillColor = DS.Colors.elfAvatarFills[ElfAvatarAppearance.normalizedFillIndex(fillIndex)]
        self.homeWithPicture = nil
        self.size = size
    }

    /// The avatar for an Elf on the roster. `displayedName` shows a name
    /// that's still being typed (onboarding) instead of the saved one.
    init(elf: Elf, displayedName: String? = nil, size: CGFloat = 32) {
        self.name = displayedName ?? elf.configuration.identity.name
        if ElfAvatarAppearance.usesBrandBlue(elfIdentifier: elf.id) {
            self.fillColor = DS.Colors.mainElfAvatarFill
        } else {
            let fillIndex = ElfAvatarAppearance.fillIndex(
                forElfIdentifier: elf.id,
                avatarColorIndex: elf.configuration.identity.avatarColorIndex
            )
            self.fillColor = DS.Colors.elfAvatarFills[fillIndex]
        }
        self.homeWithPicture = elf.home
        self.size = size
    }

    var body: some View {
        // Bigger things get rounder corners: 6 pt at 24, 8 pt at 32, 12 pt at 48.
        let avatarShape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        Group {
            if let homeWithPicture, let picture = pictureStore.picture(for: homeWithPicture) {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(avatarShape)
                    // A hairline keeps a light photo's edge visible on a light page.
                    .overlay(avatarShape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
            } else {
                Text(ElfAvatarAppearance.initials(forName: name))
                    .font(DS.Typography.interface(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: size, height: size)
                    .background(avatarShape.fill(fillColor))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), an Elf")
    }
}

/// "Choose picture…" / "Remove picture" for one Elf's avatar. Works for the
/// main Elf and side Elfs alike; the picture is saved in the Elf's folder
/// (`ElfHome.avatarPictureURL`) and every avatar of it updates at once.
struct ElfAvatarPictureButtons: View {
    let elfIdentifier: String
    @ObservedObject var elfManager: ElfManager

    @ObservedObject private var pictureStore = ElfAvatarPictureStore.shared
    @State private var isSavingPicture = false
    @State private var errorMessage: String?

    private var elfHome: ElfHome? { elfManager.elf(withIdentifier: elfIdentifier)?.home }

    private var hasPicture: Bool {
        guard let elfHome else { return false }
        return pictureStore.picture(for: elfHome) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(hasPicture ? "Change picture…" : "Choose picture…", action: choosePicture)
                    .dsSecondaryButtonStyle(size: .small)
                    .disabled(isSavingPicture)
                if hasPicture {
                    Button("Remove picture", action: removePicture)
                        .dsGhostButtonStyle(size: .small)
                        .disabled(isSavingPicture)
                }
                if isSavingPicture {
                    ProgressView().controlSize(.small)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choosePicture() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a picture for your Elf"
        openPanel.prompt = "Use Picture"
        openPanel.allowedContentTypes = [.image]
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let pictureURL = openPanel.url else { return }
        isSavingPicture = true
        errorMessage = nil
        Task {
            defer { isSavingPicture = false }
            do {
                let elfEditor = try ElfEditor(elfIdentifier: elfIdentifier, elfManager: elfManager)
                try await elfEditor.updateAvatarPicture(fromImageAt: pictureURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removePicture() {
        do {
            let elfEditor = try ElfEditor(elfIdentifier: elfIdentifier, elfManager: elfManager)
            try elfEditor.removeAvatarPicture()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A person's avatar: a circle on the neutral person color.
struct PersonAvatar: View {
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(DS.Colors.personAvatarFill))
            .accessibilityLabel("You")
    }
}
