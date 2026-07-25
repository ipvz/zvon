import SwiftUI

// MARK: - App mark (3 bars)

struct ParleyMark: View {
    var barWidth: CGFloat = 3
    var heights: [CGFloat] = [12, 20, 15]
    var color: Color = .pInk1
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().fill(color).frame(width: barWidth, height: h)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Recording dot (accent, informational breathe only)

struct RecordingDot: View {
    var size: CGFloat = 7
    var breathe: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle().fill(Color.pRecording).frame(width: size, height: size)   // recording status = red (ZVON)
            .opacity(breathe && !reduceMotion ? (on ? 1 : 0.5) : 1)
            .animation(breathe && !reduceMotion ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Spinner (premium clay comet-arc)

/// A smooth rotating arc with an angular-gradient fade (comet tail) in the accent — replaces the
/// stock system spinner. Honors reduce-motion.
struct PSpinner: View {
    var size: CGFloat = 22
    var color: Color = .pAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(gradient: Gradient(colors: [color.opacity(0), color.opacity(0.15), color]),
                                center: .center),
                style: StrokeStyle(lineWidth: max(2, size * 0.11), lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? .default : .linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Labels & rules

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(PFont.label)
            .tracking(0.6)
            .foregroundStyle(Color.pInk3)
    }
}

struct Hairline: View {
    var color: Color = .pLine
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

struct VHairline: View {
    var color: Color = .pLine
    var body: some View { Rectangle().fill(color).frame(width: 1) }
}

// MARK: - Card

struct PCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.pCard)
            .clipShape(RoundedRectangle(cornerRadius: PRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

// MARK: - Focus ring

struct FocusRing: ViewModifier {
    var focused: Bool
    var radius: CGFloat = PRadius.control
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(focused ? Color.pAccent : Color.clear, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(focused ? Color.pAccent.opacity(0.22) : Color.clear, lineWidth: 3)
                        .padding(-2)
                )
        )
    }
}

extension View {
    func focusRing(_ focused: Bool, radius: CGFloat = PRadius.control) -> some View {
        modifier(FocusRing(focused: focused, radius: radius))
    }
}

// MARK: - Level meter (driven by real energy)

struct LevelMeterView: View {
    var levels: [Float]
    var active: Bool
    var bars: Int = 6
    var leading: Int = 3   // only the leading bars are driven/inked; the rest stay static (spec)
    private let maxH: CGFloat = 16
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                // Fixed height + scaleEffect (transform), not an animated height — the latter
                // invalidates layout every frame and crashes NSISEngine in a preferredContentSize panel.
                Capsule()
                    .fill(active && i < leading ? Color.pInk1 : Color.pControlBorder)
                    .frame(width: 3, height: maxH)
                    .scaleEffect(x: 1, y: scale(i), anchor: .bottom)
            }
        }
        .frame(height: maxH)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
    private func scale(_ i: Int) -> CGFloat {
        let staticS = 5 / maxH
        guard active, i < leading, !levels.isEmpty else { return staticS }
        let w = Array(levels.suffix(leading))
        guard i < w.count else { return staticS }
        let v = CGFloat(max(0, min(1, w[i] * 6)))
        return (4 + v * 12) / maxH
    }
}

// MARK: - Checkbox / radio

struct ParleyCheckbox: View {
    var checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(checked ? Color.pInk1 : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(checked ? Color.clear : Color.pControlBorder, lineWidth: 1.5))
            .frame(width: 16, height: 16)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.pCard)
                    .opacity(checked ? 1 : 0)
            )
    }
}

struct ParleyRadio: View {
    var selected: Bool
    var body: some View {
        Circle()
            .strokeBorder(selected ? Color.pInk1 : Color.pControlBorder, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .overlay(Circle().fill(Color.pInk1).frame(width: 8, height: 8).opacity(selected ? 1 : 0))
    }
}

// MARK: - Buttons

struct PBorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }
    struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(PFont.secondary)
                .foregroundStyle(Color.pInk1)
                .padding(.horizontal, PSpace.s)
                .padding(.vertical, PSpace.xs)
                .background(Color.pField)
                .clipShape(RoundedRectangle(cornerRadius: PRadius.button))
                .overlay(RoundedRectangle(cornerRadius: PRadius.button).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.7 : 1))
        }
    }
}

struct PPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }
    struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(PFont.secondaryStrong)
                .foregroundStyle(Color.pCanvas)   // fill is pInk1 (light in dark theme) → text must be dark
                .padding(.horizontal, PSpace.m)
                .padding(.vertical, PSpace.xs)
                .background(Color.pInk1)
                .clipShape(RoundedRectangle(cornerRadius: PRadius.button))
                .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.8 : 1))
        }
    }
}

// MARK: - Note bullet

struct NoteBullet: View {
    let text: String
    var secondary: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: PSpace.s) {
            Circle().fill(Color.pInk3).frame(width: 4, height: 4).padding(.top, 9)
            Text(text)
                .font(PFont.body)
                .lineSpacing(4)
                .foregroundStyle(secondary ? Color.pInk2 : Color.pInk1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Key hint

struct KeyHintView: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: PSpace.xxs) {
            Text(keys).font(PFont.mono).foregroundStyle(Color.pInk3)
            Text(label).font(PFont.secondary).foregroundStyle(Color.pInk3)
        }
    }
}

/// Static hotkey glyph for hints.
enum Hotkeys {
    static let record = "⌘⇧R"
    static let mark = "⌘M"
    static let search = "⌘K"
    static let export = "⌘E"
    static let openNotes = "⌘↩"
    static let settings = "⌘,"
}
