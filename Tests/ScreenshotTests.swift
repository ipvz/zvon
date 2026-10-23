import AppKit
import SwiftUI
import ImageIO

@main
struct ScreenshotTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let source = fixture()
        try magnifier(source)
        try videoSelection(source)
        try geometry(source)
        try await rendering(source)
        try await historyAndGestures(source)
        try await selectionGestures(source)
        try await toolQuality(source)
        try objectEditing(source)
        try await copyShortcuts(source)
        print("PASS: screenshot coordinates, Retina crop, hit testing, gestures, history, effects, text, preview/export parity and PNG export")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ScreenshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func magnifier(_ source: CGImage) throws {
        let size = CGSize(width: 500, height: 300), pixels = CGSize(width: 1000, height: 600)
        typealias G = ScreenshotMagnifierGeometry
        try expect(G.pixel(at: CGPoint(x: 10.75, y: 20.25), display: size, image: pixels) == CGPoint(x: 21, y: 40), "Retina loupe must address native pixels without rounding across boundaries")
        try expect(G.pixel(at: CGPoint(x: -1, y: 300), display: size, image: pixels) == CGPoint(x: 0, y: 599), "Pixel lookup must clamp at display edges")
        for point in [CGPoint.zero, CGPoint(x: 499, y: 0), CGPoint(x: 0, y: 299), CGPoint(x: 499, y: 299), CGPoint(x: 250, y: 150)] {
            let frame = G.frame(near: point, in: CGRect(origin: .zero, size: size))
            try expect(CGRect(origin: .zero, size: size).contains(frame) && !frame.contains(point), "Loupe must stay on screen without covering the cursor")
            let pixel = G.pixel(at: point, display: size, image: pixels)
            let sample = G.sampleRect(pixel: pixel, display: size, image: pixels)
            let destination = G.destination(sample: sample, pixel: pixel, display: size, image: pixels)
            let x = destination.minX + (pixel.x - sample.minX + 0.5) * destination.width / sample.width
            let y = destination.minY + (pixel.y - sample.minY + 0.5) * destination.height / sample.height
            try expect(x == G.preview.midX && y == G.preview.midY, "Edge crops must keep the exact targeted pixel in the crosshair")
        }
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: -500, y: -300, width: 500, height: 300), image: source)
        let view = ScreenshotSelectionView(display: display, mode: .region, windows: [])
        let panel = ScreenshotSelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        defer { view.resetSelection(); panel.contentView = nil; panel.close() }
        func hover(_ point: CGPoint) { view.updateHover(globalPoint: CGPoint(x: point.x - 500, y: -point.y)) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            view.mouseDownIfNeeded(type, event: NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        hover(CGPoint(x: 100, y: 50))
        try expect(view.magnifier?.pixel == CGPoint(x: 200, y: 100) && view.magnifier?.isHidden == false, "Negative monitor origins must preserve loupe coordinates")
        try expect(view.magnifier?.hitTest(.zero) == nil, "Loupe must never intercept selection gestures")
        let loupe = view.magnifier!
        let bitmap = loupe.bitmapImageRepForCachingDisplay(in: loupe.bounds)!
        loupe.cacheDisplay(in: loupe.bounds, to: bitmap)
        // Fixture has a dark band above y=100 and white below; verify native-image orientation.
        let sx = CGFloat(bitmap.pixelsWide) / loupe.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / loupe.bounds.height
        let above = bitmap.colorAt(x: Int(82 * sx), y: Int(40 * sy))!.usingColorSpace(.deviceRGB)!
        let below = bitmap.colorAt(x: Int(82 * sx), y: Int(100 * sy))!.usingColorSpace(.deviceRGB)!
        try expect(above.redComponent < 0.3 && below.redComponent > 0.7, "Loupe must show source pixels upright with no vertical mirroring")
        try FileManager.default.createDirectory(atPath: ".build/screenshot-tests", withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/screenshot-tests/magnifier.png"))
        hover(CGPoint(x: 510, y: 50))
        try expect(loupe.isHidden, "Loupe must disappear when the pointer leaves its display")
        mouse(.leftMouseDown, CGPoint(x: 60, y: 60)); mouse(.leftMouseDragged, CGPoint(x: 300, y: 180))
        try expect(view.magnifier?.isHidden == false, "Loupe must follow region dragging")
        mouse(.leftMouseUp, CGPoint(x: 300, y: 180))
        try expect(view.magnifier == nil || view.magnifier!.isHidden, "Finishing selection must hide the loupe")
        view.document!.chooseTool(.arrow); hover(CGPoint(x: 150, y: 120))
        try expect(view.magnifier == nil || view.magnifier!.isHidden, "Drawing tools must not show the crop loupe")
        weak var released: ScreenshotMagnifierView?
        try autoreleasepool {
            hover(CGPoint(x: 60, y: 60))
            try expect(view.magnifier?.isHidden == false, "Crop corners must enable precise readjustment")
            mouse(.leftMouseDown, CGPoint(x: 60, y: 60)); mouse(.leftMouseDragged, CGPoint(x: 55, y: 55))
            try expect(view.magnifier?.pixel == CGPoint(x: 110, y: 110), "Resizing must track exact native pixels")
            mouse(.leftMouseDragged, CGPoint(x: 500, y: 300))
            try expect(view.magnifier?.isHidden == false && view.magnifier?.pixel == CGPoint(x: 999, y: 599), "Dragging to the display boundary must keep the last native pixel visible")
            mouse(.leftMouseUp, CGPoint(x: 55, y: 55))
            released = view.magnifier
            view.resetSelection()
        }
        try expect(released == nil, "Closing selection must release the loupe and its cached crop")
        print("PASS: magnifier native pixels, Retina, negative monitor origins, edge alignment, upright preview, gestures and teardown")
    }

    @MainActor static func videoSelection(_ source: CGImage) throws {
        for invalid in [-1, 0, Int.min, Int.max, Int(UInt32.max) + 1] {
            try expect(ScreenCaptureTarget.validWindowID(invalid) == nil, "Unrealized AppKit windows must never trap during capture enumeration")
        }
        try expect(ScreenCaptureTarget.validWindowID(42) == 42, "Valid WindowServer identity is preserved")
        let display = ScreenshotDisplay(id: 7, frame: CGRect(x: -500, y: -300, width: 500, height: 300), image: source)
        let target = ScreenshotWindow(id: 42, frame: CGRect(x: -450, y: -220, width: 300, height: 160), title: "Window")
        for mode in [ScreenshotCaptureMode.region, .display] {
            let view = ScreenshotSelectionView(display: display, mode: mode, windows: [target])
            let panel = ScreenshotSelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = view
            var selected: ScreenCaptureTarget?
            view.targetToolbarFactory = { _ in NSHostingView(rootView: Text("Record").frame(width: 200, height: 50)) }
            view.selectedTarget = { selected = $0 }
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
                view.mouseDownIfNeeded(type, event: NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            func confirm() {
                view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
            }
            mouse(.leftMouseDown, CGPoint(x: 100,y: 100)); mouse(.leftMouseUp, CGPoint(x: 100,y: 100)); confirm()
            try expect(view.document == nil, "Video selection must never allocate an annotation document")
            try expect(selected?.displayID == 7, "Display identity must survive negative global coordinates")
            if mode == .region {
                try expect(selected?.windowID == 42 && selected?.kind == .window, "Window click must preserve identity")
            } else { try expect(selected?.kind == .display && selected?.pixelSize == CGSize(width: 1000,height: 600), "Display preset uses Retina pixels") }
            let corner = view.selection!.maxX
            let bottom = view.selection!.maxY
            mouse(.leftMouseDown, CGPoint(x: corner,y: bottom)); mouse(.leftMouseDragged, CGPoint(x: corner-30,y: bottom-30)); mouse(.leftMouseUp, CGPoint(x: corner-30,y: bottom-30)); confirm()
            try expect(selected?.kind == .region && selected?.windowID == nil, "Resizing window/display becomes a fixed region")
            view.resetSelection(); panel.contentView = nil; panel.close()
        }
        print("PASS: shared video picker, window identity, display preset, Retina and resize-to-region")
    }

    @MainActor static func copyShortcuts(_ source: CGImage) async throws {
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 300), image: source)
        let target = ScreenshotWindow(id: 42, frame: CGRect(x: 50, y: 80, width: 300, height: 160), title: "Fixture")
        let cases: [(NSEvent.ModifierFlags, String, Bool)] = [
            (.control, "c", false), (.control, "с", false), (.control, "\u{3}", false),
            (.command, "c", false), (.command, "с", false), (.control, "с", true)
        ]
        for windowClick in [false, true] {
            for (flags, characters, editing) in cases {
                let view = ScreenshotSelectionView(display: display, mode: .region, windows: [target])
                let panel = ScreenshotSelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.contentView = view
                func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                if windowClick {
                    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
                    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 100)))
                } else {
                    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 60)))
                    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 350, y: 220)))
                    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 350, y: 220)))
                }
                let document = view.document!
                if editing {
                    document.chooseTool(.text)
                    let point = CGPoint(x: 100, y: 100)
                    let canvas = view.hitTest(view.convert(point, to: view.superview))!
                    canvas.mouseDown(with: mouse(.leftMouseDown, point)); canvas.mouseUp(with: mouse(.leftMouseUp, point))
                    (panel.firstResponder as! NSTextView).insertText("Привет", replacementRange: NSRange(location: NSNotFound, length: 0))
                } else { panel.makeFirstResponder(view) }
                var copied: CGImage?, copies = 0, finished = false
                // Use the real flatten/PNG pipeline with an isolated sink; never touch the user's clipboard.
                view.copyScreenshot = { document in
                    copies += 1
                    let png = try ScreenshotRenderer.encoded(await document.flattened())
                    copied = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)
                }
                view.finish = { finished = true }
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 8)!
                panel.sendEvent(key)
                panel.sendEvent(key) // Held/repeated shortcut must not enqueue a second export.
                for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
                try expect(finished && copies == 1 && copied?.width == 600 && copied?.height == 320,
                    "Control/Command C must export exactly one selected region/window in English and Russian")
                if editing {
                    try expect(document.textDraft == nil && document.annotations.last?.text == "Привет", "Control C must commit and include the active text draft")
                } else {
                    try expect(pixels(copied!) == pixels(source.cropping(to: CGRect(x: 100, y: 120, width: 600, height: 320))!),
                        "Keyboard copy must use selected pixels, not the whole display or overlay")
                }
                view.resetSelection(); panel.contentView = nil; panel.close()
            }
        }
        print("PASS: Control/Command C, English/Russian/control characters, region/window PNG, draft commit, duplicate suppression")
    }

    @MainActor static func toolQuality(_ source: CGImage) async throws {
        var style = AnnotationStyle(); style.lineWidth = 8
        let arrow = ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 30, y: 60), CGPoint(x: 230, y: 60)], style: style)
        try expect(arrow.hit(CGPoint(x: 202, y: 70), tolerance: 0), "The actual filled arrowhead must be clickable outside the shaft")
        try expect(!arrow.hit(CGPoint(x: 120, y: 100), tolerance: 2), "Empty arrow bounding-box space must not intercept drawing")
        let tiny = ScreenshotAnnotation(tool: .arrow, points: [.zero, CGPoint(x: 4, y: 0)], style: style)
        try expect(AnnotationPaths.arrow(tiny).boundingBoxOfPath.width < 10, "Short arrows must not grow oversized or inverted heads")
        let marker = ScreenshotAnnotation(tool: .marker, points: [CGPoint(x: 30, y: 60), CGPoint(x: 230, y: 60)], style: style)
        try expect(marker.hit(CGPoint(x: 100, y: 73), tolerance: 0), "The whole visible highlighter stroke must be clickable")

        let document = ScreenshotDocument(source: source)
        document.configureScale(2)
        document.chooseTool(.arrow)
        var custom = document.style; custom.lineWidth = 10; custom.color = AnnotationColor(.systemBlue)
        document.updateStyle(custom)
        document.chooseTool(.marker)
        try expect(document.style.color == AnnotationColor(.systemYellow), "Tools need independent useful defaults")
        document.chooseTool(.arrow)
        try expect(document.style == custom, "Returning to a tool must restore its style")
        document.add(arrow)
        // No await: a vector has to be available for drawing in this very mouse event.
        try expect(document.presentation.vectors == [arrow], "Live drawing must not wait for the raster worker or debounce")
        let canvas = ScreenshotCanvasView(document: document)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, 120, 60))
        canvas.mouseDragged(with: event(.leftMouseDragged, 120, 80))
        canvas.mouseUp(with: event(.leftMouseUp, 120, 80))
        try expect(document.annotations.count == 1 && document.selected?.points.first?.y == 80, "An arrow must be movable without switching to Select")
        canvas.mouseDown(with: event(.leftMouseDown, 230, 80))
        canvas.mouseUp(with: event(.leftMouseUp, 280, 82))
        try expect(document.selected?.points.last?.y == 80, "Endpoint editing must work in Arrow mode, use the release position and align near-horizontal arrows")
        document.undo()
        try expect(document.selected == nil && document.annotations[0].points.last == CGPoint(x: 230, y: 80), "One undo restores an endpoint edit")
        let count = document.annotations.count
        canvas.mouseDown(with: event(.leftMouseDown, 700, 400))
        canvas.mouseUp(with: event(.leftMouseUp, 702, 402))
        try expect(document.annotations.count == count, "Accidental clicks must not leave tiny arrow fragments")

        document.add(ScreenshotAnnotation(tool: .blur, points: [CGPoint(x: 20, y: 40), CGPoint(x: 250, y: 110)]))
        document.add(ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 300, y: 80), CGPoint(x: 500, y: 160)], style: style))
        for _ in 0..<200 where document.rendering { try await Task.sleep(for: .milliseconds(20)) }
        let live = document.presentation
        let rasterizedLive = try await document.renderer.render(source: live.image, annotations: live.vectors)
        let flattened = try await document.flattened()
        try expect(pixels(rasterizedLive) == pixels(flattened), "Cached effect prefix plus immediate vectors must preserve export pixels and stacking order")
        try expect(live.vectors.count == 1, "Vectors below a blur must stay in the raster prefix")
        document.close(); window.contentView = nil

        let ctx = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fill(CGRect(x: 500, y: 0, width: 500, height: 600))
        var gallery: [ScreenshotAnnotation] = []
        for column in 0..<2 {
            let x = CGFloat(column * 500)
            for (row, width) in [CGFloat(3), 6, 10].enumerated() {
                var style = AnnotationStyle(); style.lineWidth = width
                let y = CGFloat(row * 115 + 60)
                gallery.append(ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: x + 50, y: y + 45), CGPoint(x: x + 260, y: y)], style: style))
                gallery.append(ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: x + 340, y: y + 40), CGPoint(x: x + 405, y: y + 10)], style: style))
            }
            var shapeStyle = AnnotationStyle(); shapeStyle.filled = true; shapeStyle.color = AnnotationColor(.systemTeal)
            gallery.append(ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: x + 50, y: 420), CGPoint(x: x + 240, y: 510)], style: shapeStyle))
            gallery.append(ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: x + 285, y: 480), CGPoint(x: x + 310, y: 440), CGPoint(x: x + 350, y: 500), CGPoint(x: x + 390, y: 435), CGPoint(x: x + 440, y: 480)], style: shapeStyle))
        }
        let rendered = try await ScreenshotRenderer().render(source: ctx.makeImage()!, annotations: gallery)
        try ScreenshotRenderer.encoded(rendered).write(to: URL(fileURLWithPath: ".build/screenshot-tests/tool-quality.png"))
    }

    static func fixture() -> CGImage {
        let ctx = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.16, blue: 0.19, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 500, width: 1000, height: 100))
        ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 30))
        for y in stride(from: 150, to: 460, by: 8) {
            for x in stride(from: 60, to: 950, by: 8) {
                ctx.setFillColor(((x / 8 + y / 8) % 2 == 0 ? NSColor(white: 0.15, alpha: 1) : .white).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return ctx.makeImage()!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    static func geometry(_ source: CGImage) throws {
        let crop = ScreenshotGeometry.pixelRect(CGRect(x: 10.25, y: 20.25, width: 100, height: 50),
            displaySize: CGSize(width: 500, height: 300), imageSize: CGSize(width: 1000, height: 600))
        try expect(crop == CGRect(x: 20, y: 40, width: 201, height: 101), "Retina crop must round outwards")
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: -500, y: -300, width: 500, height: 300), image: source)
        let top = try display.crop(CGRect(x: 0, y: 0, width: 500, height: 50))
        try expect(top.width == 1000 && top.height == 100, "Crop must preserve native pixels on displays with negative origins")
        let topPixels = pixels(top)
        try expect(topPixels[0] < 50 && topPixels[2] < 70, "Crop must use top-left coordinates")
        let arrow = ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)])
        try expect(arrow.hit(CGPoint(x: 50, y: 50), tolerance: 2), "Arrow line hit")
        try expect(!arrow.hit(CGPoint(x: 10, y: 90), tolerance: 2), "Arrow bounding box is not a hit")
        let moved = arrow.moved(dx: -200, dy: 1000, within: CGSize(width: 200, height: 200))
        try expect(moved.bounds.minX == 0 && moved.bounds.maxY == 200, "Move must clamp without deforming")
        let resized = arrow.resized(to: CGRect(x: 20, y: 30, width: 140, height: 90))
        try expect(resized.points.last == CGPoint(x: 160, y: 120), "Resize must transform source geometry")
    }

    @MainActor static func rendering(_ source: CGImage) async throws {
        let renderer = ScreenshotRenderer()
        let original = pixels(source)
        let rect = [CGPoint(x: 100, y: 180), CGPoint(x: 300, y: 350)]
        for tool in [ScreenshotTool.blur, .pixelate, .redact] {
            let annotation = ScreenshotAnnotation(tool: tool, points: rect)
            let image = try await renderer.render(source: source, annotations: [annotation])
            let result = pixels(image)
            var changed = 0
            for y in 0..<600 {
                for x in 0..<1000 {
                    let i = (y * 1000 + x) * 4
                    if Array(original[i..<i+4]) != Array(result[i..<i+4]) {
                        try expect(x >= 100 && x < 300 && y >= 180 && y < 350, "\(tool) changed pixels outside selection: \(x),\(y)")
                        changed += 1
                    }
                    if tool == .redact && x > 100 && x < 300 && y > 180 && y < 350 {
                        try expect(result[i] == 255 && result[i+3] == 255, "Redaction must be opaque, even during export")
                    }
                }
            }
            try expect(changed > 5000, "\(tool) must actually modify the selected content")
        }
        var titleStyle = AnnotationStyle(); titleStyle.color = AnnotationColor(red: 1, green: 1, blue: 1); titleStyle.fontSize = 32
        let title = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 28, y: 23), CGPoint(x: 950, y: 88)],
                                         style: titleStyle, text: "ZVON · Снимки и разметка")
        var annotations = [title]
        for (index, tool) in [ScreenshotTool.blur, .pixelate, .redact].enumerated() {
            let x = CGFloat(index * 290 + 80)
            annotations.append(ScreenshotAnnotation(tool: tool, points: [CGPoint(x: x, y: 185), CGPoint(x: x + 230, y: 335)]))
        }
        annotations.append(ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 120, y: 510), CGPoint(x: 240, y: 370)]))
        annotations.append(ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 65, y: 170), CGPoint(x: 325, y: 350)]))
        annotations.append(ScreenshotAnnotation(tool: .ellipse, points: [CGPoint(x: 620, y: 440), CGPoint(x: 900, y: 535)]))
        annotations.append(ScreenshotAnnotation(tool: .marker, points: [CGPoint(x: 370, y: 485), CGPoint(x: 560, y: 485)]))
        let rendered = try await renderer.render(source: source, annotations: annotations)
        let data = try ScreenshotRenderer.encoded(rendered)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        try expect(pixels(decoded) == pixels(rendered), "PNG must exactly preserve flattened pixels")
        let renderedPixels = pixels(rendered)
        var textPixels = 0
        for y in 23..<88 { for x in 28..<950 {
            let i = (y * 1000 + x) * 4
            if renderedPixels[i] > 200 && original[i] < 50 { textPixels += 1 }
        } }
        try expect(textPixels > 1000, "Text must render upright inside its top-left rectangle")
        let document = ScreenshotDocument(source: source)
        annotations.forEach { document.add($0) }
        for _ in 0..<200 where document.rendering { try await Task.sleep(for: .milliseconds(20)) }
        try expect(!document.rendering, "Preview must finish")
        let exported = try await document.flattened()
        try expect(pixels(document.preview) == pixels(exported), "Preview and export must match exactly")
        let dir = URL(fileURLWithPath: ".build/screenshot-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("annotations.png"))
        document.close()
    }

    @MainActor static func historyAndGestures(_ source: CGImage) async throws {
        let document = ScreenshotDocument(source: source)
        let annotation = ScreenshotAnnotation(tool: .rectangle, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)])
        document.beginEdit()
        for n in 1...100 { var a = annotation; a.points[1].x = CGFloat(300 + n); document.replace(a) }
        document.commitEdit()
        document.undo()
        try expect(document.annotations.isEmpty && !document.canUndo, "A drag must be one undo step")
        document.redo()
        try expect(document.annotations.count == 1 && document.annotations[0].bounds.maxX == 400, "Redo must restore final drag position")
        document.beginEdit(); document.replace(annotation); document.cancelEdit()
        try expect(document.annotations[0].bounds.maxX == 400, "Escape must restore pre-gesture state")
        document.undo(); document.add(annotation)
        try expect(!document.canRedo, "A new edit must clear redo")

        let canvas = ScreenshotCanvasView(document: document); canvas.zoom = 0.5
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        document.tool = .arrow; document.select(nil)
        canvas.mouseDown(with: event(.leftMouseDown, 250, 60))
        canvas.mouseDragged(with: event(.leftMouseDragged, 350, 140))
        canvas.mouseUp(with: event(.leftMouseUp, 350, 140))
        try expect(document.annotations.last?.points == [CGPoint(x: 500, y: 120), CGPoint(x: 700, y: 280)], "Canvas must map points through zoom")
        document.tool = .select
        canvas.mouseDown(with: event(.leftMouseDown, 300, 100))
        canvas.mouseDragged(with: event(.leftMouseDragged, 310, 110))
        canvas.mouseUp(with: event(.leftMouseUp, 310, 110))
        try expect(document.annotations.last?.points.first == CGPoint(x: 520, y: 140), "Dragging selection must move annotation")
        document.undo()
        try expect(document.annotations.last?.points.first == CGPoint(x: 500, y: 120), "One undo must undo the entire move")
        document.close(); window.contentView = nil

        let history = ScreenshotDocument(source: source)
        for _ in 0..<150 { history.add(ScreenshotAnnotation(tool: .rectangle, points: annotation.points)) }
        var count = 0
        while history.canUndo { history.undo(); count += 1 }
        try expect(count == 100, "Undo history must remain bounded")
        history.close()
    }

    @MainActor static func selectionGestures(_ source: CGImage) async throws {
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: -500, y: 0, width: 500, height: 300), image: source)
        let view = ScreenshotSelectionView(display: display, mode: .region, windows: [])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var finished = false
        view.finish = { finished = true }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 300, 200))
        view.mouseDragged(with: event(.leftMouseDragged, 100, 80))
        view.mouseUp(with: event(.leftMouseUp, 100, 80))
        // Resize the top-left corner, then move the completed rectangle.
        view.mouseDown(with: event(.leftMouseDown, 100, 80))
        view.mouseDragged(with: event(.leftMouseDragged, 80, 60))
        view.mouseUp(with: event(.leftMouseUp, 80, 60))
        view.mouseDown(with: event(.leftMouseDown, 180, 140))
        view.mouseDragged(with: event(.leftMouseDragged, 190, 150))
        view.mouseUp(with: event(.leftMouseUp, 190, 150))
        guard let document = view.document else { throw ScreenshotError.emptySelection }
        try expect(!finished, "Releasing the mouse must enter inline editing, not finish capture")
        try expect(view.subviews.contains { $0 is NSHostingView<ScreenshotToolbarView> }, "Tools must live in the same overlay")
        let image = try await document.flattened()
        try expect(image.width == 440 && image.height == 280, "Region selection, corner resize and moving must preserve Retina size")
        let reference = try display.crop(CGRect(x: 90, y: 70, width: 220, height: 140))
        try expect(pixels(reference) == pixels(image), "Region selection must crop exact coordinates after movement")
        view.resetSelection()

        let front = ScreenshotWindow(id: 11, frame: CGRect(x: -450, y: 50, width: 200, height: 160), title: "Front")
        let back = ScreenshotWindow(id: 12, frame: CGRect(x: -480, y: 0, width: 400, height: 280), title: "Back")
        let automatic = ScreenshotSelectionView(display: display, mode: .region, windows: [front, back])
        window.contentView = automatic
        automatic.updateHover(globalPoint: CGPoint(x: -400, y: 200))
        try expect(automatic.hoveredWindow?.id == front.id, "Hover must choose the frontmost window without a mode switch")
        func autoEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: automatic.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        automatic.mouseDown(with: autoEvent(.leftMouseDown, 100, 100))
        automatic.mouseUp(with: autoEvent(.leftMouseUp, 100, 100))
        try expect(automatic.selection == CGRect(x: 50, y: 90, width: 200, height: 160), "Click must select exact window bounds on a negative-origin display")
        try expect(automatic.document != nil, "Clicking a window must show inline tools immediately")
        automatic.resetSelection()
        automatic.mouseDown(with: autoEvent(.leftMouseDown, 100, 100))
        automatic.mouseDragged(with: autoEvent(.leftMouseDragged, 180, 170))
        automatic.mouseUp(with: autoEvent(.leftMouseUp, 180, 170))
        try expect(automatic.selection == CGRect(x: 100, y: 100, width: 80, height: 70), "Dragging over a window must choose an arbitrary region instead")
        automatic.resetSelection()
        automatic.captureWindow = { _ in
            try await Task.sleep(for: .milliseconds(40))
            return source
        }
        automatic.mouseDown(with: autoEvent(.leftMouseDown, 100, 100))
        automatic.mouseUp(with: autoEvent(.leftMouseUp, 100, 100))
        automatic.resetSelection()
        try await Task.sleep(for: .milliseconds(60))
        try expect(automatic.document == nil && automatic.subviews.isEmpty, "Cancelling pending window capture must not resurrect tools or retain a document")
        window.contentView = nil
        try await inlineCanvas(source)
    }

    @MainActor static func inlineCanvas(_ source: CGImage) async throws {
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600), image: source)
        let overlay = ScreenshotSelectionView(display: display, mode: .region, windows: [])
        let window = NSWindow(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: overlay.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 100)))
        overlay.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 880, y: 450)))
        overlay.mouseUp(with: event(.leftMouseUp, CGPoint(x: 880, y: 450)))
        guard let document = overlay.document else { throw ScreenshotError.emptySelection }
        document.adjustingCrop = false; document.tool = .arrow
        let p = CGPoint(x: 200, y: 200), q = CGPoint(x: 400, y: 300)
        let hit = overlay.hitTest(overlay.convert(p, to: overlay.superview))
        try expect(hit is ScreenshotCanvasView, "Hit testing must route selected-area drawing to the canvas")
        hit?.mouseDown(with: event(.leftMouseDown, p))
        hit?.mouseDragged(with: event(.leftMouseDragged, q))
        hit?.mouseUp(with: event(.leftMouseUp, q))
        try expect(document.annotations.first?.points == [p, q], "Inline canvas must preserve screen coordinates despite the viewport offset")
        for _ in 0..<200 where document.rendering { try await Task.sleep(for: .milliseconds(20)) }
        let exported = try await document.flattened()
        try expect(exported.width == 800 && exported.height == 350, "Inline export must contain only the selection")
        try expect(pixels(exported) == pixels(document.preview.cropping(to: document.cropRect!)!), "Inline preview must match export without toolbars or dimming")
        document.adjustingCrop = true
        overlay.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 100)))
        overlay.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 60, y: 80)))
        overlay.mouseUp(with: event(.leftMouseUp, CGPoint(x: 60, y: 80)))
        try expect(document.annotations.first?.points == [p, q], "Changing selection bounds must preserve existing annotations")
        document.chooseTool(.text)
        let textPoint = CGPoint(x: 550, y: 150)
        let textTarget = overlay.hitTest(overlay.convert(textPoint, to: overlay.superview))!
        textTarget.mouseDown(with: event(.leftMouseDown, textPoint))
        textTarget.mouseUp(with: event(.leftMouseUp, textPoint))
        guard let box = overlay.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let text = box.documentView as? NSTextView else {
            throw NSError(domain: "ScreenshotTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Text must be editable on the overlay itself"])
        }
        try expect(text.window === window, "Text entry must not create a separate window")
        try expect(window.firstResponder === text, "Clicking Text must focus the editor synchronously, before the next key event")
        try expect(!text.drawsBackground && !box.drawsBackground && !box.contentView.drawsBackground && box.borderType == .noBorder,
            "Text input must be transparent without a gray form")
        try expect(document.textDraft?.style.textBackground == false, "New text must export without a default background")
        text.insertText("Текст прямо\nна снимке", replacementRange: NSRange(location: NSNotFound, length: 0))
        let arrowBeforeStyleChange = document.annotations.first
        var draftStyle = document.style; draftStyle.fontSize = 24; draftStyle.color = AnnotationColor(.systemBlue)
        window.makeFirstResponder(textTarget)
        document.updateStyle(draftStyle)
        try await Task.sleep(for: .milliseconds(50))
        try expect(text.font?.pointSize == 24 && text.textColor == draftStyle.color.nsColor, "Font and color changes must apply during typing")
        try expect(window.firstResponder === text, "Typing focus must return after using style controls")
        try expect(document.annotations.first == arrowBeforeStyleChange, "Styling a draft must not change another selected object")
        text.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        try expect(document.annotations.last?.text == "Текст прямо\nна снимке" && document.textDraft == nil, "Enter must apply inline text with line breaks")
        try expect(document.annotations.last!.bounds.width < 300 && document.annotations.last!.bounds.height < 100, "Text handles must hug actual content")
        try expect(!overlay.subviews.contains(where: { $0 is NSScrollView }), "Applying text must remove the input control")
        for _ in 0..<200 where document.rendering { try await Task.sleep(for: .milliseconds(20)) }
        overlay.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/screenshot-tests/inline-overlay.png"))
        }
        document.chooseTool(.text)
        let another = CGPoint(x: 100, y: 350)
        let canvas = overlay.hitTest(overlay.convert(another, to: overlay.superview))!
        canvas.mouseDown(with: event(.leftMouseDown, another)); canvas.mouseUp(with: event(.leftMouseUp, another))
        let anotherEditor = (overlay.subviews.first { $0 is NSScrollView } as! NSScrollView).documentView as! NSTextView
        anotherEditor.insertText("Не потерять", replacementRange: NSRange(location: NSNotFound, length: 0))
        let outside = CGPoint(x: 470, y: 350)
        let outsideTarget = overlay.hitTest(overlay.convert(outside, to: overlay.superview))!
        outsideTarget.mouseDown(with: event(.leftMouseDown, outside)); outsideTarget.mouseUp(with: event(.leftMouseUp, outside))
        try expect(document.textDraft == nil && document.annotations.last?.text == "Не потерять", "Clicking outside text must commit it before handling the canvas gesture")
        document.chooseTool(.arrow)
        let corner = overlay.selection!.origin
        document.add(ScreenshotAnnotation(tool: .arrow, points: [corner, CGPoint(x: corner.x + 60, y: corner.y + 60)]))
        try expect(overlay.hitTest(overlay.convert(corner, to: overlay.superview)) is ScreenshotCanvasView,
            "Object handles at a crop corner must resize the object, not the crop")
        overlay.resetSelection(); window.contentView = nil
    }

    @MainActor static func objectEditing(_ source: CGImage) throws {
        let document = ScreenshotDocument(source: source)
        document.configureScale(1); document.chooseTool(.arrow)
        let canvas = ScreenshotCanvasView(document: document)
        canvas.frame = CGRect(origin: .zero, size: document.size)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ p: CGPoint, _ q: CGPoint) {
            canvas.mouseDown(with: event(.leftMouseDown, p)); canvas.mouseDragged(with: event(.leftMouseDragged, q)); canvas.mouseUp(with: event(.leftMouseUp, q))
        }
        let arrow = ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)])
        document.add(arrow); document.chooseTool(.rectangle)
        drag(CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 120))
        try expect(document.selected?.id == arrow.id && document.annotations.count == 1, "Existing objects must remain selectable from other drawing tools")
        drag(CGPoint(x: 300, y: 120), CGPoint(x: 400, y: 180))
        try expect(document.selected?.points.last == CGPoint(x: 400, y: 180), "Arrow endpoint handles must change its size and angle")
        var style = document.style; style.color = AnnotationColor(.systemBlue); style.lineWidth = 10
        document.updateStyle(style)
        try expect(document.selected?.style == style, "Color and thickness must update the selected arrow")
        document.undo()
        try expect(document.selected == nil && document.annotations.first?.style == arrow.style, "Style edits must be undoable")

        var textStyle = AnnotationStyle(); textStyle.fontSize = 24
        let text = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 100, y: 250), CGPoint(x: 380, y: 290)], style: textStyle, text: "Размер текста меняется")
        document.add(text); document.tool = .select
        drag(CGPoint(x: 380, y: 290), CGPoint(x: 660, y: 330))
        try expect(document.selected?.style.fontSize == 48 && document.selected?.bounds.width == 560, "Text corner drag must scale letters and bounds together")
        try expect(document.style.fontSize == 48, "Style controls must follow resized text")
        document.undo()
        try expect(document.annotations.last == text, "One undo must restore the whole text resize")
        document.select(text.id)
        drag(CGPoint(x: 380, y: 270), CGPoint(x: 230, y: 270))
        try expect(document.selected?.style.fontSize == 24 && document.selected!.bounds.height > 40, "Text side handles must reflow lines without scaling the font")
        document.textDraft = document.selected
        try expect(!document.presentation.vectors.contains { $0.id == text.id }, "Editing text must hide the old glyphs under the transparent editor")
        document.textDraft = nil
        try expect(document.presentation.vectors.contains { $0.id == text.id }, "Cancelling text editing must restore original glyphs")
        document.close(); window.contentView = nil
    }
}

private extension ScreenshotSelectionView {
    func mouseDownIfNeeded(_ type: NSEvent.EventType, event: NSEvent) {
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        default: mouseUp(with: event)
        }
    }
}
