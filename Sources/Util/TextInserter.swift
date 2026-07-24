import AppKit
import ApplicationServices

/// Inserts dictated text into the frontmost app (Wispr Flow style): always copies to the
/// clipboard, and — if Accessibility is granted — synthesizes ⌘V to paste at the cursor.
enum TextInserter {
    /// True if we can synthesize key events (needed for auto-paste).
    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func insert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // No editable field (or no Accessibility to check) → leave the text on the clipboard for the
        // "no input field" card to show/re-copy, and report false so the caller shows it.
        guard canAutoPaste, hasEditableFocus() else {
            writeConcealed(trimmed)
            return false
        }
        // Editable field → paste at the caret WITHOUT clobbering the user's clipboard: snapshot it,
        // put our text, ⌘V, then restore the snapshot. (Same as Wispr Flow — clipboard stays intact.)
        let saved = snapshot()
        writeConcealed(trimmed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { restore(saved) }
        }
        return true
    }

    /// Dictated text can be private (passwords, notes) — mark it concealed/transient so clipboard
    /// managers and Universal Clipboard don't archive or sync it across devices.
    private static func writeConcealed(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
    }

    private static func snapshot() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { old in
            let copy = NSPasteboardItem()
            for type in old.types { if let data = old.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// True if the system-wide focused UI element is an editable text control.
    static func hasEditableFocus() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String,
           role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) || role == (kAXComboBoxRole as String) {
            return true
        }
        // Fallback: any element whose value is settable behaves like an editable field (web inputs).
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    /// Ask for Accessibility once (shows the system prompt if not yet decided).
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09   // "V"
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
