import AppKit
import ApplicationServices

/// Inserts dictated text into the frontmost app (Wispr Flow style): if Accessibility is granted
/// and a caret is focused, borrows the clipboard for a ⌘V and gives it back. The user's clipboard is
/// never left holding dictated text — when there is nowhere to paste, the text goes to the
/// "no input field" card (which has a Copy button) and the clipboard is not touched at all.
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

    static var hasPendingInsertion: Bool { pendingPaste != nil || pendingRestore != nil }

    /// Keep the process alive until the posted paste and clipboard restoration
    /// settle. Quitting immediately after dictation otherwise loses the original clipboard.
    @MainActor static func finishBeforeQuit() async {
        while hasPendingInsertion {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
    }

    @discardableResult
    static func insert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // No editable field (or no Accessibility to check) → report false so the caller shows the
        // card. The clipboard stays as the user left it: overwriting it here with nothing to
        // restore it later is how a copied snippet got replaced by the last dictation.
        guard canAutoPaste, shouldPaste() else { return false }
        // Editable field → paste at the caret WITHOUT clobbering the user's clipboard: snapshot it,
        // put our text, ⌘V, then restore the snapshot. (Same as Wispr Flow — clipboard stays intact.)
        pendingPaste?.cancel()                           // a newer dictation supersedes an unsent ⌘V
        pendingRestore?.cancel()                         // …and its pending restore
        if savedOriginal == nil {                         // capture the user's clipboard only once per cycle
            savedOriginal = snapshot()
            DebugLog.log("insert: saved clipboard (\(savedOriginal?.count ?? 0) items)")
        }
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
            scheduleRestore(dictated: trimmed)
        }
        pendingPaste = pasteWork
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay, execute: pasteWork)
        return true
    }

    private static func scheduleRestore(dictated: String) {
        let work = DispatchWorkItem {
            defer { savedOriginal = nil; pendingRestore = nil }
            // Something wrote after us, so the pasteboard may hold content NEWER than our snapshot,
            // and restoring would throw the user's fresh copy away. But a clipboard manager that
            // re-writes what it saw also bumps the count while the content is still our dictated
            // text — leaving that in place would lose the original — so only skip the restore when
            // the pasteboard holds something other than what we put there.
            let pb = NSPasteboard.general
            if pb.changeCount != ourChangeCount, pb.string(forType: .string) != dictated {
                DebugLog.log("insert: clipboard changed after paste — keeping it, no restore")
                return
            }
            restore(savedOriginal ?? [])
            DebugLog.log("insert: clipboard restored (\(savedOriginal?.count ?? 0) items)")
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

    /// Whether to send ⌘V: yes unless focus is positively somewhere text cannot go.
    ///
    /// The log shows what the old "is this an editable field?" test did in practice: of ~430
    /// refusals, 405 were "no focused AX element" — Electron, Telegram, web apps and anything else
    /// whose accessibility tree is empty or lags behind the caret — and the rest were web areas,
    /// groups and windows that host a perfectly good caret. In every one of those the user was typing
    /// into a field and got a "select a field first" card instead of their text. A wrong refusal
    /// costs the dictation every time; a wrong ⌘V costs a keystroke the frontmost app ignores. So
    /// only a focus that is clearly a button, label, checkbox and the like is refused.
    static func shouldPaste() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let element = focusedElement() else {
            DebugLog.log("insert: no focused AX element — pasting anyway")
            return true
        }
        if isEditable(element) { return true }
        // contenteditable and rich composers report the caret on an ancestor, not on the focused node.
        var current = element
        for _ in 0..<4 {
            guard let parent = attribute(current, kAXParentAttribute as String) else { break }
            if isEditable(parent) { return true }
            current = parent
        }
        let r = role(of: element)
        if let r, notTextRoles.contains(r) {
            DebugLog.log("insert: focus is not a text target (role=\(r))")
            return false
        }
        DebugLog.log("insert: focus role unclear (role=\(r ?? "nil")) — pasting anyway")
        return true
    }

    /// Controls a caret can never sit in. Everything else — including roles that merely say nothing,
    /// like a web area, a group or a window — is given the benefit of the doubt.
    private static let notTextRoles: Set<String> = [
        kAXStaticTextRole as String, kAXButtonRole as String, kAXImageRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXSliderRole as String,
        kAXMenuItemRole as String, kAXMenuBarItemRole as String,
    ]

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
