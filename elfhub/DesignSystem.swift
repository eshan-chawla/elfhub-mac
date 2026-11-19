//
//  DesignSystem.swift
//  elfhub
//
//  The elfhub brand (brand guide v2, 14 November 2026) as code: the colors
//  in light and dark, the three typefaces and their scale, corner radii,
//  shadows, motion, and the shared controls. Every value here comes from the
//  brand guide's palette.json and chapters 03–07; screens use these tokens
//  instead of their own values so the app stays one system.
//
//  The interface is quiet and neutral: warm greys, plain ink for the main
//  action and the selected thing, no blue chrome. Color is kept for meaning —
//  status (green, amber, red) and the Elf's orange pen on the user's screen.
//
//  Colors follow the system's appearance (brand decision 25): each token is a
//  dynamic color with a light and a dark value, resolved by SwiftUI against
//  the view's color scheme, so `.environment(\.colorScheme, .dark)` gives a
//  view the dark values even when the Mac is in light appearance.
//

import SwiftUI
import AppKit
import CoreText

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Typography.body`, `DS.CornerRadius.card`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Page and surfaces ────────────────────────────────────────
        // Warm neutral greys (no blue cast), light and dark.

        /// The page background behind everything.
        static let background = Color(lightHex: "#FAF9F7", darkHex: "#1F1F1E")

        /// Cards, fields, popovers.
        static let surface1 = Color(lightHex: "#FFFFFF", darkHex: "#262625")

        /// Quiet panels, table headers, inline code, the user's chat bubbles.
        static let surface2 = Color(lightHex: "#F3F2EE", darkHex: "#2D2D2B")

        /// Hover fill on interactive rows and buttons — one step past the muted surface.
        static let surface3 = Color(lightHex: "#ECEAE5", darkHex: "#343432")

        /// Pressed fill on interactive rows and buttons.

        /// The sidebar: a step off the page, following the appearance.
        static let sidebar = Color(lightHex: "#F3F1EC", darkHex: "#262624")

        /// Hover fill on sidebar rows.
        static let sidebarHover = Color(lightHex: "#E9E6E0", darkHex: "#31312F")

        /// The selected sidebar row: a plain grey pill, no color.
        static let sidebarSelected = Color(lightHex: "#E2DED6", darkHex: "#3A3A37")

        /// Sidebar labels when hovered or selected.
        static let sidebarText = Color(lightHex: "#1F1E1D", darkHex: "#EEEDE9")

        /// Sidebar labels at rest.
        static let sidebarTextMuted = Color(lightHex: "#5E5D59", darkHex: "#A9A7A1")

        // ── Borders ──────────────────────────────────────────────────

        /// Dividers and card outlines.
        static let borderSubtle = Color(lightHex: "#E8E6E1", darkHex: "#363634")

        /// Field outlines and secondary buttons.
        static let borderStrong = Color(lightHex: "#D7D4CE", darkHex: "#474744")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — body text, titles, headings.
        static let textPrimary = Color(lightHex: "#1F1E1D", darkHex: "#EEEDE9")

        /// Secondary text — descriptions and supporting lines.
        static let textSecondary = Color(lightHex: "#5E5D59", darkHex: "#B4B2AC")

        /// Captions, placeholders, small labels, timestamps.
        static let textTertiary = Color(lightHex: "#77756F", darkHex: "#8F8D87")

        /// Text on the accent fill (ink in light, near-white in dark — so the
        /// label is the page color) and on night or status fills.
        static let textOnAccent = Color(lightHex: "#FFFFFF", darkHex: "#1F1F1E")

        // ── Igloo Blue ───────────────────────────────────────────────
        // The brand's blue (the full scale is in the brand guide's
        // palette.json). The interface itself no longer uses it: only the
        // main Elf's avatar does, in the app icon's blue.

        static let igloo600 = Color(hex: "#0D66DA")

        // ── Accent: plain ink ────────────────────────────────────────
        // The main action and the selected thing are plain ink: near-black
        // in light, near-white in dark. Still rationed — one per view.

        /// Solid fill for the primary button and the send button.
        static let accent = Color(lightHex: "#1F1E1D", darkHex: "#EEEDE9")

        /// Hover and pressed fill for the primary button.
        static let accentHover = Color(lightHex: "#3D3C39", darkHex: "#D6D4CE")

        /// Accent as text, icons and outlines: links, selected labels.
        static let accentText = Color(lightHex: "#1F1E1D", darkHex: "#EEEDE9")

        /// Accent text on hover.
        static let accentTextHover = Color(lightHex: "#5E5D59", darkHex: "#B4B2AC")

        /// Selected rows, soft badges, quiet highlights.
        static let accentSubtle = Color(lightHex: "#EEECE7", darkHex: "#353533")

        /// Text on the soft surface.
        static let accentSubtleText = Color(lightHex: "#1F1E1D", darkHex: "#EEEDE9")

        /// Accents on a dark surface such as the status pill.
        static let accentOnDark = Color(lightHex: "#D9D7D2", darkHex: "#D9D7D2")

        /// The one focus ring.
        static let focusRing = Color(lightHex: "#8F8D87", darkHex: "#8F8D87")

        /// Native toggles, pickers and progress: a mid ink, so a switched-on
        /// toggle's white knob still reads in both appearances.
        static let controlTint = Color(lightHex: "#3D3C39", darkHex: "#8F8D87")

        // ── Night and ice ────────────────────────────────────────────

        /// Tooltips, a dark banner, code blocks, the status pill: warm near-black.
        static let night = Color(hex: "#1F1E1D")

        // ── Status ───────────────────────────────────────────────────
        // Green ended well · amber waits on a person · red ended badly ·
        // blue is happening now · grey needs nothing. The word is always shown.

        static let success = Color(lightHex: "#15803D", darkHex: "#4ADE80")
        static let successSoft = Color(lightHex: "#ECFDF3", darkHex: "#0F2A1B")

        static let warning = Color(lightHex: "#B45309", darkHex: "#FBBF24")
        static let warningSoft = Color(lightHex: "#FFF7E6", darkHex: "#2E2208")

        /// Danger text and icons (brand role `danger`).
        static let destructiveText = Color(lightHex: "#B91C1C", darkHex: "#F87171")
        /// Solid red — only to confirm a destructive action (brand role `dangerFill`).
        static let destructive = Color(lightHex: "#B91C1C", darkHex: "#B91C1C")
        static let destructiveHover = Color(lightHex: "#991B1B", darkHex: "#991B1B")
        static let destructiveSoft = Color(lightHex: "#FEF2F2", darkHex: "#2E1112")

        /// Category tags only (brand roles `violet` / `indigo`).
        static let violet = Color(lightHex: "#5B4BC4", darkHex: "#B4A9F0")
        static let violetSoft = Color(lightHex: "#F1EFFC", darkHex: "#221C3D")

        // ── The Elf's pen ────────────────────────────────────────────

        /// Annotation Orange: only what an Elf draws on the screen, and the
        /// listening pulse. Never buttons, badges, warnings or decoration.
        static let annotate = Color(lightHex: "#EA580C", darkHex: "#FB923C")

        // ── Overlay (on the user's screen) ───────────────────────────

        /// The Elf's pen: the pointer, circles, arrows, highlights, notes and
        /// the listening bars on the user's screen. Annotation Orange — the
        /// one warm thing on screen, so the eye goes straight to it.
        static let elfPen = annotate
        /// The light outer edge every mark gets, so it reads on any
        /// background (orange content included).
        static let elfPenEdge = Color.white.opacity(0.9)
        /// The user's own ink while drawing with push-to-talk held: Igloo
        /// Blue 500, so it's never mistaken for the Elf's orange pen. Matches
        /// UserInkAppearance.inkCGColor, which is burned into the screenshot.
        static let overlayUserInk = Color(hex: "#1F74E3")

        // ── Avatars ──────────────────────────────────────────────────

        /// The main Elf's avatar, always: Igloo Blue 600, the app icon's and
        /// the brand's blue (`ElfAvatarAppearance.usesBrandBlue`).
        static let mainElfAvatarFill = igloo600

        /// The six fills side Elfs choose from, each readable with white
        /// initials. Fills only, never text colors.
        static let elfAvatarFills: [Color] = [
            Color(hex: "#4A4744"),  // Graphite
            Color(hex: "#0F766E"),  // Teal
            Color(hex: "#6D5BD0"),  // Ice violet
            Color(hex: "#9A6B1F"),  // Amber
            Color(hex: "#B4505A"),  // Rose
            Color(hex: "#2B2A28"),  // Night
        ]

        /// The one fill for people's (circular) avatars.
        static let personAvatarFill = Color(lightHex: "#5E5D59", darkHex: "#4A4744")

        // ── Tints over a surface ─────────────────────────────────────

        /// The ink of the current appearance — dark ink in light, white in dark.
        /// Used at low opacity for hover and selection washes that must work on
        /// both light and dark surfaces: `DS.Colors.contrastTint.opacity(0.06)`.
        static let contrastTint = Color(lightHex: "#1F1E1D", darkHex: "#FFFFFF")

        // ── Disabled State ───────────────────────────────────────────

        /// Disabled controls are the same control at half strength (brand 07).
        static let disabledOpacity: Double = 0.5
    }

    // MARK: - Typography

    /// Three families, each with one job: SF Pro — the Mac's own system
    /// font — for everything you read and press (it has optical sizes and
    /// tracking tuned for each point size, and matches the system's menus
    /// and controls), Fraunces for display headings of 24 pt and up, and
    /// JetBrains Mono for small uppercase labels, keys and code. The Mac app
    /// sits at the compact product density (14 pt body).
    enum Typography {

        // ── The scale ────────────────────────────────────────────────

        /// Fraunces display headings — welcome and onboarding only.

        /// Window and page titles: the serif, like the display headings.
        static var headingLarge: Font { fraunces(size: 30) }
        /// Card titles, dialog titles.
        static var headingMedium: Font { interface(size: 18, weight: .semibold) }
        /// Section headers, large button labels.
        static var headingSmall: Font { interface(size: 15, weight: .semibold) }

        /// Product interface text.
        static var body: Font { interface(size: 14, weight: .regular) }
        static var bodyMedium: Font { interface(size: 14, weight: .medium) }
        /// Metadata, timestamps, captions.
        static var small: Font { interface(size: 13, weight: .regular) }
        static var smallMedium: Font { interface(size: 13, weight: .medium) }
        /// Dense product panels only.
        static var micro: Font { interface(size: 11, weight: .regular) }
        static var nano: Font { interface(size: 10, weight: .regular) }

        /// Section labels: 12 pt semibold in the interface font, sentence
        /// case. Pair with `.dsLabelStyle()`.
        static var label: Font { interface(size: 12, weight: .semibold) }
        /// Code, commands, IDs and keys.
        static var code: Font { mono(size: 13, weight: .regular) }

        /// Letter-spacing of the label style: none.
        static let labelTracking: CGFloat = 0

        // ── Families ─────────────────────────────────────────────────

        /// The interface font, SF Pro (the system font), at a fixed size and
        /// a weight. Nothing to bundle: it ships with macOS.
        static func interface(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: size, weight: weight)
        }

        /// JetBrains Mono at a size and weight (regular or medium).
        static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            BrandFonts.registerBundledFontsIfNeeded()
            return Font.custom(BrandFonts.monoPostScriptName(for: weight), fixedSize: size)
        }

        /// Fraunces at weight 400, crisp (SOFT 0), never wonky, its optical size
        /// following the point size — the brand's display setting. Below 24 pt
        /// the soft serifs clog, so smaller sizes fall back to the interface
        /// font, semibold.
        static func fraunces(size: CGFloat) -> Font {
            guard size >= 24 else { return interface(size: size, weight: .semibold) }
            BrandFonts.registerBundledFontsIfNeeded()
            if let frauncesFont = BrandFonts.frauncesDisplayFont(size: size) {
                return Font(frauncesFont)
            }
            return interface(size: size, weight: .semibold)
        }

        /// Letter-spacing for a Fraunces heading: about -0.02em, tightening
        /// toward -0.028em at the largest sizes.
        static func frauncesTracking(size: CGFloat) -> CGFloat {
            let emFraction: CGFloat = size >= 40 ? -0.028 : -0.02
            return size * emFraction
        }
    }

    // MARK: - Spacing

    /// The small set of spacing steps, repeated so edges line up.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    /// The bigger the thing, the rounder. Always drawn with `.continuous`
    /// corners, which match the icon's squircle tile. A corner nested inside
    /// another uses the next step down.
    enum CornerRadius {
        /// Keycaps, tooltips, small inner elements.
        static let small: CGFloat = 6
        /// Buttons and fields; Elf avatars.
        static let medium: CGFloat = 8
        /// Cards.
        static let large: CGFloat = 12
        /// Cards (kept for older call sites; the same as `large`).
        static let extraLarge: CGFloat = 12
        /// Dialogs, sheets and floating panels.
        static let dialog: CGFloat = 16
        /// Pills, badges and people's avatars.
        static let pill: CGFloat = .infinity

        /// Card radius, named for what it's for.
        static let card: CGFloat = large
        /// Button and field radius, named for what it's for.
        static let control: CGFloat = medium
    }

    // MARK: - Shadows

    /// Shadows lean toward night in light appearance (pure black looks dirty
    /// next to the igloo's lavender) and are black and stronger in dark, where
    /// a tint wouldn't show. Things that sit are flat; only things that float
    /// get depth.
    enum ShadowLevel {
        /// Cards and buttons at rest — rarely needed.
        case small
        /// Menus, dropdowns.
        case medium
        /// Popovers, floating notes, the notepad.
        case large
        /// Dialogs.
        case extraLarge

        var verticalOffset: CGFloat {
            switch self {
            case .small: return 1
            case .medium: return 4
            case .large: return 8
            case .extraLarge: return 16
            }
        }

        /// CSS blur is roughly twice SwiftUI's shadow radius.
        var radius: CGFloat {
            switch self {
            case .small: return 1
            case .medium: return 6
            case .large: return 12
            case .extraLarge: return 20
            }
        }

        func color(for colorScheme: ColorScheme) -> Color {
            switch (self, colorScheme) {
            case (.small, .dark): return Color.black.opacity(0.30)
            case (.medium, .dark): return Color.black.opacity(0.35)
            case (.large, .dark): return Color.black.opacity(0.40)
            case (.extraLarge, .dark): return Color.black.opacity(0.50)
            case (.small, _): return Colors.night.opacity(0.06)
            case (.medium, _): return Colors.night.opacity(0.08)
            case (.large, _): return Colors.night.opacity(0.10)
            case (.extraLarge, _): return Colors.night.opacity(0.14)
            }
        }
    }

    // MARK: - Motion

    /// One calm hand: one easing, three speeds, one entrance. Reduce Motion
    /// is respected everywhere — when it's on, things appear at once.
    enum Motion {
        /// Hover, focus, tooltips.
        static let fastDuration: Double = 0.12
        /// Buttons, menus, tabs.
        static let baseDuration: Double = 0.2
        /// Things entering: panels, dialogs.
        static let slowDuration: Double = 0.4

        /// The brand easing, cubic-bezier(0.2, 0.8, 0.2, 1): a quick start
        /// and a soft landing.
        static func easing(duration: Double) -> SwiftUI.Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        }

        static var fast: SwiftUI.Animation { easing(duration: fastDuration) }
        static var base: SwiftUI.Animation { easing(duration: baseDuration) }
        static var slow: SwiftUI.Animation { easing(duration: slowDuration) }

        /// The animation to use, or none when the user asked for reduced motion.
        static func animation(_ animation: SwiftUI.Animation, reduceMotion: Bool) -> SwiftUI.Animation? {
            reduceMotion ? nil : animation
        }

        /// How far something rises as it fades in.
        static let entranceRiseDistance: CGFloat = 6
    }

}

// MARK: - Bundled fonts

/// Registers the bundled brand fonts with this process and knows their
/// PostScript names. Registration is idempotent and happens the first time
/// any typography token is read, so every view gets the fonts without the
/// app delegate having to remember to call anything first.
enum BrandFonts {

    /// Fraunces' variation axes, as their four-character tags read as integers.
    private static let opticalSizeAxisIdentifier = 0x6F70737A  // 'opsz'
    private static let weightAxisIdentifier = 0x77676874       // 'wght'
    private static let softnessAxisIdentifier = 0x534F4654     // 'SOFT'
    private static let wonkyAxisIdentifier = 0x574F4E4B        // 'WONK'

    /// The brand's Fraunces weight.
    static let frauncesDisplayWeight: CGFloat = 400

    /// Whether every bundled font file was found and registered.
    private(set) static var didRegisterAllBundledFonts = false

    private static let registrationResult: Bool = {
        let bundle = Bundle(for: BrandFontsBundleToken.self)
        let fontFileURLs = bundledFontFileURLs(in: bundle)
        var registeredEveryFile = !fontFileURLs.isEmpty
        for fontFileURL in fontFileURLs {
            var registrationError: Unmanaged<CFError>?
            let didRegister = CTFontManagerRegisterFontsForURL(fontFileURL as CFURL, .process, &registrationError)
            if !didRegister {
                // Already registered (for example by a test host) is fine; the
                // fonts are available either way.
                let alreadyRegisteredErrorCode = CTFontManagerError.alreadyRegistered.rawValue
                let errorCode = registrationError.map { CFErrorGetCode($0.takeRetainedValue()) }
                if errorCode != alreadyRegisteredErrorCode {
                    registeredEveryFile = false
                }
            }
        }
        didRegisterAllBundledFonts = registeredEveryFile
        return registeredEveryFile
    }()

    static func registerBundledFontsIfNeeded() {
        _ = registrationResult
    }

    /// The bundled .ttf files, whether the build copied them flat into
    /// Resources or kept their Fonts/ folder.
    static func bundledFontFileURLs(in bundle: Bundle) -> [URL] {
        let flatFontURLs = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        let folderFontURLs = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        let allFontURLs = flatFontURLs + folderFontURLs
        var seenFileNames = Set<String>()
        return allFontURLs.filter { fontURL in
            seenFileNames.insert(fontURL.lastPathComponent).inserted
        }
    }

    static func monoPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: return "JetBrainsMono-Medium"
        default: return "JetBrainsMono-Regular"
        }
    }

    /// Fraunces set the brand's way. The variation is applied at runtime
    /// rather than baked into a modified font file, so the bundled file stays
    /// the unmodified upstream release.
    static func frauncesDisplayFont(size: CGFloat) -> CTFont? {
        let opticalSize = min(max(size, 9), 144)
        let variation: [Int: CGFloat] = [
            weightAxisIdentifier: frauncesDisplayWeight,
            softnessAxisIdentifier: 0,
            wonkyAxisIdentifier: 0,
            opticalSizeAxisIdentifier: opticalSize,
        ]
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: "Fraunces-Regular",
            kCTFontVariationAttribute: variation as CFDictionary,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        // CoreText falls back to another family when the name isn't
        // registered; only return the font when it really is Fraunces.
        let familyName = CTFontCopyFamilyName(font) as String
        return familyName == "Fraunces" ? font : nil
    }
}

/// Anchors `Bundle(for:)` to the app's bundle, which holds the fonts.
private final class BrandFontsBundleToken {}

// MARK: - Text styles

extension View {
    /// The label style: 12 pt semibold in the interface font, sentence case,
    /// no extra tracking. For section markers, status badges and short facts.
    func dsLabelStyle() -> some View {
        self
            .font(DS.Typography.label)
            .tracking(DS.Typography.labelTracking)
    }

    /// A Fraunces display heading with the brand's tight tracking.
    func dsDisplayHeading(size: CGFloat) -> some View {
        self
            .font(DS.Typography.fraunces(size: size))
            .tracking(DS.Typography.frauncesTracking(size: size))
    }

    /// A shadow at one of the brand's levels, tinted for the current appearance.
    func dsShadow(_ shadowLevel: DS.ShadowLevel) -> some View {
        modifier(DSShadowModifier(shadowLevel: shadowLevel))
    }

    /// The brand's one entrance: fade in and rise slightly, at the slow speed.
    /// Appears at once when Reduce Motion is on.
    func dsEntrance() -> some View {
        modifier(DSEntranceModifier())
    }

    /// The brand card: surface fill, 1 pt hairline border, 12 pt continuous
    /// corners, 16 pt padding, no shadow at rest.
    func dsCard(padding: CGFloat = DS.Spacing.lg) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}

private struct DSShadowModifier: ViewModifier {
    let shadowLevel: DS.ShadowLevel
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(
            color: shadowLevel.color(for: colorScheme),
            radius: shadowLevel.radius,
            x: 0,
            y: shadowLevel.verticalOffset
        )
    }
}

private struct DSEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : DS.Motion.entranceRiseDistance)
            .onAppear {
                withAnimation(DS.Motion.animation(DS.Motion.slow, reduceMotion: reduceMotion)) {
                    hasAppeared = true
                }
            }
    }
}

// MARK: - Button Styles
//
// Flat, rounded, quiet (brand chapter 07). One blue button per view. Buttons
// don't move on hover or press — only their color changes — and they never
// take status colors: approve is primary, deny is secondary, and solid red is
// only for confirming something destructive. The first click toward something
// destructive (a "Delete all…" that opens a confirmation) is a secondary
// button with a red label, set apart from the neutral buttons beside it.

/// The kinds of button the brand defines.
enum DSButtonKind {
    /// Solid Igloo Blue, white label — the one main action in a view.
    case primary
    /// Surface fill, strong border, ink label — other actions.
    case secondary
    /// No fill, muted label — low-emphasis actions, toolbars.
    case ghost
    /// Solid red, white label — only to confirm a destructive action.
    case danger
    /// Secondary button with a red label — the first click toward a
    /// destructive action, which then asks to confirm.
    case destructiveSecondary
    /// White fill, night label — only on a night or blue background.
    case inverted
}

/// The brand's button sizes: 32 pt tall by default, 28 pt small.
enum DSButtonSize {
    case regular
    case small

    var height: CGFloat {
        switch self {
        case .regular: return 32
        case .small: return 28
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return 14
        case .small: return 12
        }
    }

    var labelFont: Font {
        switch self {
        case .regular: return DS.Typography.interface(size: 14, weight: .medium)
        case .small: return DS.Typography.interface(size: 13, weight: .medium)
        }
    }
}

/// One button style for every brand button kind.
struct DSButtonStyle: ButtonStyle {
    var kind: DSButtonKind
    var size: DSButtonSize = .regular
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size, isFullWidth: isFullWidth)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonKind
    let size: DSButtonSize
    let isFullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(size.labelFont)
            .lineLimit(1)
            .foregroundColor(labelColor(isHighlighted: isHighlighted))
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(fillColor(isHighlighted: isHighlighted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: hasBorder ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
            .opacity(isEnabled ? 1 : DS.Colors.disabledOpacity)
            .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: isHighlighted)
            .onHover { hovering in isHovered = hovering }
            .pointerCursor(isEnabled: isEnabled)
    }

    private func fillColor(isHighlighted: Bool) -> Color {
        switch kind {
        case .primary: return isHighlighted ? DS.Colors.accentHover : DS.Colors.accent
        case .secondary: return isHighlighted ? DS.Colors.surface2 : DS.Colors.surface1
        case .destructiveSecondary: return isHighlighted ? DS.Colors.destructiveSoft : DS.Colors.surface1
        case .ghost: return isHighlighted ? DS.Colors.surface2 : Color.clear
        case .danger: return isHighlighted ? DS.Colors.destructiveHover : DS.Colors.destructive
        case .inverted: return isHighlighted ? Color.white.opacity(0.9) : Color.white
        }
    }

    private func labelColor(isHighlighted: Bool) -> Color {
        switch kind {
        case .primary, .danger: return DS.Colors.textOnAccent
        case .secondary: return DS.Colors.textPrimary
        case .destructiveSecondary: return DS.Colors.destructiveText
        case .ghost: return isHighlighted ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .inverted: return DS.Colors.night
        }
    }

    private var hasBorder: Bool {
        kind == .secondary || kind == .destructiveSecondary
    }

    private var borderColor: Color {
        hasBorder ? DS.Colors.borderStrong : Color.clear
    }
}

/// Icon-only button — a ghost button sized to its icon, with a night
/// tooltip. Used for close buttons, send, and small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    func makeBody(configuration: Configuration) -> some View {
        DSIconButtonBody(
            configuration: configuration,
            size: size,
            isDestructiveOnHover: isDestructiveOnHover,
            tooltipText: tooltipText,
            tooltipAlignment: tooltipAlignment
        )
    }
}

private struct DSIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isDestructiveOnHover: Bool
    let tooltipText: String?
    let tooltipAlignment: Alignment

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    var body: some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(DS.Typography.interface(size: size * 0.5, weight: .medium))
            .foregroundColor(iconColor(isHighlighted: isHighlighted))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(backgroundColor(isHighlighted: isHighlighted))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
            .opacity(isEnabled ? 1 : DS.Colors.disabledOpacity)
            .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: isHighlighted)
            .pointerCursor(isEnabled: isEnabled)
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately.
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    isTooltipVisible = false
                }
            }
            // The tooltip sits above the button; it never takes hover or clicks.
            .overlay(
                Group {
                    if isTooltipVisible, let tooltipText, !tooltipText.isEmpty {
                        DSTooltipLabel(text: tooltipText)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isHighlighted: Bool) -> Color {
        if isDestructiveOnHover && isHighlighted {
            return DS.Colors.destructiveText
        }
        return isHighlighted ? DS.Colors.textPrimary : DS.Colors.textSecondary
    }

    private func backgroundColor(isHighlighted: Bool) -> Color {
        guard isHighlighted else { return Color.clear }
        if isDestructiveOnHover {
            return DS.Colors.destructiveSoft
        }
        return configuration.isPressed ? DS.Colors.surface3 : DS.Colors.surface2
    }
}

/// The brand tooltip: night background, white text, 6 pt corners, no arrow,
/// small type. The same in light and dark.
struct DSTooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Typography.interface(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.night)
            )
            .dsShadow(.medium)
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// The one main action in a view: solid Igloo Blue.
    func dsPrimaryButtonStyle(isFullWidth: Bool = false, size: DSButtonSize = .regular) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .primary, size: size, isFullWidth: isFullWidth))
    }

    /// Other actions: surface fill with a strong border.
    func dsSecondaryButtonStyle(isFullWidth: Bool = false, size: DSButtonSize = .regular) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .secondary, size: size, isFullWidth: isFullWidth))
    }

    /// Low-emphasis actions and toolbars: no fill until hovered.
    func dsGhostButtonStyle(size: DSButtonSize = .regular) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .ghost, size: size))
    }

    /// Only to confirm a destructive action, never as a first click.
    func dsDangerButtonStyle(size: DSButtonSize = .regular) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .danger, size: size))
    }

    /// The first click toward something destructive ("Delete all chats…"),
    /// which then asks to confirm with a danger button.
    func dsDestructiveSecondaryButtonStyle(size: DSButtonSize = .small) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .destructiveSecondary, size: size))
    }

    /// Only on a night or blue background.
    func dsInvertedButtonStyle(size: DSButtonSize = .regular) -> some View {
        self.buttonStyle(DSButtonStyle(kind: .inverted, size: size))
    }

    /// The icon-only button. `tooltipAlignment` controls where the tooltip
    /// sits horizontally: `.leading` for left-edge buttons, `.trailing` for
    /// right-edge buttons, `.center` for the middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Text field

/// The brand field (chapter 07): a visible label above it in small muted
/// text, surface fill, strong border, 8 pt corners, 34 pt tall, SF Pro 14.
/// On focus the border turns Igloo Blue and the focus ring appears; an
/// error turns the border red and says what to do underneath. The
/// placeholder is an example, never the label.
struct DSTextField: View {
    let label: String?
    let placeholder: String
    @Binding var text: String
    var errorMessage: String? = nil
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        label: String?,
        placeholder: String,
        text: Binding<String>,
        errorMessage: String? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(DS.Typography.smallMedium)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typography.body)
                .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                        .fill(isEnabled ? DS.Colors.surface1 : DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                // The one focus ring: 2 pt, 2 pt outside the control.
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.control + 2, style: .continuous)
                        .strokeBorder(DS.Colors.focusRing, lineWidth: 2)
                        .padding(-4)
                        .opacity(isFocused ? 1 : 0)
                )
                .overlay(IBeamCursorView())
                .animation(DS.Motion.animation(DS.Motion.fast, reduceMotion: reduceMotion), value: isFocused)
            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Typography.small)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var borderColor: Color {
        if errorMessage != nil { return DS.Colors.destructiveText }
        if isFocused { return DS.Colors.accentText }
        return DS.Colors.borderStrong
    }
}

// MARK: - Status badge

/// The states a piece of work can be in, each with one tone everywhere
/// (brand chapter 07). The word is always shown beside the color.
enum DSStatusTone: Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
    case violet

    var textColor: Color {
        switch self {
        case .neutral: return DS.Colors.textSecondary
        case .info: return DS.Colors.accentSubtleText
        case .success: return DS.Colors.success
        case .warning: return DS.Colors.warning
        case .danger: return DS.Colors.destructiveText
        case .violet: return DS.Colors.violet
        }
    }

    var backgroundColor: Color {
        switch self {
        case .neutral: return DS.Colors.surface2
        case .info: return DS.Colors.accentSubtle
        case .success: return DS.Colors.successSoft
        case .warning: return DS.Colors.warningSoft
        case .danger: return DS.Colors.destructiveSoft
        case .violet: return DS.Colors.violetSoft
        }
    }
}

/// A short status or category word in a fully rounded pill, 20 pt tall.
struct DSStatusBadge: View {
    let text: String
    let tone: DSStatusTone

    var body: some View {
        Text(text)
            .font(DS.Typography.interface(size: 11, weight: .medium))
            .foregroundColor(tone.textColor)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(tone.backgroundColor))
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

extension View {
}

// MARK: - Color Utilities

extension NSColor {
    /// An sRGB color from a hex string like "#0D66DA" or "0D66DA".
    convenience init(brandHex: String) {
        let hexSanitized = brandHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// A color with one value for light appearance and one for dark,
    /// resolved by AppKit (and SwiftUI) against the appearance it's drawn in.
    static func brandDynamic(lightHex: String, darkHex: String) -> NSColor {
        let lightColor = NSColor(brandHex: lightHex)
        let darkColor = NSColor(brandHex: darkHex)
        return NSColor(name: nil) { appearance in
            let isDarkAppearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDarkAppearance ? darkColor : lightColor
        }
    }
}

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        self.init(nsColor: NSColor(brandHex: hex))
    }

    /// A brand color with a light and a dark value that follows the
    /// appearance of the view it's drawn in.
    init(lightHex: String, darkHex: String) {
        self.init(nsColor: NSColor.brandDynamic(lightHex: lightHex, darkHex: darkHex))
    }
}
