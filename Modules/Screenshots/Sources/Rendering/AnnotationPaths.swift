import AppKit

/// Geometry shared by display, export and hit testing. Coordinates are source pixels.
enum AnnotationPaths {
    static func arrow(_ a: ScreenshotAnnotation) -> CGPath {
        let path = CGMutablePath()
        guard let start = a.points.first, let end = a.points.last else { return path }
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.01 else { return path }
        let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
        let width = min(a.style.lineWidth, length * 0.22)
        let headLength = min(max(width * 4, 12), length * 0.48)
        let headHalf = min(max(width * 1.65, 5), length * 0.25)
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * along - uy * across, y: start.y + uy * along + ux * across)
        }
        let neck = length - headLength
        path.move(to: point(0, width / 2))
        path.addLine(to: point(neck, width / 2))
        path.addLine(to: point(neck, headHalf))
        path.addLine(to: end)
        path.addLine(to: point(neck, -headHalf))
        path.addLine(to: point(neck, -width / 2))
        path.addLine(to: point(0, -width / 2))
        let angle = atan2(uy, ux)
        path.addArc(center: start, radius: width / 2, startAngle: angle - .pi / 2, endAngle: angle - 3 * .pi / 2, clockwise: true)
        path.closeSubpath()
        return path
    }

    static func smoothStroke(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 { if let end = points.last { path.addLine(to: end) }; return path }
        for i in 1..<points.count - 1 {
            let current = points[i], next = points[i + 1]
            path.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2), control: current)
        }
        path.addLine(to: points.last!)
        return path
    }

    static func shape(_ a: ScreenshotAnnotation) -> CGPath {
        switch a.tool {
        case .arrow: return arrow(a)
        case .ellipse: return CGPath(ellipseIn: a.bounds, transform: nil)
        case .rectangle:
            let radius = a.style.rounded ? min(a.style.lineWidth * 1.5, min(a.bounds.width, a.bounds.height) / 4) : 0
            return CGPath(roundedRect: a.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        default: return smoothStroke(a.points)
        }
    }

    static func constrainedEndpoint(_ point: CGPoint, from origin: CGPoint, shift: Bool, automatic: Bool, scale: CGFloat) -> CGPoint {
        let length = hypot(point.x - origin.x, point.y - origin.y)
        let angle = atan2(point.y - origin.y, point.x - origin.x)
        let step: CGFloat = shift ? .pi / 4 : .pi / 2
        let snapped = (angle / step).rounded() * step
        guard shift || (automatic && length * scale >= 24 && abs(angle - snapped) < .pi / 60) else { return point }
        return CGPoint(x: origin.x + length * cos(snapped), y: origin.y + length * sin(snapped))
    }
}
