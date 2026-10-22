import AppKit
import SwiftUI
import Combine

@MainActor
final class ScreenshotCanvasView: NSView {
    let document: ScreenshotDocument
    var zoom: CGFloat = 1
    var copyImage: (() -> Void)?
    var saveImage: (() -> Void)?
    var cancel: (() -> Void)?
    var beginInteraction: (() -> Void)?
    var editText: (() -> Void)?
    private var observation: AnyCancellable?
    private var start: CGPoint?
    private var original: ScreenshotAnnotation?
    private var drawing: ScreenshotAnnotation?
    private var handle: Int?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(document: ScreenshotDocument) {
        self.document = document
        super.init(frame: .zero)
        observation = document.objectWillChange.sink { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.19, alpha: 1).setFill(); bounds.fill()
        let presentation = document.presentation
        NSImage(cgImage: presentation.image, size: document.size).draw(in: bounds, from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.scaleBy(x: zoom, y: zoom)
            for annotation in presentation.vectors {
                context.saveGState(); ScreenshotRenderer.drawVector(annotation, in: context); context.restoreGState()
            }
            context.restoreGState()
        }
        // During a gesture the actual shape is the feedback; controls must not obscure it.
        guard start == nil, document.textDraft == nil, !document.adjustingCrop, let selection = document.selected else { return }
        let accent = NSColor(srgbRed: 0.3, green: 0.75, blue: 0.75, alpha: 1)
        if selection.tool != .arrow {
            accent.withAlphaComponent(0.75).setStroke()
            let path = NSBezierPath(rect: scaled(selection.bounds).insetBy(dx: -2, dy: -2))
            path.lineWidth = 1; path.setLineDash([3, 3], count: 2, phase: 0); path.stroke()
        }
        for p in handles(for: selection) {
            let box = CGRect(x: p.x * zoom - 5, y: p.y * zoom - 5, width: 10, height: 10)
            NSColor.white.setFill(); NSBezierPath(ovalIn: box).fill()
            accent.setStroke(); let ring = NSBezierPath(ovalIn: box); ring.lineWidth = 1.5; ring.stroke()
        }
    }

    private func handles(for annotation: ScreenshotAnnotation) -> [CGPoint] {
        if annotation.tool == .arrow { return [annotation.points.first!, annotation.points.last!] }
        let r = annotation.bounds
        let sides = [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        let vertical = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
        return ScreenshotGeometry.corners(r) + sides + (annotation.tool == .text ? [] : vertical)
    }
    func containsSelectionHandle(_ point: CGPoint) -> Bool {
        guard document.textDraft == nil, !document.adjustingCrop, let selected = document.selected else { return false }
        return handles(for: selected).contains { hypot($0.x * zoom - point.x, $0.y * zoom - point.y) <= 11 }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        if let selected = document.selected, let index = handles(for: selected).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 11 / zoom }) {
            (index == 4 || index == 5 ? NSCursor.resizeLeftRight : index >= 6 ? NSCursor.resizeUpDown : NSCursor.crosshair).set()
        } else if editableHit(p, forceNew: event.modifierFlags.contains(.option)) != nil { NSCursor.openHand.set() }
        else { (document.tool == .text ? NSCursor.iBeam : document.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set() }
    }
    private func editableHit(_ p: CGPoint, forceNew: Bool) -> ScreenshotAnnotation? {
        guard !forceNew else { return nil }
        return document.annotations.reversed().first {
            (document.tool == .select || (document.tool == .text ? $0.tool == .text
                : ![.marker, .pen, .blur, .pixelate, .redact].contains(document.tool)))
                && $0.hit(p, tolerance: 6 / zoom)
        }
    }

