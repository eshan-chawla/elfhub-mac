//
//  ScreenActionSynthesizer.swift
//  elfhub
//
//  Posts real synthetic mouse and keyboard events so elfhub can actually
//  act on the user's screen (click, double-click, type, key shortcuts,
//  scroll) — not just point at things. This is the local, non-daemon
//  counterpart to the shipped app's bundled cua-driver: because the events
//  originate inside elfhub itself, macOS attributes the Accessibility and
//  Screen Recording usage to elfhub, and no separate helper needs authorizing.
//
//  Every coordinate this type receives is a TOP-LEFT-origin Core Graphics
//  global point (Quartz coordinates), which is what CGEvent expects. That is
//  deliberately different from the AppKit bottom-left global points used to
//  draw the guidance overlay — see CompanionScreenCapture's mapping
//  helpers, which produce both origins from the same screenshot pixel.
//
//  Requires the Accessibility permission (AXIsProcessTrusted); callers must
//  gate on WindowPositionManager.hasAccessibilityPermission() before firing.
//
//  Every posted event is tagged with `syntheticEventMarker` so elfhub can tell
//  its own input apart from the user's: UserInterruptionMonitor treats any
//  UNtagged input during an action chain as the user taking over.
//
//  Pauses between events are async (never a blocking sleep), so the main
//  actor — and with it the Esc / takeover event tap — stays responsive.
//

import AppKit
import Carbon
import CoreGraphics

enum ScreenActionSynthesizer {

    /// Written into each synthetic event's eventSourceUserData field ("ELFOS").
    static let syntheticEventMarker: Int64 = 0x45_4C_46_4F_53

    /// True when an event was posted by elfhub rather than the user's hardware.
    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    /// Tags the event as elfhub's own and posts it.
    private static func postTaggedEvent(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll Direction

    enum ScrollDirection: String {
        case up
        case down
        case left
        case right
    }

    // MARK: - Pointer Position

    /// Where elfhub last put the pointer, so a chain can tell afterwards
    /// whether the user has moved it since.
    private(set) static var lastSyntheticPointerLocation: CGPoint?

    /// The pointer's current position in Core Graphics global coordinates.
    static func currentPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Puts the pointer back where the user left it — but only if it is still
    /// where elfhub last put it. If the user has moved it since, their
    /// position wins and nothing happens.
    static func restorePointerIfUntouched(to originalPointerLocation: CGPoint) {
        guard let lastSyntheticPointerLocation,
              let currentPointerLocation = currentPointerLocation(),
              hypot(currentPointerLocation.x - lastSyntheticPointerLocation.x,
                    currentPointerLocation.y - lastSyntheticPointerLocation.y) < 2 else {
            return
        }
        postMouseMoveWithoutPause(to: originalPointerLocation)
    }

    // MARK: - Mouse Clicks

    /// Moves the pointer to the target and performs a single left click.
    /// The move happens first so hover/tooltip state updates and the real
    /// pointer visibly lands where the user just saw the triangle point.
    static func performSingleClick(at coreGraphicsGlobalPoint: CGPoint) async {
        await postMouseMove(to: coreGraphicsGlobalPoint)
        await postMouseClickPair(at: coreGraphicsGlobalPoint, clickState: 1)
    }

    /// Performs a left double-click. macOS recognizes a double-click only when
    /// the second down/up pair carries a rising click-state of 2 on the SAME
    /// location; otherwise most apps treat it as two separate single clicks.
    static func performDoubleClick(at coreGraphicsGlobalPoint: CGPoint) async {
        await postMouseMove(to: coreGraphicsGlobalPoint)
        await postMouseClickPair(at: coreGraphicsGlobalPoint, clickState: 1)
        await postMouseClickPair(at: coreGraphicsGlobalPoint, clickState: 2)
    }

    private static func postMouseMove(to point: CGPoint) async {
        postMouseMoveWithoutPause(to: point)
        // Give the target app a beat to register the hover before the click.
        await interEventPause()
    }

    private static func postMouseMoveWithoutPause(to point: CGPoint) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        postTaggedEvent(CGEvent(mouseEventSource: eventSource,
                                mouseType: .mouseMoved,
                                mouseCursorPosition: point,
                                mouseButton: .left))
        lastSyntheticPointerLocation = point
    }

