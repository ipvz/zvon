import AppKit
import SwiftUI
import Combine

// MARK: - Menu bar (ONE grouped status item: Parley mark │ divider │ tasks — routed by click x)

/// A single status item drawn as one grouped strip (per mockup): the Parley mark (+ recording
/// timer/dot) on the left, a hairline divider, then the tasks glyph + open-count badge on the right.
/// Two separate NSStatusItems can't be kept adjacent (the system spaces them and other apps' items
/// interleave), so both live in one button and the click is routed by x-position to the right popover.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: TranscriptStore
    private let tasks: TaskStore
    private let statusItem: NSStatusItem
    private let mainPopover = NSPopover()
    private let tasksPopover = NSPopover()
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var dividerX: CGFloat = 0   // button-space boundary: click left → main, right → tasks

    init(store: TranscriptStore, tasks: TaskStore = .shared) {
        self.store = store
        self.tasks = tasks
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.action = #selector(handleClick(_:))
            button.target = self
        }
        for p in [mainPopover, tasksPopover] { p.behavior = .transient; p.delegate = self }
        mainPopover.contentViewController = NSHostingController(
            rootView: MenuBarPopover(store: store, closePopover: { [weak self] in self?.mainPopover.performClose(nil) }))
        tasksPopover.contentViewController = NSHostingController(
            rootView: TasksMenuPopover(store: store, closePopover: { [weak self] in self?.tasksPopover.performClose(nil) }))

        // Discrete state only — NOT `levels` (churns ~25×/s). The 1s timer drives the clock and
        // also picks up menu-bar appearance changes (dark/light) within a second.
        cancellable = Publishers.MergeMany(
            store.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            store.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            store.$showMenuBar.map { _ in () }.eraseToAnyPublisher(),
            tasks.$tasks.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in Task { @MainActor in self?.updateButton() } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateButton() }
        }
        updateButton()
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let x = button.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil).x
        let wantTasks = x >= dividerX
        let show = wantTasks ? tasksPopover : mainPopover
        let other = wantTasks ? mainPopover : tasksPopover
        if other.isShown { other.performClose(sender) }
        if show.isShown { show.performClose(sender) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            // Both popovers drop from the SAME point — the divider — so the pop origin is stable no
            // matter which half was clicked (and doesn't wander as the timer/badge width changes).
            let anchor = NSRect(x: dividerX - 5, y: 0, width: 10, height: button.bounds.height)
            show.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        }
    }

    private func updateButton() {
        statusItem.isVisible = store.showMenuBar
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let timerText: String? = {
            guard store.isRecording else { return nil }
            let s = Int(store.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
            return String(format: "%d:%02d", s / 60, s % 60)
        }()
        let built = Self.composite(dark: dark, recording: store.isRecording, paused: store.isPaused,
                                   timer: timerText, count: tasks.open.count)
        button.image = built.image
        dividerX = built.dividerX
    }

    /// One image: [3-bar mark] [timer ●]? │ [checkmark.circle] [count badge]?. Returns the divider's
    /// x (in image points == button points) so the click handler can route left/right. Non-template
    /// (the clay badge/dot must keep their color) so ink is chosen from the menu-bar appearance.
    static func composite(dark: Bool, recording: Bool, paused: Bool, timer: String?, count: Int)
        -> (image: NSImage, dividerX: CGFloat) {
        let ink = dark ? NSColor(calibratedWhite: 0.90, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)
        // ZVON: red only for the recording dot; the tasks badge uses teal.
        let rec = NSColor(srgbRed: 0xDE / 255, green: 0x3E / 255, blue: 0x2D / 255, alpha: 1)
        let clay = dark ? NSColor(srgbRed: 0x00 / 255, green: 0xC4 / 255, blue: 0xC4 / 255, alpha: 1)
                        : NSColor(srgbRed: 0x00 / 255, green: 0x97 / 255, blue: 0x98 / 255, alpha: 1)
        let cream = dark ? NSColor(srgbRed: 0x04 / 255, green: 0x20 / 255, blue: 0x1F / 255, alpha: 1) : NSColor.white
        let H: CGFloat = 22
        let markH: CGFloat = 13
        let markW: CGFloat = Brand.menubarGlyph.map { markH * ($0.size.width / max(1, $0.size.height)) } ?? 10
        let tFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let timerW: CGFloat = timer.map { ($0 as NSString).size(withAttributes: [.font: tFont]).width + 5 } ?? 0
        let dotW: CGFloat = (recording && !paused) ? 8 : 0            // 4 gap + 4 dot
        let dividerGap: CGFloat = 6, dividerW: CGFloat = 1
        let checkSize: CGFloat = 14
        let bFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let badgeH: CGFloat = 15
        let badgeText = count > 0 ? "\(count)" : ""
        let badgeBoxW: CGFloat = count > 0
            ? max(badgeH, (badgeText as NSString).size(withAttributes: [.font: bFont]).width + 9) : 0
        let badgeW: CGFloat = count > 0 ? 4 + badgeBoxW : 0           // 4 gap + pill

        let dividerX = markW + timerW + dotW + dividerGap            // boundary for click routing
        let totalW = markW + timerW + dotW + dividerGap + dividerW + dividerGap + checkSize + badgeW + 2

        let img = NSImage(size: NSSize(width: totalW, height: H), flipped: false) { _ in
            var x: CGFloat = 0
            // ZVON mark — draw the template glyph tinted to the menu-bar ink (fallback: 3 bars).
            if let g = Brand.menubarGlyph {
                let r = NSRect(x: 0, y: (H - markH) / 2, width: markW, height: markH)
                g.draw(in: r)
                ink.set(); r.fill(using: .sourceAtop)
            } else {
                ink.setFill()
                var bx = x
                for h in [CGFloat(8), 13, 10] {
                    NSBezierPath(roundedRect: NSRect(x: bx, y: (H - h) / 2, width: 2, height: h), xRadius: 1, yRadius: 1).fill()
                    bx += 4
                }
            }
            x += markW
            // recording timer
            if let timer {
                x += 5
                let attrs: [NSAttributedString.Key: Any] = [.font: tFont, .foregroundColor: ink]
                let s = timer as NSString
                let ts = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: x, y: (H - ts.height) / 2), withAttributes: attrs)
                x += ts.width
            }
            if recording && !paused {
                x += 4
                rec.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: (H - 4) / 2, width: 4, height: 4)).fill()
                x += 4
            }
            // divider
            x += dividerGap
            ink.withAlphaComponent(0.30).setFill()
            NSRect(x: x, y: (H - 12) / 2, width: dividerW, height: 12).fill()
            x += dividerW + dividerGap
            // tasks glyph (SF Symbol tinted to ink)
            if let check = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
                let cs = check.size
                check.draw(in: NSRect(x: x, y: (H - cs.height) / 2, width: cs.width, height: cs.height))
            }
            x += checkSize
            // open-count badge (clay pill)
            if count > 0 {
                x += 4
                clay.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: (H - badgeH) / 2, width: badgeBoxW, height: badgeH),
                             xRadius: badgeH / 2, yRadius: badgeH / 2).fill()
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let ba: [NSAttributedString.Key: Any] = [.font: bFont, .foregroundColor: cream, .paragraphStyle: para]
                let s = badgeText as NSString
                let bs = s.size(withAttributes: ba)
                s.draw(in: NSRect(x: x, y: (H - bs.height) / 2, width: badgeBoxW, height: bs.height), withAttributes: ba)
            }
            return true
        }
        img.isTemplate = false
        return (img, dividerX)
    }
}

