import AppKit

/// ZVON brand marks loaded from bundled PNGs (rasterized from brand/*.svg).
enum Brand {
    /// Full app-icon tile (teal + wave) — sidebar mark.
    static let mark: NSImage? = load("zvon-mark", template: false)
    /// Menu-bar glyph — black on transparent, template so the system tints it.
    static let menubarGlyph: NSImage? = load("zvon-menubar", template: true)

    /// Full wave mark for the sidebar brand row (window-handoff §1 — paired with live "ZVON" text,
    /// NOT the square tile and NOT a baked-in wordmark). Ink on light, paper (white) on dark.
    private static let waveInk: NSImage? = load("zvon-wave-ink", template: false)
    private static let wavePaper: NSImage? = load("zvon-wave-paper", template: false)
    static func wave(dark: Bool) -> NSImage? { dark ? wavePaper : waveInk }

    /// White wave glyph for the dark dictation capsule (zvon-icon-menubar-paper).
    static let pillGlyph: NSImage? = load("zvon-pill-glyph", template: false)

    private static func load(_ name: String, template: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = template
        return img
    }
}