    private static func postMouseClickPair(at point: CGPoint, clickState: Int64) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        let mouseDown = CGEvent(mouseEventSource: eventSource,
                                mouseType: .leftMouseDown,
                                mouseCursorPosition: point,
                                mouseButton: .left)
        mouseDown?.setIntegerValueField(.mouseEventClickState, value: clickState)
        postTaggedEvent(mouseDown)

        await interEventPause()

        let mouseUp = CGEvent(mouseEventSource: eventSource,
                              mouseType: .leftMouseUp,
                              mouseCursorPosition: point,
                              mouseButton: .left)
        mouseUp?.setIntegerValueField(.mouseEventClickState, value: clickState)
        postTaggedEvent(mouseUp)
    }

    // MARK: - Scroll

    /// Scrolls at the given point. Line-based units are more broadly compatible
    /// across native apps than pixel-based scrolling.
    static func performScroll(at coreGraphicsGlobalPoint: CGPoint,
                              direction: ScrollDirection,
                              scrollAmountInLines: Int32 = 6) async {
        await postMouseMove(to: coreGraphicsGlobalPoint)

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let verticalDelta: Int32
        let horizontalDelta: Int32
        switch direction {
        case .up:    verticalDelta = scrollAmountInLines;  horizontalDelta = 0
        case .down:  verticalDelta = -scrollAmountInLines; horizontalDelta = 0
        case .left:  verticalDelta = 0;  horizontalDelta = scrollAmountInLines
        case .right: verticalDelta = 0;  horizontalDelta = -scrollAmountInLines
        }

        postTaggedEvent(CGEvent(scrollWheelEvent2Source: eventSource,
                                units: .line,
                                wheelCount: 2,
                                wheel1: verticalDelta,
                                wheel2: horizontalDelta,
                                wheel3: 0))
    }

    // MARK: - Typing Arbitrary Text

    /// Types the given string into whatever currently has keyboard focus.
    /// Uses keyboardSetUnicodeString so any Unicode (accents, emoji, non-Latin
    /// scripts) is typed directly without needing a per-character keycode table.
    ///
    /// Async on purpose: it yields between characters instead of blocking the
    /// main thread, so the Esc / user-takeover monitor (an event tap on the
    /// main run loop) keeps working mid-string. `shouldContinue` is checked
    /// before every character so a stop lands within one keystroke.
    /// Returns false if typing was stopped early.
    @discardableResult
    static func typeText(_ text: String, shouldContinue: () -> Bool = { true }) async -> Bool {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        // Emit one key-down/key-up pair per character so long strings type
        // reliably and focus/auto-complete handlers see discrete events.
        for character in text {
            guard shouldContinue() else { return false }

            // Newlines and tabs as real key presses: as unicode strings many
            // apps ignore them or insert a literal character.
            if character == "\n" || character == "\r\n" || character == "\r" {
                await performKeyCombo(modifiers: [], modifierKeyCodes: [], keyCode: CGKeyCode(kVK_Return))
            } else if character == "\t" {
                await performKeyCombo(modifiers: [], modifierKeyCodes: [], keyCode: CGKeyCode(kVK_Tab))
            } else {
                var utf16CodeUnits = Array(String(character).utf16)

                // Explicitly clear modifier flags: if the user is still holding
                // a key (e.g. the ctrl+option push-to-talk combo), inherited
                // flags would turn literal text into shortcuts.
                let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                keyDown?.flags = []
                keyDown?.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count,
                                                  unicodeString: &utf16CodeUnits)
                postTaggedEvent(keyDown)

                let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
                keyUp?.flags = []
                keyUp?.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count,
                                                unicodeString: &utf16CodeUnits)
                postTaggedEvent(keyUp)
            }

            // Brief pacing: slower apps drop characters typed with zero gap.
            try? await Task.sleep(nanoseconds: 6_000_000)
        }
        return true
    }

    // MARK: - Key Combos

    /// Presses a key combo written as "cmd+s", "cmd+shift+z", "return", etc.
    /// Returns false — and presses nothing — if any part of the combo isn't a
    /// key elfhub knows, so a typo never turns into a different shortcut.
    @discardableResult
    static func performKeyCombo(comboString: String) async -> Bool {
        guard let resolvedCombo = resolveKeyCombo(
            from: comboString,
            characterKeyCodeForCurrentLayout: currentKeyboardLayoutCharacterKeyCodes()
        ) else {
            return false
        }
        await performKeyCombo(
            modifiers: resolvedCombo.modifiers,
            modifierKeyCodes: resolvedCombo.modifierKeyCodes,
            keyCode: resolvedCombo.keyCode
        )
        return true
    }

    /// Presses the modifier keys down one by one (as a person would), taps the
    /// key, then releases the modifiers in reverse order. Some apps only react
    /// to shortcuts whose modifiers were really pressed, not just flagged.
    static func performKeyCombo(modifiers: CGEventFlags, modifierKeyCodes: [CGKeyCode], keyCode: CGKeyCode) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)

        var heldModifierFlags: CGEventFlags = []
        var pressedModifierKeyCodes: [CGKeyCode] = []
        // Release whatever was pressed even if something below goes wrong,
        // so no modifier is ever left stuck down.
        defer {
            for modifierKeyCode in pressedModifierKeyCodes.reversed() {
                heldModifierFlags.remove(modifierFlag(forModifierKeyCode: modifierKeyCode))
                let modifierUp = CGEvent(keyboardEventSource: eventSource, virtualKey: modifierKeyCode, keyDown: false)
                modifierUp?.flags = heldModifierFlags
                postTaggedEvent(modifierUp)
            }
        }

        for modifierKeyCode in modifierKeyCodes {
            heldModifierFlags.insert(modifierFlag(forModifierKeyCode: modifierKeyCode))
            let modifierDown = CGEvent(keyboardEventSource: eventSource, virtualKey: modifierKeyCode, keyDown: true)
            modifierDown?.flags = heldModifierFlags
            postTaggedEvent(modifierDown)
            pressedModifierKeyCodes.append(modifierKeyCode)
        }

        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = modifiers
        postTaggedEvent(keyDown)

        await interEventPause()

        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = modifiers
        postTaggedEvent(keyUp)
    }

    // MARK: - Key Combo Parsing

    struct ResolvedKeyCombo: Equatable {
        let modifiers: CGEventFlags
        /// The physical modifier keys to hold, in the order they're pressed.
        let modifierKeyCodes: [CGKeyCode]
        let keyCode: CGKeyCode

        static func == (lhs: ResolvedKeyCombo, rhs: ResolvedKeyCombo) -> Bool {
            lhs.modifiers.rawValue == rhs.modifiers.rawValue
                && lhs.modifierKeyCodes == rhs.modifierKeyCodes
                && lhs.keyCode == rhs.keyCode
        }
    }

    /// Splits a "cmd+shift+s" style string into modifiers plus exactly one
    /// terminal key. The terminal key may be a named key ("return", "f5",
    /// "page_down") or a single character ("s", "/", "é"). Single characters
    /// use the user's CURRENT keyboard layout first (so "cmd+z" presses the
    /// key labeled Z on an AZERTY or QWERTZ keyboard), then the US layout.
    ///
    /// Returns nil when the combo has no terminal key, more than one, or any
    /// part elfhub doesn't recognize — never a guess.
    static func resolveKeyCombo(
        from comboString: String,
        characterKeyCodeForCurrentLayout: [String: CGKeyCode] = [:]
    ) -> ResolvedKeyCombo? {
        var normalizedComboString = comboString.lowercased().trimmingCharacters(in: .whitespaces)
        // "cmd++" means cmd with the plus key; splitting on "+" would lose it.
        var terminalPlusKey = false
        if normalizedComboString.hasSuffix("++") || normalizedComboString == "+" {
            terminalPlusKey = true
            normalizedComboString = String(normalizedComboString.dropLast())
        }

        let tokens = normalizedComboString
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var accumulatedModifiers: CGEventFlags = []
        var modifierKeyCodes: [CGKeyCode] = []
        var terminalKeyCode: CGKeyCode? = terminalPlusKey ? CGKeyCode(kVK_ANSI_Equal) : nil

        for token in tokens {
            if let modifier = modifierKey(for: token) {
                if !accumulatedModifiers.contains(modifier.flag) {
                    accumulatedModifiers.insert(modifier.flag)
                    modifierKeyCodes.append(modifier.keyCode)
                }
                continue
            }
            guard terminalKeyCode == nil,
                  let tokenKeyCode = keyCode(forTerminalToken: token, characterKeyCodeForCurrentLayout: characterKeyCodeForCurrentLayout) else {
                // A second terminal key, or something unknown: refuse.
                return nil
            }
            terminalKeyCode = tokenKeyCode
        }

        guard let keyCode = terminalKeyCode else { return nil }
        return ResolvedKeyCombo(modifiers: accumulatedModifiers, modifierKeyCodes: modifierKeyCodes, keyCode: keyCode)
    }

    /// The modifier flag and physical key for a modifier name. "super",
    /// "meta" and "win" are what other tools (and some models) call ⌘.
    static func modifierKey(for token: String) -> (flag: CGEventFlags, keyCode: CGKeyCode)? {
        switch token {
        case "cmd", "command", "super", "meta", "win", "windows": return (.maskCommand, CGKeyCode(kVK_Command))
        case "shift":                                            return (.maskShift, CGKeyCode(kVK_Shift))
        case "opt", "option", "alt":                             return (.maskAlternate, CGKeyCode(kVK_Option))
        case "ctrl", "control":                                  return (.maskControl, CGKeyCode(kVK_Control))
        case "fn", "function":                                   return (.maskSecondaryFn, CGKeyCode(kVK_Function))
        default:                                                 return nil
        }
    }

    static func modifierFlag(for token: String) -> CGEventFlags? {
        modifierKey(for: token)?.flag
    }

    private static func modifierFlag(forModifierKeyCode modifierKeyCode: CGKeyCode) -> CGEventFlags {
        switch Int(modifierKeyCode) {
        case kVK_Command: return .maskCommand
        case kVK_Shift: return .maskShift
        case kVK_Option: return .maskAlternate
        case kVK_Control: return .maskControl
        case kVK_Function: return .maskSecondaryFn
        default: return []
        }
    }

    private static func keyCode(
        forTerminalToken token: String,
        characterKeyCodeForCurrentLayout: [String: CGKeyCode]
    ) -> CGKeyCode? {
        // Named keys, ignoring "_" / "-" / spaces so "page_down", "page-down"
        // and "pagedown" all work.
        let compactToken = token.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let namedKeyCode = namedKeyCodes[compactToken] {
            return namedKeyCode
        }
        guard token.count == 1 else { return nil }
        return characterKeyCodeForCurrentLayout[token] ?? usLayoutCharacterKeyCodes[token]
    }

    /// Keys with names. "delete" is the Mac's delete key (backspace);
    /// "forwarddelete" is the ⌦ key.
    static let namedKeyCodes: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "keypadenter": CGKeyCode(kVK_ANSI_KeypadEnter), "kpenter": CGKeyCode(kVK_ANSI_KeypadEnter),
        "tab": CGKeyCode(kVK_Tab),
        "space": CGKeyCode(kVK_Space), "spacebar": CGKeyCode(kVK_Space),
        "esc": CGKeyCode(kVK_Escape), "escape": CGKeyCode(kVK_Escape),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete), "del": CGKeyCode(kVK_ForwardDelete),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "uparrow": CGKeyCode(kVK_UpArrow), "downarrow": CGKeyCode(kVK_DownArrow),
        "leftarrow": CGKeyCode(kVK_LeftArrow), "rightarrow": CGKeyCode(kVK_RightArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "pgup": CGKeyCode(kVK_PageUp), "pgdn": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
        "minus": CGKeyCode(kVK_ANSI_Minus), "hyphen": CGKeyCode(kVK_ANSI_Minus),
        "equal": CGKeyCode(kVK_ANSI_Equal), "equals": CGKeyCode(kVK_ANSI_Equal), "plus": CGKeyCode(kVK_ANSI_Equal),
        "comma": CGKeyCode(kVK_ANSI_Comma), "period": CGKeyCode(kVK_ANSI_Period),
        "slash": CGKeyCode(kVK_ANSI_Slash), "backslash": CGKeyCode(kVK_ANSI_Backslash),
        "semicolon": CGKeyCode(kVK_ANSI_Semicolon), "quote": CGKeyCode(kVK_ANSI_Quote),
        "leftbracket": CGKeyCode(kVK_ANSI_LeftBracket), "rightbracket": CGKeyCode(kVK_ANSI_RightBracket),
        "grave": CGKeyCode(kVK_ANSI_Grave), "backtick": CGKeyCode(kVK_ANSI_Grave),
    ]

    /// Character keys on a US keyboard: the fallback when the current layout
    /// has no key for a character.
    static let usLayoutCharacterKeyCodes: [String: CGKeyCode] = [
        // Letters
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        // Digits
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        // Punctuation
        "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal),
        "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
        "\\": CGKeyCode(kVK_ANSI_Backslash), ";": CGKeyCode(kVK_ANSI_Semicolon),
        "'": CGKeyCode(kVK_ANSI_Quote), ",": CGKeyCode(kVK_ANSI_Comma),
        ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash),
        "`": CGKeyCode(kVK_ANSI_Grave),
    ]

    /// Which key types each character on the user's current keyboard layout
    /// (no modifiers held). Read fresh each time because the user can switch
    /// input sources at any moment.
    static func currentKeyboardLayoutCharacterKeyCodes() -> [String: CGKeyCode] {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        var characterKeyCodes: [String: CGKeyCode] = [:]
        layoutData.withUnsafeBytes { rawLayoutBytes in
            guard let keyboardLayout = rawLayoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Lower key codes are the main keyboard; the keypad's digits come
            // later, so the first key found for a character wins.
            for virtualKeyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var producedCharacters = [UniChar](repeating: 0, count: 4)
                var producedCharacterCount = 0
                let translateStatus = UCKeyTranslate(
                    keyboardLayout,
                    UInt16(virtualKeyCode),
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    producedCharacters.count,
                    &producedCharacterCount,
                    &producedCharacters
                )
                guard translateStatus == noErr, producedCharacterCount == 1 else { continue }
                let character = String(utf16CodeUnits: producedCharacters, count: producedCharacterCount).lowercased()
                guard let firstScalar = character.unicodeScalars.first, firstScalar.value >= 0x20 else { continue }
                if characterKeyCodes[character] == nil {
                    characterKeyCodes[character] = CGKeyCode(virtualKeyCode)
                }
            }
        }
        return characterKeyCodes
    }

    // MARK: - Timing

    /// A short pause between paired events (move→down, down→up). Real
    /// hardware never fires these instantaneously, and some apps drop events
    /// that arrive with zero gap. Async so it never blocks the main actor.
    private static func interEventPause() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
