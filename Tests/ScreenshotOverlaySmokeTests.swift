import AppKit

/// Run as a separate process with a real NSApplication event loop. Offscreen bitmap
/// tests do not exercise the layer-backed redraw path in the production crash report.
@main
struct ScreenshotOverlaySmokeTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await activationAndRestart()
            startDrawingSmoke()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: native overlay smoke test timed out\n", stderr); exit(1)
        }
        app.run()
    }

    @MainActor static func activationAndRestart() async {
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: 40, y: 40, width: 200, height: 120), image: context.makeImage()!)
        let capture = DelayedCapture(environment: ScreenshotEnvironment(displays: [display], windows: []))
        let controller = ScreenshotController(capture: capture)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func panels() -> [ScreenshotSelectionPanel] { NSApp.windows.compactMap { $0 as? ScreenshotSelectionPanel }.filter { $0.isVisible } }
        func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

        controller.start(); controller.start()
        await settle()
        precondition(capture.pending.count == 1, "Repeated shortcut must not start parallel captures")
        controller.cancelCapture(); controller.start()
        await settle()
        precondition(capture.pending.count == 2, "Cancel must allow an immediate new capture")
        capture.completeFirst(); await settle()
        precondition(panels().isEmpty, "Late cancelled capture must not open an overlay")
        capture.completeFirst(); await settle()
        precondition(panels().count == 1, "Replacement capture must survive old task cleanup")
        let panel = panels()[0]
        precondition(panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate,
                     "Overlay must take keyboard focus without activating or hiding with the application")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                     "Opening capture must not activate the screenshot application")
        panel.orderOut(nil)
        controller.start(); await settle()
        precondition(panels().first === panel && capture.pending.isEmpty,
                     "Repeated shortcut must recover the same hidden overlay")
        for _ in 0..<15 {
            controller.cancelCapture(); controller.start(); await settle()
            precondition(capture.pending.count == 1, "Rapid restart must create one request")
            capture.completeFirst(); await settle()
            precondition(panels().count == 1, "Old cancellation must not dismiss the new overlay")
        }
        controller.cancelCapture(); await settle()
        precondition(panels().isEmpty, "Cancel must release all overlays")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                     "Closing capture must not bring another application forward")
        print("PASS: nonactivating capture, hidden-overlay recovery, late callbacks and 15 immediate restarts")
    }

    @MainActor static func startDrawingSmoke() {
        let app = NSApplication.shared
        let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let display = ScreenshotDisplay(id: 1, frame: CGRect(x: 40, y: 40, width: 500, height: 300), image: context.makeImage()!)
        let target = ScreenshotWindow(id: 42, frame: CGRect(x: 80, y: 80, width: 300, height: 180), title: "Fixture")
        var panel: NSPanel?
        var view: ScreenshotSelectionView?
        var ticks = 0
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                let phase = ticks % 24
                if phase == 0 {
                    let overlay = ScreenshotSelectionView(display: display, mode: .region, windows: [target])
                    let window = ScreenshotSelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = overlay
                    window.orderFrontRegardless()
                    window.makeKey(); window.makeFirstResponder(overlay)
                    panel = window; view = overlay
                }
                guard let panel, let view else { fatalError("Missing overlay") }
                func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                func key(_ characters: String, code: UInt16) {
                    app.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
                }
                switch phase {
                case 1...3: view.updateHover(globalPoint: CGPoint(x: phase == 2 ? 41 : 100, y: 100))
                case 4: view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 80)))
                case 5...8: view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 200 + phase * 10, y: 190)))
                case 9: view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 300, y: 200)))
                case 10:
                    view.document!.chooseTool(.text)
                    let point = CGPoint(x: 120, y: 110)
                    let target = view.hitTest(view.convert(point, to: view.superview))!
                    target.mouseDown(with: event(.leftMouseDown, point)); target.mouseUp(with: event(.leftMouseUp, point))
                    precondition(panel.firstResponder is NSTextView, "Text click must focus the actual production panel")
                case 11:
                    key("Проверка", code: 0)
                    precondition((panel.firstResponder as? NSTextView)?.string == "Проверка", "Native keyboard events must reach the inline editor")
                case 12:
                    var style = view.document!.style; style.fontSize = 48; style.color = AnnotationColor(.systemBlue)
                    view.document!.updateStyle(style)
                case 13:
                    precondition((panel.firstResponder as? NSTextView)?.font?.pointSize == 24, "Retina font controls must update the live editor")
                    key("\r", code: 36)
                    precondition(view.document?.textDraft == nil && view.document?.annotations.last?.text == "Проверка", "Enter must commit text instead of exporting")
                case 14:
                    let corner = view.selection!.origin
                    view.mouseDown(with: event(.leftMouseDown, corner))
                    view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: corner.x - 10, y: corner.y - 10)))
                case 15:
                    precondition(view.magnifier?.isHidden == false, "Deferred document updates must not hide the loupe during crop resizing")
                    view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 70, y: 70)))
                    precondition(view.magnifier?.isHidden == true, "Finishing resize must hide the loupe")
                case 18: view.resetSelection()
                case 19: view.updateHover(globalPoint: CGPoint(x: 100, y: 100))
                case 23:
                    view.resetSelection(); panel.orderOut(nil); panel.contentView = nil; panel.close()
                default: break
                }
                if phase != 23 { view.displayIfNeeded() }
                ticks += 1
                if ticks == 288 { print("PASS: 12 native overlay lifecycles, keyboard text input, live Retina styling, Enter commit and teardown"); exit(0) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor private final class DelayedCapture: ScreenshotCapturing {
    let environment: ScreenshotEnvironment
    var pending: [CheckedContinuation<ScreenshotEnvironment, Error>] = []
    init(environment: ScreenshotEnvironment) { self.environment = environment }
    func prepare() async throws -> ScreenshotEnvironment {
        // Deliberately ignore cancellation to model an in-flight system callback.
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func completeFirst() { pending.removeFirst().resume(returning: environment) }
    func capture(window: ScreenshotWindow) async throws -> CGImage { environment.displays[0].image }
}
