import AppKit
import SwiftUI
import Combine
import CoreText

/// One surface for hover → click/drag → annotate → copy/save. The selected pixels never move.
@MainActor
final class ScreenshotSelectionView: NSView {
    let display: ScreenshotDisplay
    let mode: ScreenshotCaptureMode
    let windows: [ScreenshotWindow]
    var finish: (() -> Void)?
    var didSelect: (() -> Void)?
    var saving: ((Bool) -> Void)?
    var captureWindow: ((ScreenshotWindow) async throws -> CGImage)?
    var copyScreenshot: (ScreenshotDocument) async throws -> Void = { try await ScreenshotExporter.copy($0) }
    private(set) var selection: CGRect?
    private(set) var hoveredWindow: ScreenshotWindow?
    private(set) var document: ScreenshotDocument?
    private var start: CGPoint?
    private var original: CGRect?
    private var handle: Int?
    private var dragged = false
    private var tracker: NSTrackingArea?
    private var viewport: ScreenshotClipView?
    private var canvas: ScreenshotCanvasView?
    private var border: ScreenshotSelectionBorder?
    private var toolbar: NSHostingView<ScreenshotToolbarView>?
    private let toolbarState = ScreenshotToolbarState()
    private var toolOptions: NSHostingView<ScreenshotToolOptionsView>?
    private var toolbarObservation: AnyCancellable?
    private var observation: AnyCancellable?
    private var textBox: NSScrollView?
    private var textView: ScreenshotInlineTextView?
    private var textID: UUID?
    private var windowCaptureTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = 0
    private let sizeLabel = ScreenshotOverlayLabel(fontName: "Menlo-Medium", size: 11)
    private let hintLabel = ScreenshotOverlayLabel(fontName: "Helvetica", size: 12)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(display: ScreenshotDisplay, mode: ScreenshotCaptureMode, windows: [ScreenshotWindow]) {
        self.display = display; self.mode = mode; self.windows = windows
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetSelection() {
        generation += 1
        windowCaptureTask?.cancel(); windowCaptureTask = nil
        exportTask?.cancel(); exportTask = nil
        observation = nil; toolbarObservation = nil; toolbarState.showsOptions = false
        document?.close(); document = nil
        for view in [viewport, border, toolbar, toolOptions, textBox] as [NSView?] { view?.removeFromSuperview() }
        toolOptions = nil
        viewport = nil; canvas = nil; border = nil; toolbar = nil; textBox = nil; textView = nil; textID = nil
        selection = nil; hoveredWindow = nil; start = nil; original = nil; handle = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let tracker { removeTrackingArea(tracker) }
        let tracker = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracker); self.tracker = tracker
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: display.image, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.48).setFill(); bounds.fill(using: .sourceOver)
        let highlight = selection ?? (mode == .display ? bounds : hoveredWindow.map { localRect($0.frame) })
        if let rect = highlight, !rect.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemTeal.setStroke()
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
            let pixels = ScreenshotGeometry.pixelRect(rect, displaySize: bounds.size, imageSize: display.size)
            label("\(Int(pixels.width)) × \(Int(pixels.height)) px", at: CGPoint(x: min(max(rect.minX, 8), bounds.width - 150), y: max(8, rect.minY - 30)))
        }
        if selection == nil {
            let hint = mode == .display ? "Нажми на нужный экран · Esc — отмена"
                : "Наведи и нажми — окно · Зажми и потяни — область · Esc — отмена"
            let width = min(bounds.width - 32, 620)
            let box = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 60, width: width, height: 36)
            NSColor(white: 0.08, alpha: 0.95).setFill(); NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            hintLabel.draw(hint, in: box.insetBy(dx: 8, dy: 0), centered: true)
        }
    }

    private func label(_ text: String, at point: CGPoint) {
        let rect = CGRect(origin: point, size: CGSize(width: 150, height: 24))
        NSColor(white: 0.08, alpha: 0.9).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        sizeLabel.draw(text, in: rect.insetBy(dx: 8, dy: 0))
    }
    private func localRect(_ global: CGRect) -> CGRect {
        CGRect(x: global.minX - display.frame.minX, y: display.frame.maxY - global.maxY, width: global.width, height: global.height).intersection(bounds)
    }
    private func point(_ event: NSEvent) -> CGPoint { ScreenshotGeometry.clamp(convert(event.locationInWindow, from: nil), to: bounds.size) }
    private func globalPoint(_ local: CGPoint) -> CGPoint { CGPoint(x: display.frame.minX + local.x, y: display.frame.maxY - local.y) }
    func updateHover(globalPoint: CGPoint) {
        guard selection == nil, mode == .region else { return }
        hoveredWindow = windows.first { $0.frame.contains(globalPoint) }; needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey(); window?.makeFirstResponder(self) }
        updateHover(globalPoint: globalPoint(point(event)))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if let toolOptions, !toolOptions.isHidden, toolOptions.frame.contains(p) { return super.hitTest(point) }
        if toolbar?.frame.contains(p) == true || textBox?.frame.contains(p) == true { return super.hitTest(point) }
        if document?.exporting == true { return self }
        // Object handles win over crop corners, even when a handle straddles the crop edge.
        if let canvas, canvas.containsSelectionHandle(canvas.convert(p, from: self)) { return canvas }
        if let rect = selection {
            if ScreenshotGeometry.corners(rect).contains(where: { hypot($0.x - p.x, $0.y - p.y) < 9 }) { return self }
            if document?.adjustingCrop == true || !rect.contains(p) { return self }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard document?.exporting != true, windowCaptureTask == nil else { return }
        toolbarState.showsOptions = false
        window?.makeFirstResponder(self)
        if textView != nil { commitText() }
        let p = point(event)
        start = p; original = selection; handle = nil; dragged = false
        if let selection {
            handle = ScreenshotGeometry.corners(selection).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 9 }
            if handle == nil && !selection.contains(p) {
                // Starting elsewhere retains annotations in screen coordinates until the new crop is chosen.
                original = nil
                hoveredWindow = windows.first { $0.frame.contains(globalPoint(p)) }
            }
        } else { updateHover(globalPoint: globalPoint(p)) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, document?.exporting != true else { return }
        let p = point(event)
        guard dragged || hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
        dragged = true
        if let original, let handle {
            selection = ScreenshotGeometry.rect(ScreenshotGeometry.corners(original)[(handle + 2) % 4], p)
        } else if let original {
            let dx = min(max(p.x - start.x, -original.minX), bounds.width - original.maxX)
            let dy = min(max(p.y - start.y, -original.minY), bounds.height - original.maxY)
            selection = original.offsetBy(dx: dx, dy: dy)
        } else { selection = ScreenshotGeometry.rect(start, p) }
        toolbar?.isHidden = true
        updateLayout(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        if !dragged, original == nil {
            if mode == .display { selection = bounds }
            else if let hoveredWindow {
                selection = localRect(hoveredWindow.frame)
                chooseWindow(hoveredWindow); return
            } else { selection = nil; needsDisplay = true; return }
        }
        guard let rect = selection, rect.width >= 2, rect.height >= 2 else {
            selection = original; updateLayout(); needsDisplay = true; return
        }
        didSelect?()
        if document == nil { installDocument(source: display.image) }
        toolbar?.isHidden = false; updateLayout()
        needsDisplay = true
    }

    private func chooseWindow(_ target: ScreenshotWindow) {
        didSelect?()
        guard let captureWindow else { installDocument(source: display.image); return }
        generation += 1
        let expected = generation, display = display
        windowCaptureTask = Task { [weak self] in
            do {
                let image = try await captureWindow(target)
                try Task.checkCancellation()
                let composed = try display.compositing(image, in: target.frame)
                guard let self, generation == expected else { return }
                windowCaptureTask = nil; installDocument(source: composed)
            } catch is CancellationError {} catch {
                guard let self, generation == expected else { return }
                windowCaptureTask = nil; installDocument(source: display.image)
                document?.error = "Окно изменилось. Выбран видимый участок экрана."
            }
        }
        needsDisplay = true
    }

    private func installDocument(source: CGImage) {
        observation = nil; document?.close()
        viewport?.removeFromSuperview(); toolbar?.removeFromSuperview(); toolOptions?.removeFromSuperview(); border?.removeFromSuperview()
        toolbarObservation = nil; toolbarState.showsOptions = false
        let document = ScreenshotDocument(source: source)
        document.configureScale(display.size.width / bounds.width)
        self.document = document
        let viewport = ScreenshotClipView(); viewport.wantsLayer = true; viewport.layer?.masksToBounds = true
        let canvas = ScreenshotCanvasView(document: document)
        canvas.zoom = bounds.width / display.size.width
        canvas.copyImage = { [weak self] in self?.export(save: false) }
        canvas.saveImage = { [weak self] in self?.export(save: true) }
        canvas.cancel = { [weak self] in self?.dismissOptionsOrFinish() }
        canvas.beginInteraction = { [weak self] in
            self?.toolbarState.showsOptions = false
            self?.commitText()
        }
        canvas.editText = { [weak self] in self?.syncDocumentUI() }
        viewport.addSubview(canvas); addSubview(viewport)
        self.viewport = viewport; self.canvas = canvas
        let border = ScreenshotSelectionBorder(); addSubview(border); self.border = border
        let toolbar = NSHostingView(rootView: ScreenshotToolbarView(document: document, state: toolbarState,
            copy: { [weak self] in self?.export(save: false) }, save: { [weak self] in self?.export(save: true) },
            cancel: { [weak self] in self?.finish?() }, finishText: { [weak self] in self?.commitText() }))
        addSubview(toolbar); self.toolbar = toolbar
        let toolOptions = NSHostingView(rootView: ScreenshotToolOptionsView(document: document))
        toolOptions.isHidden = true; addSubview(toolOptions); self.toolOptions = toolOptions
        toolbarObservation = toolbarState.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.updateLayout()
                if let text = self?.textView { self?.window?.makeFirstResponder(text) }
            }
        }
        observation = document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.syncDocumentUI() }
        }
        updateLayout(); needsDisplay = true
    }

    private func updateLayout() {
        guard let rect = selection else { return }
        let crop = ScreenshotGeometry.pixelRect(rect, displaySize: bounds.size, imageSize: display.size)
        if document?.cropRect != crop { document?.cropRect = crop }
        viewport?.frame = rect
        canvas?.frame = CGRect(x: -rect.minX, y: -rect.minY, width: bounds.width, height: bounds.height)
        border?.frame = rect.insetBy(dx: -7, dy: -7); border?.needsDisplay = true
        var toolbarSize = ScreenshotToolbarView.size
        if document?.error != nil { toolbarSize.height = max(toolbarSize.height, toolbar?.fittingSize.height ?? 80) }
        let x = min(max(rect.maxX - toolbarSize.width, 10), max(10, bounds.width - toolbarSize.width - 10))
        let y: CGFloat
        if rect.maxY + toolbarSize.height + 14 <= bounds.height { y = rect.maxY + 10 }
        else if rect.minY >= toolbarSize.height + 14 { y = rect.minY - toolbarSize.height - 10 }
        else { y = min(max(rect.maxY - toolbarSize.height - 12, 10), bounds.height - toolbarSize.height - 10) }
        toolbar?.frame = CGRect(origin: CGPoint(x: x, y: y), size: toolbarSize)
        if let toolOptions, let document {
            toolOptions.isHidden = !toolbarState.showsOptions || document.adjustingCrop
                || (document.tool == .select && document.selected == nil) || toolbar?.isHidden == true
            if !toolOptions.isHidden {
                let size = toolOptions.fittingSize
                let optionsX = min(max(x + toolbarSize.width - size.width, 10), max(10, bounds.width - size.width - 10))
                let below = y + toolbarSize.height + 8
                let optionsY = y >= size.height + 18 ? y - size.height - 8
                    : min(below, max(10, bounds.height - size.height - 10))
                toolOptions.frame = CGRect(x: optionsX, y: optionsY, width: size.width, height: size.height)
            }
        }
    }

    private func syncDocumentUI() {
        guard let document else { return }
        if let draft = document.textDraft, textID != draft.id { showText(draft) }
        if let draft = document.textDraft, let textView {
            let font = NSFont.systemFont(ofSize: draft.style.fontSize * bounds.width / display.size.width, weight: .semibold)
            if textView.font != font { textView.font = font }
            textView.textColor = draft.style.color.nsColor
            textView.insertionPointColor = draft.style.color.nsColor
            textView.typingAttributes = [.font: font, .foregroundColor: draft.style.color.nsColor]
            updateTextEditorLayout()
            if window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
        }
        if document.textDraft == nil, textView != nil { removeTextBox() }
        if textView == nil, !document.adjustingCrop, !(window?.firstResponder is NSText) { window?.makeFirstResponder(canvas) }
        updateLayout()
    }
    private func showText(_ draft: ScreenshotAnnotation) {
        removeTextBox(); textID = draft.id
        let scale = bounds.width / display.size.width
        let r = draft.bounds
        let frame = CGRect(x: r.minX * scale, y: r.minY * scale,
                           width: r.width * scale, height: max(draft.style.fontSize * scale * 1.5, r.height * scale))
        let box = NSScrollView(frame: frame)
        box.borderType = .noBorder; box.hasVerticalScroller = false; box.drawsBackground = false
        box.contentView.drawsBackground = false; box.backgroundColor = .clear
        let text = ScreenshotInlineTextView(frame: CGRect(origin: .zero, size: frame.size))
        text.isRichText = false; text.font = .systemFont(ofSize: draft.style.fontSize * scale, weight: .semibold)
        text.isEditable = true; text.isSelectable = true; text.allowsUndo = true
        text.drawsBackground = false; text.backgroundColor = .clear
        text.textColor = draft.style.color.nsColor; text.insertionPointColor = draft.style.color.nsColor
        text.string = draft.text; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true; text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = .zero
        text.changed = { [weak self] in self?.updateTextEditorLayout() }
        text.finish = { [weak self] in self?.commitText() }; text.cancel = { [weak self] in self?.dismissText() }
        box.documentView = text; addSubview(box, positioned: .above, relativeTo: viewport)
        textBox = box; textView = text
        updateTextEditorLayout()
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    }
    private func updateTextEditorLayout() {
        guard let text = textView, let box = textBox, let container = text.textContainer, let manager = text.layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let available = (selection?.maxY ?? bounds.height) - box.frame.minY
        let height = min(available, max((text.font?.pointSize ?? 20) * 1.5, ceil(used.height) + 2))
        if abs(box.frame.height - height) > 0.5 { box.setFrameSize(CGSize(width: box.frame.width, height: max(1, height))) }
    }
    private func removeTextBox() { textBox?.removeFromSuperview(); textBox = nil; textView = nil; textID = nil }
    private func dismissText() { document?.textDraft = nil; removeTextBox(); window?.makeFirstResponder(canvas) }
    private func commitText() {
        guard let document, var draft = document.textDraft, let textView else { return }
        draft.text = textView.string
        if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { document.applyText(draft) }
        else if document.annotations.contains(where: { $0.id == draft.id }) {
            document.select(draft.id); document.deleteSelection()
        }
        dismissText()
    }

    func export(save: Bool) {
        guard let document, !document.exporting, let window else { return }
        commitText(); document.exporting = true; document.error = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { document.exporting = false; exportTask = nil }
            do {
                if save {
                    saving?(true)
                    defer { saving?(false) }
                    guard try await ScreenshotExporter.save(document, parent: window) else { return }
                } else { try await copyScreenshot(document) }
                try Task.checkCancellation()
                finish?()
            } catch is CancellationError {} catch { document.error = error.localizedDescription }
        }
    }
    func handleCommand(_ event: NSEvent) -> Bool {
        guard document != nil, let shortcut = ScreenshotShortcut(event) else { return false }
        switch shortcut {
        case .copy: export(save: false)
        case .save: export(save: true)
        case .undo: document?.undo()
        case .redo: document?.redo()
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismissOptionsOrFinish() }
        else if event.keyCode == 36 || event.keyCode == 76 { export(save: false) }
        else if handleCommand(event) { return }
        else if let document, let tool = ScreenshotTool.allCases.first(where: { $0.key == event.charactersIgnoringModifiers?.lowercased() }) {
            document.chooseTool(tool); window?.makeFirstResponder(canvas)
        } else { super.keyDown(with: event) }
    }

    private func dismissOptionsOrFinish() {
        if toolbarState.showsOptions { toolbarState.showsOptions = false }
        else { finish?() }
    }
}