// MARK: - Floating widget (NSPanel)

@MainActor
final class FloatingWidgetController {
    static weak var shared: FloatingWidgetController?

    private let store: TranscriptStore
    private let panel: NSPanel
    private let hosting: NSHostingController<WidgetRootView>
    private static let posKey = "widgetOrigin"

    private var sizeCancellable: AnyCancellable?
    private var hiddenCancellable: AnyCancellable?
    private var recCancellable: AnyCancellable?
    private var collapseWork: DispatchWorkItem?

    /// Bring the widget on-screen (bottom-left) and expand it so it's easy to find.
    func reveal() {
        store.widgetHidden = false
        store.widgetSize = .expanded
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.minX + PMetric.dockInset, y: v.minY + PMetric.dockInset))
        }
        panel.orderFrontRegardless()
    }

    private func applyHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    init(store: TranscriptStore) {
        self.store = store
        hosting = NSHostingController(rootView: WidgetRootView(store: store))
        hosting.sizingOptions = .preferredContentSize

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 76, height: 76),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = hosting
        // Keep the hosting view fully transparent so only the SwiftUI puck draws (no panel backing).
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        restorePosition()
        panel.orderFrontRegardless()
        FloatingWidgetController.shared = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition), name: NSWindow.didMoveNotification, object: panel
        )
        // The panel is .preferredContentSize — it grows from its origin when the SwiftUI content
        // resizes (puck → compact → expanded). Docked at the right/top edge, that pushes it off-screen,
        // so pull it back into the visible frame after every resize.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clampIntoScreen), name: NSWindow.didResizeNotification, object: panel
        )

        // The widget only collapses by the user tapping the chevron ⌄ — never on outside clicks
        // (deliberate: it stays expanded until dismissed). We just keep it front when expanded.
        sizeCancellable = store.$widgetSize
            .removeDuplicates()
            .sink { [weak self] size in Task { @MainActor in self?.applySize(size) } }
        applySize(store.widgetSize)

        hiddenCancellable = store.$widgetHidden
            .removeDuplicates()
            .sink { [weak self] hidden in Task { @MainActor in self?.applyHidden(hidden) } }
        applyHidden(store.widgetHidden)

        // Auto-behavior (spec §4): recording starts → expand; stops → collapse after 3 s. We only
        // expand on the rising edge, so a manual collapse mid-recording is respected (not overridden).
        recCancellable = store.$isRecording
            .removeDuplicates()
            .sink { [weak self] rec in Task { @MainActor in self?.recordingChanged(rec) } }
    }

    private func recordingChanged(_ recording: Bool) {
        // Dictation also flips isRecording (it opens a mic session) — but push-to-talk must NEVER
        // drive the floating widget. Only real meeting recording expands/collapses it.
        if store.isDictating { return }
        collapseWork?.cancel()
        if recording {
            if !store.widgetHidden { store.widgetSize = .expanded }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.store.isRecording else { return }
                self.store.widgetSize = .puck
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func applySize(_ size: WidgetSize) {
        if size != .puck { panel.orderFrontRegardless() }
        clampIntoScreen()
    }

    /// Nudge the panel back on-screen if a resize pushed it past an edge (keeps a small margin).
    @objc private func clampIntoScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let f = panel.frame
        let m = PMetric.dockInset
        var o = f.origin
        if f.maxX > v.maxX { o.x = v.maxX - f.width - m }
        if o.x < v.minX { o.x = v.minX + m }
        if f.maxY > v.maxY { o.y = v.maxY - f.height - m }
        if o.y < v.minY { o.y = v.minY + m }
        if o != f.origin { panel.setFrameOrigin(o) }
    }

    private func restorePosition() {
        if let arr = UserDefaults.standard.array(forKey: Self.posKey) as? [Double], arr.count == 2 {
            panel.setFrameOrigin(NSPoint(x: arr[0], y: arr[1]))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.minX + PMetric.dockInset, y: v.minY + PMetric.dockInset))
        }
    }

    @objc private func savePosition() {
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: Self.posKey)
        scheduleSnap()
    }

    private var snapWork: DispatchWorkItem?

    /// Debounced so it fires when the user stops dragging (not on every move event).
    private func scheduleSnap() {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapToEdge() }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func snapToEdge() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let f = panel.frame
        var o = f.origin
        let inset = PMetric.dockInset, thresh: CGFloat = 26
        if o.x - v.minX < thresh { o.x = v.minX + inset }
        else if v.maxX - f.maxX < thresh { o.x = v.maxX - f.width - inset }
        if o.y - v.minY < thresh { o.y = v.minY + inset }
        else if v.maxY - f.maxY < thresh { o.y = v.maxY - f.height - inset }
        guard o != f.origin else { return }   // already docked → no loop from the re-triggered didMove
        panel.animator().setFrameOrigin(o)
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: Self.posKey)
    }
}

