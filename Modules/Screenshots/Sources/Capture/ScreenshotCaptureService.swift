import AppKit
import ScreenCaptureKit

public enum ScreenshotCaptureMode: String, CaseIterable {
    case region, display
    public var title: String {
        switch self {
        case .region: return "Снимок области"
        case .display: return "Снимок экрана"
        }
    }
}

struct ScreenshotDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage
    var size: CGSize { CGSize(width: image.width, height: image.height) }
    func compositing(_ windowImage: CGImage, in globalFrame: CGRect) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotError.rendering }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        let sx = size.width / frame.width, sy = size.height / frame.height
        ctx.draw(windowImage, in: CGRect(x: (globalFrame.minX - frame.minX) * sx,
                                        y: (globalFrame.minY - frame.minY) * sy,
                                        width: globalFrame.width * sx, height: globalFrame.height * sy))
        guard let result = ctx.makeImage() else { throw ScreenshotError.rendering }
        return result
    }
    func crop(_ rect: CGRect) throws -> CGImage {
        let pixels = ScreenshotGeometry.pixelRect(rect, displaySize: frame.size, imageSize: size)
        guard pixels.width >= 2, pixels.height >= 2, let crop = image.cropping(to: pixels) else { throw ScreenshotError.emptySelection }
        return crop
    }
}

struct ScreenshotWindow {
    let id: CGWindowID
    let frame: CGRect // AppKit global coordinates, bottom left.
    let title: String
}

struct ScreenshotEnvironment {
    let displays: [ScreenshotDisplay]
    let windows: [ScreenshotWindow] // Front to back.
}

@MainActor
protocol ScreenshotCapturing {
    func prepare() async throws -> ScreenshotEnvironment
    func capture(window: ScreenshotWindow) async throws -> CGImage
}

/// No live stream and no long-lived screen frames: capture exists only while choosing a target.
@MainActor
final class ScreenshotCaptureService: ScreenshotCapturing {
    func prepare() async throws -> ScreenshotEnvironment {
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else { throw ScreenshotError.permission }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let excludedIDs = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window is NSPanel || window.identifier?.rawValue.hasPrefix("zvon.screenshot") == true else { return nil }
            return ScreenCaptureTarget.validWindowID(window.windowNumber)
        })
        let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
        var displays: [ScreenshotDisplay] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.ignoreShadowsDisplay = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: configuration)
            try Task.checkCancellation()
            displays.append(ScreenshotDisplay(id: display.displayID, frame: screen.frame, image: image))
        }
        guard !displays.isEmpty else { throw ScreenshotError.noDisplay }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let order = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let eligible = Dictionary(uniqueKeysWithValues: content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 30 && $0.frame.height > 30 && !excludedIDs.contains($0.windowID)
        }.map { ($0.windowID, $0) })
        let windows: [ScreenshotWindow] = order.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? NSNumber, let window = eligible[id.uint32Value] else { return nil }
            let frame = CGRect(x: window.frame.minX, y: primaryHeight - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.owningApplication?.applicationName ?? "Окно"
            return ScreenshotWindow(id: window.windowID, frame: frame, title: title)
        }
        return ScreenshotEnvironment(displays: displays, windows: windows)
    }

    func capture(window: ScreenshotWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else { throw ScreenshotError.noDisplay }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return image
    }
}
