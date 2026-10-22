# ZVONScreenshots

Independent macOS 14+ static library. The app calls `ScreenshotController.start(_:)`; global shortcuts and menu actions live in `Sources/App/ScreenshotIntegration.swift`.

## User flow

**Select region** is a single flow: hover highlights the frontmost application window, click fixes its bounds, drag selects an arbitrary rectangle. Releasing the mouse shows a compact annotation toolbar beside the selection. The image stays in place on the screen. There is no separate editor window or window-capture mode.

Default shortcuts: Command + Shift + A selects a region/window; Command + Option + 3 starts with the display preset. Both are configurable in **Settings → Screenshots**. The former Command + Option + 5 window shortcut is no longer registered.

After selection, use the toolbar to draw arrows, rectangles, ellipses, highlighter, pen, text, blur, pixelation or opaque covers. Text is entered directly on the transparent overlay after a click; Enter, Command + Enter or clicking outside applies it. Shift + Enter inserts a line break; Escape cancels the edit. Double-click an existing text object to edit it. The crop button moves the selection; corner handles adjust its boundaries without losing annotations. V selects annotation objects, which can be moved/resized. Existing objects are also directly selectable from shape tools; Option starts a new overlapping object. Text-tool clicks create text or edit existing text. Arrow endpoints adjust length/angle; text corners scale the letters, while side handles change wrapping width without changing font size. Object handles take precedence over crop handles at the selection boundary. Command Z / Command Shift Z undo/redo annotations. Enter, Control C or Command C copies the selected result and dismisses the overlay. Copy/save/undo shortcuts use physical key codes and work in English and Russian layouts. Control C also commits and copies an active text draft; Command C retains normal text-copy behavior while editing text. Command S opens the system save dialog for PNG/JPEG; cancelling it keeps the selection. Escape cancels capture (or the active text/annotation gesture first).

The main toolbar is one 46-point-high row. Its color swatch opens a compact card for the active tool's color, thickness, outline, fill or effect strength. Both views remain inside the capture overlay; the card is positioned within the display bounds and receives input independently of the crop. Presentation state is separate from the screenshot document and undo history.

## Boundaries

- `Capture/`: ScreenCaptureKit permission, display snapshots, window discovery and independent window capture. Window descriptors carry IDs/geometry, without retaining ScreenCaptureKit objects. The capture protocol is the integration boundary. No continuous capture stream.
- `Model/`: immutable source bitmap, annotations, crop and bounded transactional history. Geometry stays in native full-display pixels with a top-left origin. Changing the crop does not translate or discard annotations.
- `Rendering/`: serial full-resolution renderer shared by preview and export; export crops the flattened result to the selected pixel bounds. Toolbar, selection handles and outside dimming are view-only. Core Image effects sample composited annotations in order. The exporter owns only file/clipboard operations.
- `UI/ScreenshotSelectionController`: overlay lifetime, one active selection across monitors, focus restoration and save-dialog window levels.
- `UI/ScreenshotSelectionView`: hover/drag selection, clipped annotation canvas, toolbar and inline text on the same surface.
- `UI/ScreenshotCanvasView`: annotation gestures, hit testing and coordinate conversion.
- `UI/ScreenshotToolbarView`: tools and style controls; never opens another editing window.

Window click captures the chosen window independently of occluders and composites it into the frozen display at its original bounds. If the window disappears, the visible screen region remains available with an inline explanation. Isolated captures omit shadows for deterministic bounds; display snapshots preserve desktop shadows. Regions stay within one monitor, at that monitor's native pixel density.

There are no dependencies on audio, transcripts, networking or AI. Only explicit copy/save exports pixels. History holds at most 100 vector snapshots, without bitmap copies; stale renders are cancelled. Closing capture releases documents, overlays and pending work. There is no automatic screenshot history or upload. Use opaque cover when information must be completely hidden; blur and pixelation are visual effects.

## Validation

`scripts/test-screenshots.sh` covers Retina/negative-origin coordinates, automatic frontmost-window hover and click, arbitrary drag over a window, overlay tool placement, actual canvas hit routing, crop resizing without losing annotations, bounded history, effects, text, PNG round-trip and exact preview/export parity. Synthetic visual output is written to `.build/screenshot-tests/inline-overlay.png`. Tests do not read the screen or modify the clipboard.

Tests also dispatch Control/Command C through the production panel for both layouts, region/window selection and active text drafts, then check the cropped PNG using an isolated export sink. Tests compile with Release optimization. `SCREENSHOT_NATIVE_SMOKE=1 scripts/test-screenshots.sh` additionally opens small synthetic panels and exercises 12 capture lifecycles in a real AppKit event loop, including hover labels, changing dimensions, the inline toolbar and teardown. This covers native layer redraws that bitmap-only tests miss. Overlay labels use cached CoreText lines with concrete fonts, avoiding the AppKit string-drawing path implicated in a macOS 26.5.1 crash.

Hardware validation remains necessary for mixed-DPI monitors, full-screen Spaces and OS permission/save-dialog interactions.

## Drawing quality

Vectors after the last blur/pixelation are painted synchronously from model geometry at display refresh rate. Earlier layers are a cached raster prefix, so effects preserve their stacking order. A single coalescing background worker renders the latest bitmap snapshot; pointer events cannot starve rendering or build an unbounded queue. The same vector paths drive preview, export and hit testing.

Arrows are continuous filled silhouettes with proportional heads, rounded tails and optional contrast outlines. Selection shows endpoint controls instead of a bounding rectangle. In Arrow mode, drag an existing arrow or either endpoint to adjust it; Option forces a new overlapping arrow. Near-horizontal/vertical arrows align automatically, Shift constrains to 45° increments, and Option disables automatic alignment. Click-sized accidental arrows are discarded. Pen/highlighter strokes use quadratic smoothing. Figures support rounded corners, contrast outlines and translucent fills. Text is transparent by default, with an optional dark backing. Color/font controls also work while typing, and committed text bounds fit the actual content. Tool styles are remembered independently during capture; thickness presets use screen points so they feel consistent on Retina and non-Retina displays.