// MARK: - Dictation HUD (spectrogram pill · no-field card, bottom-center)

@MainActor
final class DictationHUDController {
    private let store: TranscriptStore
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private enum Mode: Equatable { case none, pill, processing, card }
    private var mode: Mode = .none

    init(store: TranscriptStore) {
        self.store = store
        // Fixed frame per mode, and crucially NO `.preferredContentSize`: a constraint-driven
        // window frame + rapidly-updating SwiftUI content segfaults NSISEngine.
        let hosting = NSHostingController(rootView: DictationHUDView(store: store))

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DictationHUDView.cardSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = hosting
        // Transparent host so only the SwiftUI pill/card draws — no panel backing behind it.
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        // React only to the mode-defining state; the pill's live bars re-render inside SwiftUI
        // (SpectrogramPill observes the store directly), so the controller needn't wake on `levels`.
        cancellable = Publishers.MergeMany(
            store.$isDictating.map { _ in () }.eraseToAnyPublisher(),
            store.$dictationProcessing.map { _ in () }.eraseToAnyPublisher(),
            store.$dictationCard.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in Task { @MainActor in self?.update() } }
        update()
    }

    private func update() {
        let next: Mode = store.isDictating ? .pill
            : store.dictationProcessing ? .processing
            : (store.dictationCard != nil ? .card : .none)
        guard next != mode else { return }
        mode = next
        switch next {
        case .none:
            panel.orderOut(nil)
        case .pill, .processing, .card:
            panel.ignoresMouseEvents = (next != .card)   // only the card is interactive; pill/processing never block typing
            let size = next == .pill ? DictationHUDView.pillSize
                : next == .processing ? DictationHUDView.processingSize : DictationHUDView.cardSize
            panel.setContentSize(size)
            positionBottomCenter()
            panel.orderFrontRegardless()
        }
    }

