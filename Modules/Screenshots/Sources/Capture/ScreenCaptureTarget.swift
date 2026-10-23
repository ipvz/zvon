import AppKit

/// Shared selection boundary. Coordinates are display-local points with a top-left origin.
/// A window keeps its identity; dragging its bounds deliberately changes it into a region.
public struct ScreenCaptureTarget: Sendable {
    public enum Kind: Sendable { case display, region, window }
    public let kind: Kind
    public let displayID: CGDirectDisplayID
    public let windowID: CGWindowID?
    public let rect: CGRect
    public let pixelSize: CGSize
    public let title: String
    /// AppKit can expose sentinel/placeholder window numbers outside CGWindowID's range.
    /// Never use a trapping integer cast for a window that has not reached WindowServer.
    public static func validWindowID(_ number: Int) -> CGWindowID? {
        guard let id = CGWindowID(exactly: number), id > 0 else { return nil }
        return id
    }
    public init(kind: Kind, displayID: CGDirectDisplayID, windowID: CGWindowID? = nil,
                rect: CGRect, pixelSize: CGSize, title: String) {
        self.kind = kind; self.displayID = displayID; self.windowID = windowID
        self.rect = rect; self.pixelSize = pixelSize; self.title = title
    }
}

/// Reuses the screenshot overlay without creating an annotation document or exporting pixels.
/// The caller owns the compact accessory and receives only a capture descriptor.
@MainActor
public final class ScreenTargetSelector {
    private let selector = ScreenshotSelectionController()
    private let capture = ScreenshotCaptureService()
    public init() {}
    public func choose(displayOnly: Bool = false,
                       toolbar: @escaping (@escaping () -> Void) -> NSView) async throws -> ScreenCaptureTarget? {
        try await Task.sleep(for: .milliseconds(180))
        let environment = try await capture.prepare()
        var result: ScreenCaptureTarget?
        try await selector.run(mode: displayOnly ? .display : .region, environment: environment,
                               captureWindow: capture.capture, targetToolbar: toolbar) { target in
            result = target
        }
        try Task.checkCancellation()
        return result
    }
    public func cancel() { selector.cancel() }
}
