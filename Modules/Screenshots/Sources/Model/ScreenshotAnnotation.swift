import AppKit

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, marker, pen, text, blur, pixelate, redact
    var id: Self { self }
    var title: String {
        switch self {
        case .select: return "Выделение"
        case .arrow: return "Стрелка"
        case .rectangle: return "Прямоугольник"
        case .ellipse: return "Овал"
        case .marker: return "Маркер"
        case .pen: return "Карандаш"
        case .text: return "Текст"
        case .blur: return "Блюр"
        case .pixelate: return "Пикселизация"
        case .redact: return "Закрасить"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .blur: return "drop.halffull"
        case .pixelate: return "square.grid.3x3.fill"
        case .redact: return "rectangle.fill"
        }
    }
    var key: String { ["v", "a", "r", "e", "h", "p", "t", "b", "x", "k"][Self.allCases.firstIndex(of: self)!] }
    var isEffect: Bool { self == .blur || self == .pixelate }
}

struct AnnotationColor: Equatable, Sendable {
    var red: CGFloat = 1
    var green: CGFloat = 0.25
    var blue: CGFloat = 0.22
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: CGFloat = 1, green: CGFloat = 0.25, blue: CGFloat = 0.22) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
}

struct AnnotationStyle: Equatable, Sendable {
    var color = AnnotationColor()
    var lineWidth: CGFloat = 6
    var fontSize: CGFloat = 32
    var effectStrength: CGFloat = 16
    var outline = true
    var rounded = true
    var filled = false
    var textBackground = false
}

/// All geometry is in source pixels, with the origin at the top left. Never store view coordinates.
struct ScreenshotAnnotation: Identifiable, Equatable {
    var id = UUID()
    var tool: ScreenshotTool
    var points: [CGPoint]
    var style = AnnotationStyle()
    var text = ""

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { r, p in
            CGRect(x: min(r.minX, p.x), y: min(r.minY, p.y),
                   width: max(r.maxX, p.x) - min(r.minX, p.x),
                   height: max(r.maxY, p.y) - min(r.minY, p.y))
        }
    }

    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        if [.text, .blur, .pixelate, .redact].contains(tool) {
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
        let path = AnnotationPaths.shape(self)
        if tool == .arrow || (style.filled && [.rectangle, .ellipse].contains(tool)) {
            if path.contains(p) { return true }
        }
        let strokeWidth = tool == .marker ? style.lineWidth * 4 : tool == .arrow ? 0 : style.lineWidth
        return path.copy(strokingWithWidth: max(1, strokeWidth + tolerance * 2), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }

    func moved(dx: CGFloat, dy: CGFloat, within size: CGSize) -> Self {
        var copy = self
        let r = bounds
        let x = min(max(dx, -r.minX), size.width - r.maxX)
        let y = min(max(dy, -r.minY), size.height - r.maxY)
        copy.points = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
        return copy
    }

    func resized(to rect: CGRect, scalingText: Bool = true) -> Self {
        var copy = self
        let old = bounds
        copy.points = points.map {
            CGPoint(x: rect.minX + (old.width > 0 ? ($0.x - old.minX) / old.width : 0) * rect.width,
                    y: rect.minY + (old.height > 0 ? ($0.y - old.minY) / old.height : 0) * rect.height)
        }
        if tool == .text, scalingText, old.height > 0 {
            copy.style.fontSize *= rect.height / old.height
        }
        return copy
    }

    /// Shared measurement for committed text and width-only reflow. Keeps selection
    /// handles close to the glyphs instead of retaining the empty input rectangle.
    func fittingText(maxWidth: CGFloat, maxHeight: CGFloat, tightWidth: Bool = true) -> Self {
        guard tool == .text else { return self }
        var copy = self
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let width = max(1, maxWidth)
        let measured = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
                .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold), .paragraphStyle: paragraph
            ])
        let fittedWidth = tightWidth ? min(width, max(8, ceil(measured.width) + 2)) : width
        let height = min(maxHeight, max(style.fontSize * 1.25, ceil(measured.height) + 2))
        copy.points = [bounds.origin, CGPoint(x: bounds.minX + fittedWidth, y: bounds.minY + max(1, height))]
        return copy
    }
}

enum ScreenshotGeometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func clamp(_ p: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }
    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    static func distance(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / squared, 0), 1)
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    /// Convert a selection in screen points (top-left origin) to an outward-rounded pixel crop.
    static func pixelRect(_ rect: CGRect, displaySize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / displaySize.width, sy = imageSize.height / displaySize.height
        let x = floor(rect.minX * sx), y = floor(rect.minY * sy)
        return CGRect(x: x, y: y, width: ceil(rect.maxX * sx) - x, height: ceil(rect.maxY * sy) - y)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
