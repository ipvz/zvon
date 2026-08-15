import AppKit
import ApplicationServices

/// Inserts dictated text into the frontmost app (Wispr Flow style): always copies to the
/// clipboard, and — if Accessibility is granted — synthesizes ⌘V to paste at the cursor.
enum TextInserter {
    /// True if we can synthesize key events (needed for auto-paste).
    static var canAutoPaste: Bool { AXIsProcessTrusted() }

    // The user's real clipboard, captured once and restored after the paste settles. A restore in
    // flight means a dictation is mid-cycle: a second rapid dictation must NOT re-snapshot (it would
    // capture the first one's concealed text and lose the user's original) — it reuses this baseline.
    private static var savedOriginal: [NSPasteboardItem]?
    private static var pendingPaste: DispatchWorkItem?
    private static var pendingRestore: DispatchWorkItem?
    /// `changeCount` of the pasteboard right after WE wrote to it. Anything else means someone
    /// (the user, a clipboard manager) has written since, and our bookkeeping is stale.
    private static var ourChangeCount = -1

    /// How long our text stays on the pasteboard before the user's clipboard goes back.
    ///
    /// ⌘V is delivered asynchronously: the target app reads the pasteboard whenever it gets around
    /// to processing the key event. Restore too early and the app reads the RESTORED clipboard —
    /// the dictation silently inserts whatever the user had copied before. That was this code at
    /// 0.25s, and it lost the race on any loaded machine or heavy Electron target. A second and a
    /// half costs nothing (the clipboard is merely occupied) and clears the window with room spare.
    private static let restoreDelay: TimeInterval = 1.5
    /// Let the pasteboard write settle and the trigger key finish releasing before ⌘V goes out.
    private static let pasteDelay: TimeInterval = 0.05

    @discardableResult
    static func insert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // No editable field (or no Accessibility to check) → leave the text on the clipboard for the
        // "no input field" card to show/re-copy, and report false so the caller shows it.
        guard canAutoPaste, hasEditableFocus() else {
            ourChangeCount = writeConcealed(trimmed)
            return false
        }
        // Editable field → paste at the caret WITHOUT clobbering the user's clipboard: snapshot it,
        // put our text, ⌘V, then restore the snapshot. (Same as Wispr Flow — clipboard stays intact.)
        pendingPaste?.cancel()                           // a newer dictation supersedes an unsent ⌘V
        pendingRestore?.cancel()                         // …and its pending restore
        if savedOriginal == nil { savedOriginal = snapshot() }   // capture the user's clipboard only once per cycle
        ourChangeCount = writeConcealed(trimmed)

        let pasteWork = DispatchWorkItem {
            pendingPaste = nil
            // Between the write and now, a clipboard manager may have rewritten the pasteboard.
            // Paste what the user dictated, not what a background app decided to put there.
            if NSPasteboard.general.changeCount != ourChangeCount {
                DebugLog.log("insert: pasteboard changed before ⌘V — rewriting dictated text")
                ourChangeCount = writeConcealed(trimmed)
            }
            paste()
            scheduleRestore()
        }
        pendingPaste = pasteWork
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay, execute: pasteWork)
        return true
    }

    private static func scheduleRestore() {
        let work = DispatchWorkItem {
            defer { savedOriginal = nil; pendingRestore = nil }
            // Something wrote after us, so the pasteboard now holds content NEWER than our snapshot.
            // Restoring would throw the user's fresh copy away; leave it alone.
            guard NSPasteboard.general.changeCount == ourChangeCount else {
                DebugLog.log("insert: clipboard changed after paste — keeping it, no restore")
                return
            }
            restore(savedOriginal ?? [])
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    /// Dictated text can be private (passwords, notes) — mark it concealed/transient so clipboard
    /// managers and Universal Clipboard don't archive or sync it across devices.
    @discardableResult
    private static func writeConcealed(_ text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        return pb.changeCount
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

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
        "AXSearchField",
    ]

    /// True if the focused UI element is somewhere a caret can live.
    ///
    /// Deliberately generous. A false negative breaks dictation for the user every single time —
    /// the caret is blinking in a real field and we refuse to paste — while a false positive costs
    /// at most a ⌘V that the frontmost app ignores. The old test asked only for three AX roles or a
    /// settable value, which misses most of the places people actually type: Electron and Chromium
    /// surfaces (Slack, VS Code, Notion, every web input) expose a generic group, or expose nothing
    /// at all until accessibility is switched on for them explicitly.
    static func hasEditableFocus() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let element = focusedElement() else {
            DebugLog.log("insert: no focused AX element")
            return false
        }
        if isEditable(element) { return true }
        // contenteditable and rich composers report the caret on an ancestor, not on the focused node.
        var current = element
        for _ in 0..<4 {
            guard let parent = attribute(current, kAXParentAttribute as String) else { break }
            if isEditable(parent) { return true }
            current = parent
        }
        DebugLog.log("insert: focus not editable (role=\(role(of: element) ?? "nil"))")
        return false
    }

    /// The focused element, asking the frontmost app directly when the system-wide query comes up
    /// empty — and switching on accessibility for Chromium/Electron hosts, which ship their tree
    /// hidden until an assistive client asks for it.
    private static func focusedElement() -> AXUIElement? {
        if let e = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) { return e }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let e = attribute(app, kAXFocusedUIElementAttribute as String) { return e }
        // Last resort: the focused window's own focused element.
        guard let window = attribute(app, kAXFocusedWindowAttribute as String) else { return nil }
        return attribute(window, kAXFocusedUIElementAttribute as String)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let r = role(of: element)
        if let r, editableRoles.contains(r) { return true }

        // A selection range or an insertion-point line means a caret genuinely lives here. Checked
        // BEFORE any role exclusion: this is the stronger signal, and web inputs and custom editors
        // expose it while reporting themselves as plain groups.
        for attr in [kAXSelectedTextRangeAttribute as String, "AXInsertionPointLineNumber"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success, value != nil { return true }
        }

        // A settable value alone is weak evidence — sliders and checkboxes have one too — so it does
        // not count for things a caret plainly cannot sit in.
        if let r, r == (kAXStaticTextRole as String) || r == (kAXButtonRole as String)
            || r == (kAXImageRole as String) || r == (kAXCheckBoxRole as String)
            || r == (kAXSliderRole as String) || r == (kAXMenuItemRole as String) {
            return false
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Ask for Accessibility once (shows the system prompt if not yet decided).
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func paste() {
        // `.privateState`, not `.combinedSessionState`: the latter merges the REAL keyboard state
        // into synthetic events, so a trigger modifier still physically held turns our ⌘V into
        // ⌥⌘V / ⇧⌘V — a different command in many apps.
        let src = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 0x09   // "V"
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
