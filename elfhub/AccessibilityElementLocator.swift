//
//  AccessibilityElementLocator.swift
//  elfhub
//
//  Reads the real UI element under a screen point through the Accessibility
//  API. Two uses:
//
//  - Precision: a model's pixel estimate is often a few points off. When the
//    point lands inside a real button or a highlight roughly covers a real
//    control, elfhub snaps to the element's true frame, so pointing,
//    annotating and clicking land exactly — even with weaker local models.
//  - Safety: consent decisions use the element's real role and title (e.g. a
//    "Send" default button, a password field) instead of the label the model
//    wrote, which a prompt injection on screen could influence.
//
//  Accessibility uses top-left-origin global coordinates, the same space as
//  Core Graphics events. Every call has a short messaging timeout so a hung
//  app can't stall elfhub, and lookups run off the main thread.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - Element Facts

/// What elfhub learned about the element under a point. Sendable so it can be
/// produced on a background task.
struct AccessibilityElementFacts: Equatable, Sendable {
    /// Element frame in Core Graphics global coordinates (top-left origin).
    let frameInCoreGraphicsGlobalCoordinates: CGRect?
    let role: String?
    let subrole: String?
    /// Best human-readable name: title, then description, then placeholder.
    let title: String?
    let isSecureTextField: Bool
    /// True when the element is its window's default button (the one Return
    /// presses) — typically the "commit" action of a dialog or form.
    let isDefaultButton: Bool
    let owningApplicationBundleIdentifier: String?
    /// Host of the web page the element sits in ("mail.google.com"), when it
    /// is inside a browser's web area. Lets consent treat a web mail or chat
    /// page like the native Mail or Slack app.
    var webPageHost: String? = nil
    /// True when the element is web content (a browser page, or an Electron
    /// app's UI). Accessibility actions there can report success without
    /// running the page's own event handlers, so elfhub uses real events.
    var isInsideWebContent: Bool = false
}

// MARK: - Locator

enum AccessibilityElementLocator {

    /// Per-call messaging timeout. Keeps a frozen app from blocking elfhub.
    nonisolated static let messagingTimeoutInSeconds: Float = 0.05

    /// The element at a Core Graphics global point, or nil when Accessibility
    /// isn't granted, nothing is there, or the hit is elfhub's own overlay.
    static func elementFacts(atCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint) async -> AccessibilityElementFacts? {
        await Task.detached(priority: .userInitiated) {
            lookUpElementFactsSynchronously(atCoreGraphicsGlobalPoint: coreGraphicsGlobalPoint)
        }.value
    }

    /// The element that currently has keyboard focus (where typed text goes).
    static func focusedElementFacts() async -> AccessibilityElementFacts? {
        await Task.detached(priority: .userInitiated) {
            lookUpFocusedElementFactsSynchronously()
        }.value
    }

    // MARK: - Synchronous lookups (background)

