import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotError: LocalizedError {
    case permission, noDisplay, emptySelection, rendering, export
    var errorDescription: String? {
        switch self {
        case .permission: return "Разреши ZVON запись экрана в системных настройках macOS. После выдачи разрешения может потребоваться перезапуск приложения."
        case .noDisplay: return "Не удалось найти доступный экран или окно. Попробуй сделать снимок ещё раз."
        case .emptySelection: return "Выдели область размером хотя бы 2 × 2 пикселя."
        case .rendering: return "Не удалось обработать изображение. Попробуй уменьшить область снимка."
        case .export: return "Не удалось сохранить изображение. Проверь доступ к выбранной папке."
        }
    }
}

/// One serial renderer per document. Preview and export use this exact pipeline and resolution.
actor ScreenshotRenderer {
    private let ci = CIContext(options: [.cacheIntermediates: false])

    func render(source: CGImage, annotations: [ScreenshotAnnotation]) throws -> CGImage {
        try Task.checkCancellation()
        if annotations.isEmpty { return source }
        let width = source.width, height = source.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotError.rendering }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        for annotation in annotations {
            try Task.checkCancellation()
            if annotation.tool.isEffect {
                try effect(annotation, context: ctx, height: CGFloat(height))
            } else {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
                Self.drawVector(annotation, in: ctx)
                ctx.restoreGState()
            }
        }
        guard let result = ctx.makeImage() else { throw ScreenshotError.rendering }
        return result
    }

    private func effect(_ a: ScreenshotAnnotation, context: CGContext, height: CGFloat) throws {
        guard let current = context.makeImage() else { throw ScreenshotError.rendering }
        let rect = CGRect(x: a.bounds.minX, y: height - a.bounds.maxY, width: a.bounds.width, height: a.bounds.height)
            .integral.intersection(CGRect(x: 0, y: 0, width: current.width, height: current.height))
        guard rect.width > 0, rect.height > 0 else { return }
        let input = CIImage(cgImage: current).clampedToExtent()
        let output: CIImage
        if a.tool == .blur {
            output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: a.style.effectStrength])
        } else {
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: a.style.effectStrength,
                                                                    kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
        }
        guard let image = ci.createCGImage(output.cropped(to: rect), from: rect) else { throw ScreenshotError.rendering }
        context.saveGState()
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    nonisolated static func drawVector(_ a: ScreenshotAnnotation, in ctx: CGContext) {
        let color = a.style.color.nsColor.cgColor
        ctx.setStrokeColor(color); ctx.setFillColor(color)
        ctx.setLineWidth(a.style.lineWidth); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch a.tool {
        case .arrow, .rectangle, .ellipse, .pen, .marker:
            let path = AnnotationPaths.shape(a)
            if a.tool == .marker {
                // One stroked path: intersections inside a gesture do not darken repeatedly.
                ctx.setAlpha(0.30); ctx.setLineWidth(a.style.lineWidth * 4)
                ctx.setLineCap(.round); ctx.addPath(path); ctx.strokePath()
                break
            }
            if a.style.filled && [.rectangle, .ellipse].contains(a.tool) {
                ctx.saveGState(); ctx.setAlpha(0.14); ctx.addPath(path); ctx.fillPath(); ctx.restoreGState()
            }
            if a.style.outline {
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.setLineWidth(a.tool == .arrow ? max(1.5, a.style.lineWidth * 0.4) : a.style.lineWidth + max(2, a.style.lineWidth * 0.6))
                ctx.addPath(path); ctx.strokePath(); ctx.restoreGState()
            }
            ctx.addPath(path)
            if a.tool == .arrow { ctx.fillPath() } else { ctx.strokePath() }
        case .redact:
            ctx.setAlpha(1); ctx.fill(a.bounds.integral)
        case .text:
            if a.style.textBackground {
                ctx.saveGState(); ctx.setFillColor(NSColor(white: 0.08, alpha: 0.9).cgColor)
                let padding = a.style.fontSize * 0.18
                ctx.addPath(CGPath(roundedRect: a.bounds.insetBy(dx: -padding, dy: -padding), cornerWidth: padding, cornerHeight: padding, transform: nil))
                ctx.fillPath(); ctx.restoreGState()
            }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let string = NSAttributedString(string: a.text, attributes: [
                .font: NSFont.systemFont(ofSize: a.style.fontSize, weight: .semibold),
                .foregroundColor: a.style.color.nsColor, .paragraphStyle: paragraph
            ])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            string.draw(with: a.bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        case .select, .blur, .pixelate: break
        }
    }

    nonisolated static func encoded(_ image: CGImage, type: UTType = .png) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw ScreenshotError.export }
        CGImageDestinationAddImage(destination, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.export }
        return data as Data
    }
}
