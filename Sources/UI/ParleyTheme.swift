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

    // Text
    static let pInk1 = parley(0x232120, 0xECEAE4)   // primary
    static let pInk2 = parley(0x6A665E, 0xA29D94)   // secondary
    static let pInk3 = parley(0xA8A399, 0x6C6860)   // tertiary
    static let pOnFill = Color.white                // on accent / dark fills

    // Surfaces (warm neutral)
    static let pDesk = parley(0xE8E6E1, 0x14120F)   // behind windows
    static let pCanvas = parley(0xFDFCFA, 0x1C1A17) // window body / notes
    static let pRail = parley(0xF5F3EF, 0x201E19)   // right rail / sidebar
    static let pChrome = parley(0xF6F4F0, 0x201E1A) // toolbar / status bar
    static let pWidget = parley(0xEDEBE6, 0x1A1815) // widget canvas
    static let pCard = parley(0xFFFFFF, 0x241F1B)   // cards, panels
    static let pPuck = parley(0xFFFFFF, 0x262320)   // floating puck
    static let pField = parley(0xFBFAF8, 0x17150F)  // inputs (rest bg)
    static let pChip = parley(0xF1EFEA, 0x2A2721)   // ⌘K chip

    // Lines & controls
    static let pLine = parley(0xE5E1D9, 0x322E28)   // primary separators
    static let pLine2 = parley(0xEEEBE4, 0x2A2721)  // inside cards
    static let pTrackOff = parley(0xD8D4CC, 0x3C382F)
    static let pControlBorder = parley(0xCFC9BC, 0x4C463D)
    static let pSelection = parley(0xE9E6E0, 0x2E2A24)
    static let pButtonBorder = parley(0xDCD8D0, 0x3A362F)
    static let pWidgetBorder = parley(0xE0DCD4, 0x34302A)   // floating widget / HUD / popover rims

    // Accent (≤3 uses per screen) + danger + success
    static let pAccent = parley(0xB15B3B, 0xB15B3B)
    static let pOnAccent = parley(0x232120, 0xF4EFEA)       // readable text ON an accent-tinted fill (both themes)
    static let pDanger = parley(0xC0442E, 0xE0745C)
    static let pSuccess = Color(nsColor: .systemGreen)
}

// MARK: - Typography (system font; max 5 sizes)

enum PFont {
    /// Meeting document title — once per screen.
    static let title = Font.system(size: 26, weight: .semibold)
    /// Section headings / settings category.
    static let heading = Font.system(size: 18, weight: .semibold)
    /// Notes body — the primary reading size.
    static let body = Font.system(size: 15, weight: .regular)
    /// Secondary: actions, transcript, settings rows, buttons.
    static let secondary = Font.system(size: 13, weight: .regular)
    static let secondaryStrong = Font.system(size: 13, weight: .semibold)
    /// Labels (uppercase, tracked), timestamps, key hints.
    static let label = Font.system(size: 11, weight: .semibold)
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

enum PRadius {
    static let window: CGFloat = 10
    static let card: CGFloat = 10
    static let widget: CGFloat = 14
    static let puck: CGFloat = 16
    static let control: CGFloat = 7
    static let button: CGFloat = 8
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