    nonisolated private static func lookUpElementFactsSynchronously(
        atCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint
    ) -> AccessibilityElementFacts? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeoutInSeconds)

        var hitElement: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(coreGraphicsGlobalPoint.x),
            Float(coreGraphicsGlobalPoint.y),
            &hitElement
        )
        guard hitTestResult == .success, let hitElement else { return nil }
        return makeElementFacts(for: hitElement)
    }

    nonisolated private static func lookUpFocusedElementFactsSynchronously() -> AccessibilityElementFacts? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeoutInSeconds)

        var focusedElementValue: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return nil }
        return makeElementFacts(for: focusedElementValue as! AXUIElement)
    }

    nonisolated private static func makeElementFacts(for element: AXUIElement) -> AccessibilityElementFacts? {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutInSeconds)

        var owningProcessIdentifier: pid_t = 0
        AXUIElementGetPid(element, &owningProcessIdentifier)
        // The overlay is click-through but still part of elfhub's own
        // Accessibility tree; never treat our own UI as the target.
        if owningProcessIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        let title = [
            stringAttribute(kAXTitleAttribute, of: element),
            stringAttribute(kAXDescriptionAttribute, of: element),
            stringAttribute(kAXPlaceholderValueAttribute, of: element)
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let owningApplicationBundleIdentifier = NSRunningApplication(processIdentifier: owningProcessIdentifier)?.bundleIdentifier
        let enclosingWebArea = enclosingWebAreaElement(of: element)
        let webPageHost = enclosingWebArea.flatMap { webArea in
            isBrowser(bundleIdentifier: owningApplicationBundleIdentifier) ? webPageHost(ofWebArea: webArea) : nil
        }

        return AccessibilityElementFacts(
            frameInCoreGraphicsGlobalCoordinates: frameAttribute(of: element),
            role: role,
            subrole: subrole,
            title: title,
            isSecureTextField: subrole == (kAXSecureTextFieldSubrole as String),
            isDefaultButton: isDefaultButtonOfItsWindow(element),
            owningApplicationBundleIdentifier: owningApplicationBundleIdentifier,
            webPageHost: webPageHost,
            isInsideWebContent: enclosingWebArea != nil
        )
    }

    // MARK: - Web content

    /// How far up the tree to look for a web area. Web pages nest deeply;
    /// past this the element is treated as not web content.
    nonisolated static let maximumAncestorDepthForWebArea = 48

    /// Browsers whose web areas report the page's URL.
    nonisolated static let browserBundleIdentifierPrefixes = [
        "com.apple.safari", "com.google.chrome", "org.chromium", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser", "com.operasoftware",
        "com.vivaldi", "app.zen-browser", "com.kagi.kagimacos"
    ]

    nonisolated static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let loweredBundleIdentifier = bundleIdentifier?.lowercased() else { return false }
        return browserBundleIdentifierPrefixes.contains { loweredBundleIdentifier.hasPrefix($0) }
    }

    /// The AXWebArea the element is inside (itself included), if any.
    nonisolated private static func enclosingWebAreaElement(of element: AXUIElement) -> AXUIElement? {
        var currentElement = element
        for _ in 0..<maximumAncestorDepthForWebArea {
            AXUIElementSetMessagingTimeout(currentElement, messagingTimeoutInSeconds)
            if stringAttribute(kAXRoleAttribute, of: currentElement) == "AXWebArea" {
                return currentElement
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return nil
            }
            currentElement = parentValue as! AXUIElement
        }
        return nil
    }

    nonisolated private static func webPageHost(ofWebArea webArea: AXUIElement) -> String? {
        var urlValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &urlValue) == .success,
              let urlValue else { return nil }
        if let pageURL = urlValue as? URL {
            return pageURL.host
        }
        if let pageURLString = urlValue as? String {
            return URL(string: pageURLString)?.host
        }
        return nil
    }

    nonisolated private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else {
            return nil
        }
        return attributeValue as? String
    }

    nonisolated private static func frameAttribute(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var elementOrigin = CGPoint.zero
        var elementSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementOrigin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize) else {
            return nil
        }
        return CGRect(origin: elementOrigin, size: elementSize)
    }

    nonisolated private static func isDefaultButtonOfItsWindow(_ element: AXUIElement) -> Bool {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return false
        }

        var defaultButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXDefaultButtonAttribute as CFString, &defaultButtonValue) == .success,
              let defaultButtonValue else {
            return false
        }
        return CFEqual(defaultButtonValue, element)
    }
}

// MARK: - Snapping Rules (pure)

/// Decides when a real element's frame should replace the model's estimate.
/// All rects and points are in Core Graphics global coordinates.
enum AccessibilitySnapping {

