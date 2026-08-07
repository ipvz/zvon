import SwiftUI
import AppKit

// MARK: - Dynamic color (auto-adapts to system Light/Dark)

extension NSColor {
    convenience init(lightHex light: UInt32, darkHex dark: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension Color {
    static func parley(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(lightHex: light, darkHex: dark))
    }

    // ── ZVON palette v1.0 (was Parley/clay → ZVON/teal). Token names kept; values remapped.
    // Text
    static let pInk1 = parley(0x0C1413, 0xF2F5F4)   // text
    static let pInk2 = parley(0x5E6B69, 0x8B9A97)   // textSecondary
    static let pInk3 = parley(0x8A9694, 0x6C7A78)   // textTertiary
    static let pOnFill = parley(0xFFFFFF, 0x04201F) // text ON an accent fill (accentOn)

    // Surfaces (cool neutral, dark-first)
    static let pDesk = parley(0xE8EBEA, 0x080D0C)   // behind windows
    static let pCanvas = parley(0xF7F8F7, 0x0E1615) // window body
    static let pRail = parley(0xEEF1F0, 0x0A1110)   // sidebar
    static let pChrome = parley(0xF2F4F3, 0x0E1615) // toolbar / status bar
    static let pWidget = parley(0xEEF1F0, 0x131D1C) // widget canvas
    static let pCard = parley(0xFFFFFF, 0x131D1C)   // surface — cards, panels
    static let pPuck = parley(0xFFFFFF, 0x1B2524)   // floating puck / raised
    static let pField = parley(0xFFFFFF, 0x0E1615)  // inputs (rest bg)
    static let pChip = parley(0xF2F4F3, 0x1B2524)   // ⌘K chip

    // Lines & controls
    static let pLine = parley(0xE1E6E5, 0x253130)   // hairlineStrong — primary separators
    static let pLine2 = parley(0xE1E6E5, 0x1B2524)  // hairline — inside cards
    static let pTrackOff = parley(0xB3BCBA, 0x46534F)
    static let pControlBorder = parley(0xDFE4E3, 0x253130)
    static let pSelection = parley(0xF2F4F3, 0x1B2524)   // surfaceRaised — active row
    static let pButtonBorder = parley(0xE1E6E5, 0x253130)
    static let pWidgetBorder = parley(0xE1E6E5, 0x253130)

    // Accent = teal. Red = recording ONLY (never errors/delete in ZVON, but pDanger reuses it for now).
    static let pAccent = parley(0x009798, 0x00C4C4)
    static let pOnAccent = parley(0xFFFFFF, 0x04201F)
    static var pAccentWash: Color { pAccent.opacity(0.13) }   // active-section tint
    static let pRecording = parley(0xDE3E2D, 0xFF6B57)         // recording status only
    static let pDanger = parley(0xDE3E2D, 0xFF6B57)
    static let pSuccess = parley(0x007D7E, 0x00C4C4)           // "granted" — teal, green is not a brand color

    // Floating-widget surfaces (spec: dark bg #101817, muted-teal status, bright text in the mic bubble)
    static let pWidgetBG = parley(0xFFFFFF, 0x101817)         // widget panel body
    static let pStatusLocal = parley(0x007D7E, 0x3E9D9D)      // «локально» — muted teal status text
    static let pMicBubbleText = parley(0x0C1413, 0xDFF7F7)    // text inside the accent mic bubble

    // Elevation. The spec's shadow alphas were authored against the DARK widget (#101817); reused
    // verbatim in Light they read as a grey smudge around every floating card — the surface is
    // white, the desktop behind it is light, and 28–50% black has nothing to sink into. Same
    // geometry, much softer alpha in Light. Three tiers, nothing else.
    private static func shadowInk(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: isDark ? dark : light)
        })
    }
    static let pShadow1 = shadowInk(light: 0.07, dark: 0.22)   // resting card on canvas
    static let pShadow2 = shadowInk(light: 0.10, dark: 0.30)   // floating widget, dictation pills
    static let pShadow3 = shadowInk(light: 0.14, dark: 0.48)   // modal-weight overlay
    // Control-scale lift (segmented thumb): a 3px radius needs a firmer alpha than a surface, and
    // in Dark the old flat 14% black under a dark thumb was invisible.
    static let pShadowControl = shadowInk(light: 0.14, dark: 0.36)
}

// MARK: - Typography (system font; max 5 sizes)

enum PFont {   // ZVON type scale (SF Pro)
    static let title = Font.system(size: 21, weight: .semibold)      // titleXL
    static let heading = Font.system(size: 17, weight: .semibold)    // title/headline
    static let body = Font.system(size: 14, weight: .regular)        // body
    static let secondary = Font.system(size: 13.5, weight: .regular) // bodySm
    static let secondaryStrong = Font.system(size: 13.5, weight: .semibold)
    static let label = Font.system(size: 11, weight: .medium)        // overline (usually uppercased + tracked)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let monoSecondary = Font.system(size: 13, weight: .regular, design: .monospaced)
}

// MARK: - Spacing (strict 8pt grid; 4 & 12 for control internals only)

enum PSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 40
    static let xxxl: CGFloat = 48
    static let huge: CGFloat = 64
}

// MARK: - Radius

enum PRadius {   // ZVON radii
    static let window: CGFloat = 12
    static let card: CGFloat = 9
    static let widget: CGFloat = 14
    static let puck: CGFloat = 17
    static let control: CGFloat = 7
    static let button: CGFloat = 7
}

// MARK: - Chrome metrics

enum PMetric {
    static let toolbar: CGFloat = 56
    static let settingsToolbar: CGFloat = 52
    static let statusBar: CGFloat = 32
    static let menuBarStrip: CGFloat = 28
    static let rail: CGFloat = 360
    static let settingsSidebar: CGFloat = 220
    static let notesMeasure: CGFloat = 680
    static let actionRow: CGFloat = 40
    static let settingsRow: CGFloat = 48
    static let dockInset: CGFloat = 16       // widget resting distance from a screen edge
}
