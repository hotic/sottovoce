import AppKit
import ApplicationServices

/// Writes preview text straight into the focused text field (like an input method) and replaces it in place
/// with the final text.
///
/// Uses the Accessibility API: writes AXSelectedText at the cursor and remembers the position and length, so the
/// next update selects that range and replaces it. Every write is read back to verify; if it can't be read back
/// (terminals, some custom-drawn controls) the inline preview is abandoned and the final text falls back to a
/// clipboard paste.
@MainActor
final class InlineComposer {
    enum FocusKind {
        /// An editable text control
        case editable
        /// Clearly not a text field (desktop, file list, button…)
        case notEditable
        /// No focused element, or can't tell; just paste as usual
        case unknown
    }

    private var element: AXUIElement?
    /// Write position (UTF-16 offset, matching AX ranges)
    private var start = 0
    /// Text currently written
    private var text = ""
    /// The control doesn't support writing or the user edited the content; stop trying
    private var broken = false
    /// Electron processes whose accessibility tree has already been enabled
    private var enabledPids = Set<pid_t>()

    private let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        // Don't block the main thread when the target app hangs
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }()

    var isActive: Bool { element != nil && !text.isEmpty && !broken }

    /// Replace the previously written text with a new preview; if focus moved, clear the preview from the old
    /// control and write into the new one
    func update(_ preview: String) {
        let focused = focusedElement()
        if !same(focused, element) {
            discard()
            guard let focused, classify(focused) == .editable else { return }
            element = focused
            broken = false
            text = ""
            start = selectedRange(focused)?.location ?? 0
        }
        guard let el = element, !broken, preview != text else { return }
        if !text.isEmpty {
            // Leave it alone if the user edited the content meanwhile
            guard string(el, at: start, length: text.utf16.count) == text else { broken = true; return }
            setSelectedRange(el, CFRange(location: start, length: text.utf16.count))
        }
        guard write(el, preview) else { broken = true; return }
        text = preview
    }

    /// Finalize: replace the preview with the final text. Returns false when there is no inline preview to replace,
    /// and the caller inserts the text another way
    func commit(_ final: String) -> Bool {
        guard let el = element, !broken, !text.isEmpty else { reset(); return false }
        // Focus moved elsewhere: clear the preview from the old control and let the caller insert at the new focus
        guard same(focusedElement(), el) else { discard(); return false }
        defer { reset() }
        guard string(el, at: start, length: text.utf16.count) == text else { return false }
        setSelectedRange(el, CFRange(location: start, length: text.utf16.count))
        if write(el, final) { return true }
        // The AX write failed but the preview is selected, so pasting replaces it
        TextInserter.insert(final)
        return true
    }

    /// Cancel: remove the preview that was written
    func discard() {
        defer { reset() }
        guard let el = element, !broken, !text.isEmpty,
              string(el, at: start, length: text.utf16.count) == text else { return }
        setSelectedRange(el, CFRange(location: start, length: text.utf16.count))
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, "" as CFTypeRef)
    }

    /// Whether the current focus is a text field
    func focusKind() -> FocusKind {
        guard let el = focusedElement() else { return .unknown }
        return classify(el)
    }

    private func reset() {
        element = nil
        text = ""
        broken = false
    }

    /// Write and verify by reading back; on success move the cursor to the end
    private func write(_ el: AXUIElement, _ s: String) -> Bool {
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFTypeRef) == .success,
              string(el, at: start, length: s.utf16.count) == s else { return false }
        setSelectedRange(el, CFRange(location: start + s.utf16.count, length: 0))
        return true
    }

    /// Focused element of the frontmost app. On macOS 27 asking the system-wide element for focus returns
    /// kAXErrorCannotComplete, so ask the app instead
    private func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        if let el = copyElement(appEl, kAXFocusedUIElementAttribute) { return el }
        // Electron / Chromium apps don't build an accessibility tree by default, so focus is unavailable;
        // enable AXManualAccessibility and try again
        guard !enabledPids.contains(pid) else { return copyElement(systemWide, kAXFocusedUIElementAttribute) }
        enabledPids.insert(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return copyElement(appEl, kAXFocusedUIElementAttribute) ?? copyElement(systemWide, kAXFocusedUIElementAttribute)
    }

    /// Controls that are clearly not text input. Only these make it wait for the user to click a text field;
    /// anything uncertain (web areas, groups, custom-drawn controls) is treated as a text field, so apps with
    /// nonstandard control roles like WeChat and Chrome don't get stuck at "Click a text field"
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXImage", "AXMenuItem", "AXMenuBarItem", "AXWindow", "AXTabGroup", "AXToolbar",
        "AXSplitGroup", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
    ]

    private func classify(_ el: AXUIElement) -> FocusKind {
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        let r = role as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return .editable }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return .editable
        }
        // The Finder desktop is an AXGroup with the AXDesktop subrole
        if subrole as? String == "AXDesktop" || Self.nonTextRoles.contains(r) { return .notEditable }
        return .unknown
    }

    private func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }

    private func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    private func setSelectedRange(_ el: AXUIElement, _ range: CFRange) {
        var r = range
        if let v = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
    }

    /// Read the text in a range: prefer the parameterized string-for-range attribute, falling back to slicing the
    /// whole value when unsupported
    private func string(_ el: AXUIElement, at location: Int, length: Int) -> String? {
        var r = CFRange(location: location, length: length)
        if let rv = AXValueCreate(.cfRange, &r) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
               let s = out as? String {
                return s
            }
        }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let all = v as? String else { return nil }
        let ns = all as NSString
        guard location >= 0, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }
}