    /// Layout containers whose frames are far bigger than the thing the model
    /// meant; snapping to them would make the mark less precise, not more.
    static let containerRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXGroup",
        "AXScrollArea", "AXSplitGroup", "AXSplitter", "AXWebArea", "AXLayoutArea",
        "AXLayoutItem", "AXBrowser", "AXOutline", "AXTable", "AXList",
        "AXTabGroup", "AXToolbar", "AXUnknown"
    ]

    /// Discrete controls where clicking the center is always what's meant.
    /// Text areas are excluded on purpose: where in the text you click matters.
    static let centerClickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle", "AXImage"
    ]

    /// True when the element is a real, reasonably sized control on the
    /// display rather than a giant container or a sliver.
    static func isElementUsableForSnapping(
        elementFrame: CGRect,
        role: String?,
        displayBounds: CGRect
    ) -> Bool {
        if let role, containerRoles.contains(role) { return false }
        guard elementFrame.width >= 6, elementFrame.height >= 6 else { return false }
        return elementFrame.width <= displayBounds.width * 0.6
            && elementFrame.height <= displayBounds.height * 0.4
    }

    /// The point to click or point at: the element's center for discrete
    /// controls the model's point falls inside, otherwise nil (keep the model's point).
    static func snappedTargetPoint(
        modelPoint: CGPoint,
        elementFrame: CGRect,
        role: String?
    ) -> CGPoint? {
        guard let role, centerClickableRoles.contains(role), elementFrame.contains(modelPoint) else {
            return nil
        }
        return CGPoint(x: elementFrame.midX, y: elementFrame.midY)
    }

    /// A highlight snapped to the real element (with a little breathing room)
    /// when the model's box and the element substantially agree, otherwise nil.
    static func snappedHighlightFrame(modelFrame: CGRect, elementFrame: CGRect) -> CGRect? {
        let modelArea = modelFrame.width * modelFrame.height
        let elementArea = elementFrame.width * elementFrame.height
        guard modelArea > 0, elementArea > 0 else { return nil }

        let intersection = modelFrame.intersection(elementFrame)
        guard !intersection.isNull else { return nil }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = modelArea + elementArea - intersectionArea
        let intersectionOverUnion = intersectionArea / unionArea

        guard intersectionOverUnion >= 0.3 else { return nil }
        return elementFrame.insetBy(dx: -4, dy: -4)
    }
}

// MARK: - Global Coordinate Conversion

/// Converts between Core Graphics global coordinates (top-left origin of the
/// primary display, used by events and Accessibility) and AppKit global
/// coordinates (bottom-left origin, used by windows and the overlay).
enum GlobalCoordinateSpaceConversion {

    /// Height of the primary display — the one whose AppKit frame origin is
    /// (0,0) and which defines the flip between the two systems.
    private static var primaryDisplayHeight: CGFloat {
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return primaryScreen?.frame.height ?? 0
    }

    static func appKitPoint(fromCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint) -> CGPoint {
        CGPoint(x: coreGraphicsGlobalPoint.x, y: primaryDisplayHeight - coreGraphicsGlobalPoint.y)
    }

    static func appKitRect(fromCoreGraphicsGlobalRect coreGraphicsGlobalRect: CGRect) -> CGRect {
        CGRect(
            x: coreGraphicsGlobalRect.origin.x,
            y: primaryDisplayHeight - coreGraphicsGlobalRect.maxY,
            width: coreGraphicsGlobalRect.width,
            height: coreGraphicsGlobalRect.height
        )
    }
}

// MARK: - Accessibility Actions

/// Acts on native controls through Accessibility instead of synthetic mouse
/// and keyboard events — the "most precise channel first" rule. Pressing a
/// button with AXPress doesn't move the user's pointer or need the window in
/// front, and inserting text sets it in one step instead of character by
/// character. Web content is skipped on purpose: there these calls can
/// report success without running the page's own handlers.
enum AccessibilityElementActions {