    private func positionBottomCenter() {
        let screen = NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.minY + 96))
    }
}

// MARK: - Single-key (modifier hold) dictation trigger — Wispr Flow style

/// Push-to-talk on ONE modifier key (Fn / Right ⌘ / Right ⌥ / Right ⌃), which `KeyboardShortcuts`
/// can't express. A short delay before starting + cancel-on-other-keypress distinguishes a real
/// hold from a normal shortcut chord (so e.g. right-⌘C doesn't start dictation). Needs Accessibility
/// (global key monitoring); the `.combo` trigger falls back to the KeyboardShortcuts binding.
@MainActor
final class DictationHoldController {
    private let store: TranscriptStore
    private var monitors: [Any] = []
    private var held = false
    private var otherKey = false
    private var startWork: DispatchWorkItem?
    private static let holdDelay = 0.15   // modifier held alone before dictation starts — short so the
                                          // first word isn't lost; a chord's 2nd key still cancels via otherKeyDown

    init(store: TranscriptStore) {
        self.store = store
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor in self?.flagsChanged(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor in self?.flagsChanged(e) }; return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in self?.otherKeyDown() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            Task { @MainActor in self?.otherKeyDown() }; return e
        } as Any)
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private func flagsChanged(_ e: NSEvent) {
        guard let kc = store.dictationTrigger.keyCode, e.keyCode == kc else { return }
        let pressed = e.modifierFlags.contains(store.dictationTrigger.flag)
        if pressed && !held {
            held = true
            otherKey = false
            if store.dictationMode == .toggle {
                store.toggleDictation()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.held, !self.otherKey else { return }
                self.store.startDictation()
            }
            startWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
        } else if !pressed && held {
            held = false
            startWork?.cancel()
            if store.dictationMode == .hold, store.isDictating { store.stopDictation() }
        }
    }

    /// A non-modifier key pressed while the trigger is held → it's a shortcut chord, not dictation.
    private func otherKeyDown() {
        guard held else { return }
        otherKey = true
        startWork?.cancel()
        if store.isDictating { store.stopDictation() }
    }
}