/// The capture HUD deliberately uses concrete CoreText fonts and colors. NSString's
/// AppKit drawing path crashed in TAttributes::ApplyFont while resolving the system
/// monospace font on macOS 26.5.1. Keep that path out of overlay redraws entirely.
@MainActor
private final class ScreenshotOverlayLabel {
    private let font: CTFont
    private var cachedText: String?
    private var cachedLine: CTLine?

    init(fontName: String, size: CGFloat) {
        font = CTFontCreateWithName(fontName as CFString, size, nil)
    }

    func draw(_ text: String, in rect: CGRect, centered: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0, rect.height > 0 else { return }
        if cachedText != text {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            cachedLine = CTLineCreateWithAttributedString(string)
            cachedText = text
        }
        guard let line = cachedLine else { return }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: centered ? max(0, (rect.width - width) / 2) : 0,
                                       y: (rect.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
    }
}

private final class ScreenshotClipView: NSView { override var isFlipped: Bool { true } }
private final class ScreenshotSelectionBorder: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 7, dy: 7)
        NSColor.systemTeal.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 1; path.stroke()
        for p in ScreenshotGeometry.corners(rect) {
            NSColor.white.setFill(); CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6).fill()
        }
    }
}
private final class ScreenshotInlineTextView: NSTextView {
    var finish: (() -> Void)?
    var cancel: (() -> Void)?
    var changed: (() -> Void)?
    override func didChangeText() { super.didChangeText(); changed?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?(); return }
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) { finish?(); return }
        super.keyDown(with: event)
    }
}