    /// Controls where AXPress means exactly what a click means.
    nonisolated static let pressableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
        "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"
    ]

    /// Editable text roles that accept inserted text.
    nonisolated static let textInsertionRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Below this length, typing character by character is quick enough and
    /// behaves exactly like the user typing.
    nonisolated static let minimumTextLengthForInsertion = 40

    /// True when a click on this element should be an AXPress.
    nonisolated static func shouldPressWithAccessibility(_ targetElementFacts: AccessibilityElementFacts?) -> Bool {
        guard let targetElementFacts, let role = targetElementFacts.role else { return false }
        return pressableRoles.contains(role) && !targetElementFacts.isInsideWebContent
    }

    /// True when this text should be inserted into the focused element in one
    /// step. Text with newlines or tabs is always typed, because those are
    /// real Return / Tab presses (which consent judges as such).
    nonisolated static func shouldInsertTextWithAccessibility(_ text: String, into focusedElementFacts: AccessibilityElementFacts?) -> Bool {
        guard let focusedElementFacts, let role = focusedElementFacts.role else { return false }
        let containsKeyPresses = text.contains("\n") || text.contains("\r") || text.contains("\t")
        return text.count >= minimumTextLengthForInsertion
            && !containsKeyPresses
            && textInsertionRoles.contains(role)
            && !focusedElementFacts.isSecureTextField
            && !focusedElementFacts.isInsideWebContent
    }

    /// Presses the control under the point, but only if it is still the
    /// element that was approved (same role and title) and it supports
    /// AXPress. Returns false — having done nothing — otherwise, so the
    /// caller can fall back to a real click.
    static func pressElement(
        atCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint,
        expectedRole: String?,
        expectedTitle: String?
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            pressElementSynchronously(
                atCoreGraphicsGlobalPoint: coreGraphicsGlobalPoint,
                expectedRole: expectedRole,
                expectedTitle: expectedTitle
            )
        }.value
    }

    /// Inserts text at the focused element's caret (replacing any selection)
    /// and checks that the value actually changed. Returns false when the
    /// element refused or ignored it — nothing was changed then, so the
    /// caller can safely type the text instead.
    static func insertTextIntoFocusedElement(_ text: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            insertTextIntoFocusedElementSynchronously(text)
        }.value
    }

    nonisolated private static func pressElementSynchronously(
        atCoreGraphicsGlobalPoint coreGraphicsGlobalPoint: CGPoint,
        expectedRole: String?,
        expectedTitle: String?
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, AccessibilityElementLocator.messagingTimeoutInSeconds)

        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(coreGraphicsGlobalPoint.x),
            Float(coreGraphicsGlobalPoint.y),
            &hitElement
        ) == .success, let hitElement else { return false }
        AXUIElementSetMessagingTimeout(hitElement, AccessibilityElementLocator.messagingTimeoutInSeconds)

        var owningProcessIdentifier: pid_t = 0
        AXUIElementGetPid(hitElement, &owningProcessIdentifier)
        guard owningProcessIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        let hitRole = copyStringAttribute(kAXRoleAttribute, of: hitElement)
        guard let hitRole, hitRole == expectedRole, pressableRoles.contains(hitRole) else { return false }
        let hitTitle = [
            copyStringAttribute(kAXTitleAttribute, of: hitElement),
            copyStringAttribute(kAXDescriptionAttribute, of: hitElement),
            copyStringAttribute(kAXPlaceholderValueAttribute, of: hitElement)
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard hitTitle == expectedTitle else { return false }

        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(hitElement, &actionNames) == .success,
              let actionNames = actionNames as? [String],
              actionNames.contains(kAXPressAction as String) else { return false }

        return AXUIElementPerformAction(hitElement, kAXPressAction as CFString) == .success
    }

    nonisolated private static func insertTextIntoFocusedElementSynchronously(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, AccessibilityElementLocator.messagingTimeoutInSeconds)

        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return false }
        let focusedElement = focusedElementValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedElement, AccessibilityElementLocator.messagingTimeoutInSeconds)

        guard let role = copyStringAttribute(kAXRoleAttribute, of: focusedElement), textInsertionRoles.contains(role),
              copyStringAttribute(kAXSubroleAttribute, of: focusedElement) != (kAXSecureTextFieldSubrole as String) else {
            return false
        }

        var isSelectedTextSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSelectedTextSettable) == .success,
              isSelectedTextSettable.boolValue else { return false }

        // Replacing a selection with identical text wouldn't change the value,
        // which would look like a failure and get the text typed twice.
        guard copyStringAttribute(kAXSelectedTextAttribute, of: focusedElement) != text else { return false }

        let valueBeforeInsertion = copyStringAttribute(kAXValueAttribute, of: focusedElement)
        guard AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        // Some apps accept the call and ignore it. Only report success when
        // the field's value really changed, so the caller never types the
        // text a second time after a real insertion.
        let valueAfterInsertion = copyStringAttribute(kAXValueAttribute, of: focusedElement)
        return valueAfterInsertion != valueBeforeInsertion
    }

    nonisolated private static func copyStringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else {
            return nil
        }
        return attributeValue as? String
    }
}
