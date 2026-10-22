import AppKit

/// Run as a separate process with a real NSApplication event loop. Offscreen bitmap
/// tests do not exercise the layer-backed redraw path in the production crash report.
@main
struct ScreenshotOverlaySmokeTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("FAIL: native overlay smoke test timed out\n", stderr); exit(1)
        }
        app.run()
    }
}