    private func scaled(_ r: CGRect) -> CGRect { CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom) }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return ScreenshotGeometry.clamp(CGPoint(x: p.x / zoom, y: p.y / zoom), to: document.size)
    }

    override func mouseDown(with event: NSEvent) {
        beginInteraction?()
        window?.makeFirstResponder(self)
        let p = point(event)
        start = p; handle = nil; original = nil; drawing = nil
        if event.clickCount >= 2, let text = editableHit(p, forceNew: event.modifierFlags.contains(.option)), text.tool == .text {
            document.select(text.id); document.textDraft = text; start = nil; editText?(); return
        }
        if !event.modifierFlags.contains(.option), let selected = document.selected {
            handle = handles(for: selected).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 11 / zoom }
            if handle != nil { original = selected; document.beginEdit(); return }
        }
        let selected = editableHit(p, forceNew: event.modifierFlags.contains(.option))
        if document.tool == .select || selected != nil {
            document.select(selected?.id)
            if let selected, selected.tool == .text, event.clickCount == 2 || document.tool == .text {
                document.textDraft = selected; start = nil; editText?(); return
            }
            original = selected
            if selected != nil { document.beginEdit(); NSCursor.closedHand.set() }
        } else if document.tool == .text {
            let crop = document.cropRect ?? CGRect(origin: .zero, size: document.size)
            let width = min(320 / zoom, crop.maxX - p.x)
            let height = min(document.style.fontSize * 1.5, crop.maxY - p.y)
            guard width > 5, height > 5 else { return }
            document.textDraft = ScreenshotAnnotation(tool: .text,
                points: [p, CGPoint(x: p.x + width, y: p.y + height)], style: document.style)
            start = nil; editText?()
        } else {
            document.beginEdit()
            drawing = ScreenshotAnnotation(tool: document.tool, points: [p, p], style: document.style)
            document.replace(drawing!)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        var p = point(event)
        if let original {
            if let handle {
                if original.tool == .arrow {
                    var changed = original
                    p = AnnotationPaths.constrainedEndpoint(p, from: original.points[1 - handle], shift: event.modifierFlags.contains(.shift), automatic: !event.modifierFlags.contains(.option), scale: zoom)
                    changed.points[handle] = ScreenshotGeometry.clamp(p, to: document.size); document.replace(changed)
                } else if handle >= 4 {
                    var rect = original.bounds
                    let minimum = 12 / zoom
                    switch handle {
                    case 4: let x = min(p.x, rect.maxX - minimum); rect.size.width = rect.maxX - x; rect.origin.x = x
                    case 5: rect.size.width = max(minimum, p.x - rect.minX)
                    case 6: let y = min(p.y, rect.maxY - minimum); rect.size.height = rect.maxY - y; rect.origin.y = y
                    default: rect.size.height = max(minimum, p.y - rect.minY)
                    }
                    var changed = original.resized(to: rect, scalingText: false)
                    if original.tool == .text {
                        changed = changed.fittingText(maxWidth: rect.width,
                            maxHeight: (document.cropRect?.maxY ?? document.size.height) - rect.minY, tightWidth: false)
                    }
                    document.replace(changed)
                } else {
                    let anchor = ScreenshotGeometry.corners(original.bounds)[(handle + 2) % 4]
                    if original.tool == .text {
                        let corner = ScreenshotGeometry.corners(original.bounds)[handle]
                        let dx = corner.x - anchor.x, dy = corner.y - anchor.y
                        let projection = ((p.x - anchor.x) * dx + (p.y - anchor.y) * dy) / max(1, dx * dx + dy * dy)
                        let crop = document.cropRect ?? CGRect(origin: .zero, size: document.size)
                        let limitX = (dx < 0 ? anchor.x - crop.minX : crop.maxX - anchor.x) / max(1, abs(dx))
                        let limitY = (dy < 0 ? anchor.y - crop.minY : crop.maxY - anchor.y) / max(1, abs(dy))
                        let scale = min(limitX, limitY, max(6 / (original.style.fontSize * zoom), projection))
                        p = CGPoint(x: anchor.x + dx * scale, y: anchor.y + dy * scale)
                    }
                    var rect = ScreenshotGeometry.rect(anchor, p)
                    rect.size.width = max(2, rect.width); rect.size.height = max(2, rect.height)
                    document.replace(original.resized(to: rect))
                }
            } else {
                document.replace(original.moved(dx: p.x - start.x, dy: p.y - start.y, within: document.size))
            }
        } else if var drawing {
            if drawing.tool == .arrow {
                p = AnnotationPaths.constrainedEndpoint(p, from: start, shift: event.modifierFlags.contains(.shift), automatic: !event.modifierFlags.contains(.option), scale: zoom)
                p = ScreenshotGeometry.clamp(p, to: document.size)
            } else if event.modifierFlags.contains(.shift), [.rectangle, .ellipse].contains(drawing.tool) {
                let length = min(abs(p.x - start.x), abs(p.y - start.y))
                p = CGPoint(x: start.x + (p.x < start.x ? -length : length), y: start.y + (p.y < start.y ? -length : length))
            }
            if [.marker, .pen].contains(drawing.tool) {
                if let last = drawing.points.last, hypot(p.x - last.x, p.y - last.y) > 1 / zoom { drawing.points.append(p) }
            } else { drawing.points = [start, p] }
            self.drawing = drawing; document.replace(drawing)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if start != nil { mouseDragged(with: event) }
        let minimum: CGFloat = drawing?.tool == .arrow ? 7 : 3
        if let drawing, hypot(drawing.bounds.width, drawing.bounds.height) * zoom < minimum { document.cancelEdit(); document.select(nil) }
        else { document.commitEdit() }
        start = nil; original = nil; drawing = nil; handle = nil; needsDisplay = true
        mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleShortcut(event) { return }
        if event.keyCode == 36 || event.keyCode == 76 { copyImage?(); return }
        if event.keyCode == 53 {
            if start != nil {
                document.cancelEdit(); document.select(nil); start = nil; drawing = nil; original = nil
            } else { cancel?() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { document.deleteSelection(); return }
        if [123, 124, 125, 126].contains(event.keyCode), let selected = document.selected {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            document.beginEdit()
            document.replace(selected.moved(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                            dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0, within: document.size))
            document.commitEdit(); return
        }
        if let tool = ScreenshotTool.allCases.first(where: { $0.key == event.charactersIgnoringModifiers?.lowercased() }) {
            document.chooseTool(tool); return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleShortcut(event) || super.performKeyEquivalent(with: event)
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = ScreenshotShortcut(event) else { return false }
        switch shortcut {
        case .copy: copyImage?()
        case .save: saveImage?()
        case .undo: document.undo()
        case .redo: document.redo()
        }
        return true
    }
}
