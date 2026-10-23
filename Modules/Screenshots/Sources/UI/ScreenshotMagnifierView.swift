import AppKit

/// Geometry stays in display-local points; the loupe samples the frozen native pixels.
enum ScreenshotMagnifierGeometry {
    static let size = CGSize(width: 140, height: 166)
    static let preview = CGRect(x: 6, y: 6, width: 128, height: 128)
    static let zoom: CGFloat = 8

    static func pixel(at point: CGPoint, display: CGSize, image: CGSize) -> CGPoint {
        CGPoint(x: min(image.width - 1, max(0, floor(point.x * image.width / display.width))),
                y: min(image.height - 1, max(0, floor(point.y * image.height / display.height))))
    }

    static func frame(near point: CGPoint, in bounds: CGRect) -> CGRect {
        let gap: CGFloat = 24, margin: CGFloat = 8
        let x = point.x + gap + size.width <= bounds.maxX - margin ? point.x + gap : point.x - gap - size.width
        let y = point.y + gap + size.height <= bounds.maxY - margin ? point.y + gap : point.y - gap - size.height
        return CGRect(x: min(max(bounds.minX + margin, x), max(bounds.minX + margin, bounds.maxX - size.width - margin)),
                      y: min(max(bounds.minY + margin, y), max(bounds.minY + margin, bounds.maxY - size.height - margin)),
                      width: size.width, height: size.height)
    }

    static func sampleRect(pixel: CGPoint, display: CGSize, image: CGSize) -> CGRect {
        let rx = ceil(preview.width * image.width / display.width / zoom / 2)
        let ry = ceil(preview.height * image.height / display.height / zoom / 2)
        return CGRect(x: pixel.x - rx, y: pixel.y - ry, width: 2 * rx + 1, height: 2 * ry + 1)
            .intersection(CGRect(origin: .zero, size: image))
    }

    static func destination(sample: CGRect, pixel: CGPoint, display: CGSize, image: CGSize) -> CGRect {
        let sx = zoom * display.width / image.width, sy = zoom * display.height / image.height
        // Do not recenter the crop at display edges: the targeted pixel stays in the crosshair.
        return CGRect(x: preview.midX + (sample.minX - pixel.x - 0.5) * sx,
                      y: preview.midY + (sample.minY - pixel.y - 0.5) * sy,
                      width: sample.width * sx, height: sample.height * sy)
    }
}

@MainActor
final class ScreenshotMagnifierView: NSView {
    private let source: CGImage
    private let displaySize: CGSize
    private var imageSize: CGSize { CGSize(width: source.width, height: source.height) }
    private var enlarged: NSImage?
    private var destination = CGRect.zero
    private(set) var pixel: CGPoint?
    private let label = ScreenshotOverlayLabel(fontName: "Menlo-Medium", size: 10)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(image: CGImage, displaySize: CGSize) {
        source = image; self.displaySize = displaySize
        super.init(frame: CGRect(origin: .zero, size: ScreenshotMagnifierGeometry.size))
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(at point: CGPoint, in bounds: CGRect) {
        let next = ScreenshotMagnifierGeometry.pixel(at: point, display: displaySize, image: imageSize)
        if next != pixel {
            pixel = next
            let rect = ScreenshotMagnifierGeometry.sampleRect(pixel: next, display: displaySize, image: imageSize)
            enlarged = source.cropping(to: rect).map { NSImage(cgImage: $0, size: rect.size) }
            destination = ScreenshotMagnifierGeometry.destination(sample: rect, pixel: next, display: displaySize, image: imageSize)
            needsDisplay = true
        }
        setFrameOrigin(ScreenshotMagnifierGeometry.frame(near: point, in: bounds).origin)
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current, let pixel else { return }
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.07, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10); outline.lineWidth = 1; outline.stroke()
        let preview = ScreenshotMagnifierGeometry.preview
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: preview, xRadius: 5, yRadius: 5).addClip()
        context.imageInterpolation = .none
        enlarged?.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let step = CGSize(width: ScreenshotMagnifierGeometry.zoom * displaySize.width / imageSize.width,
                          height: ScreenshotMagnifierGeometry.zoom * displaySize.height / imageSize.height)
        if min(step.width, step.height) >= 4 {
            let grid = NSBezierPath()
            for i in -40...40 {
                let x = preview.midX + (CGFloat(i) + 0.5) * step.width
                let y = preview.midY + (CGFloat(i) + 0.5) * step.height
                if x >= preview.minX && x <= preview.maxX { grid.move(to: CGPoint(x: x, y: preview.minY)); grid.line(to: CGPoint(x: x, y: preview.maxY)) }
                if y >= preview.minY && y <= preview.maxY { grid.move(to: CGPoint(x: preview.minX, y: y)); grid.line(to: CGPoint(x: preview.maxX, y: y)) }
            }
            NSColor.black.withAlphaComponent(0.18).setStroke(); grid.lineWidth = 0.5; grid.stroke()
        }
        // Leave the central pixel visible; high-contrast arms work on light and dark content.
        let cross = NSBezierPath()
        let cx = preview.midX, cy = preview.midY
        for (a, b) in [(CGPoint(x: preview.minX, y: cy), CGPoint(x: cx - step.width / 2 - 1, y: cy)),
                       (CGPoint(x: cx + step.width / 2 + 1, y: cy), CGPoint(x: preview.maxX, y: cy)),
                       (CGPoint(x: cx, y: preview.minY), CGPoint(x: cx, y: cy - step.height / 2 - 1)),
                       (CGPoint(x: cx, y: cy + step.height / 2 + 1), CGPoint(x: cx, y: preview.maxY))] {
            cross.move(to: a); cross.line(to: b)
        }
        NSColor.black.withAlphaComponent(0.8).setStroke(); cross.lineWidth = 2; cross.stroke()
        NSColor.systemTeal.setStroke(); cross.lineWidth = 1; cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
        label.draw("\(Int(pixel.x)) · \(Int(pixel.y)) px", in: CGRect(x: 6, y: 138, width: 128, height: 22), centered: true)
    }

    static let cursor: NSCursor = {
        let image = NSImage(size: CGSize(width: 30, height: 30), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: CGRect(x: 9, y: 9, width: 12, height: 12))
            for (a, b) in [(CGPoint(x: 15,y: 1),CGPoint(x: 15,y: 11)), (CGPoint(x: 15,y: 19),CGPoint(x: 15,y: 29)),
                           (CGPoint(x: 1,y: 15),CGPoint(x: 11,y: 15)), (CGPoint(x: 19,y: 15),CGPoint(x: 29,y: 15))] {
                path.move(to: a); path.line(to: b)
            }
            NSColor.white.setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 1; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 15, y: 15))
    }()
}
