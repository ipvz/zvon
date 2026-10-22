import SwiftUI
import AppKit

/// Presentation state belongs to the overlay, not to the screenshot/undo model.
@MainActor
final class ScreenshotToolbarState: ObservableObject {
    @Published var showsOptions = false
}

/// A single compact row embedded in the capture overlay.
struct ScreenshotToolbarView: View {
    static let size = CGSize(width: 576, height: 46)
    @ObservedObject var document: ScreenshotDocument
    @ObservedObject var state: ScreenshotToolbarState
    var copy: () -> Void
    var save: () -> Void
    var cancel: () -> Void
    var finishText: () -> Void
    private let accent = Color(red: 0.3, green: 0.75, blue: 0.75)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                toolButton("Изменить область", symbol: "crop", active: document.adjustingCrop) {
                    state.showsOptions = false
                    document.adjustingCrop = true; document.select(nil)
                }
                separator
                HStack(spacing: 2) {
                    ForEach(ScreenshotTool.allCases) { tool in
                        toolButton("\(tool.title) (\(tool.key.uppercased()))", symbol: tool.symbol,
                                   active: !document.adjustingCrop && document.tool == tool) {
                            document.chooseTool(tool)
                        }
                    }
                }
                separator
                Button { state.showsOptions.toggle() } label: {
                    HStack(spacing: 2) {
                        Circle().fill(Color(nsColor: document.style.color.nsColor))
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }
                    .frame(width: 28, height: 30)
                    .background(state.showsOptions ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .help("Цвет, размер и оформление выбранного объекта")
                .accessibilityLabel("Цвет и параметры инструмента")
                .disabled(document.adjustingCrop || (document.tool == .select && document.selected == nil && document.textDraft == nil))
                HStack(spacing: 2) {
                    iconButton("Отменить — Command Z", symbol: "arrow.uturn.backward") { document.undo() }.disabled(!document.canUndo || document.textDraft != nil)
                    iconButton("Повторить — Command Shift Z", symbol: "arrow.uturn.forward") { document.redo() }.disabled(!document.canRedo || document.textDraft != nil)
                }
                separator
                HStack(spacing: 2) {
                    Button(action: document.textDraft == nil ? copy : finishText) {
                        Group {
                            if document.exporting { ProgressView().controlSize(.small) }
                            else { Image(systemName: document.textDraft == nil ? "doc.on.doc" : "checkmark").font(.system(size: 13, weight: .semibold)) }
                        }
                        .frame(width: 28, height: 30)
                        .foregroundStyle(Color(red: 0.07, green: 0.16, blue: 0.17))
                        .background(accent, in: RoundedRectangle(cornerRadius: 7))
                    }.help(document.textDraft == nil ? "Копировать — Control C, Command C или Enter" : "Применить текст — Enter")
                        .accessibilityLabel(document.textDraft == nil ? "Копировать" : "Применить текст")
                    iconButton("Сохранить — Command S", symbol: "square.and.arrow.down", action: save)
                    iconButton("Закрыть — Escape", symbol: "xmark", action: cancel)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.size.height)
            if let error = document.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(width: Self.size.width)
        .modifier(ScreenshotPaletteSurface())
        .buttonStyle(ScreenshotPaletteButtonStyle())
        .disabled(document.exporting)
        .onChange(of: document.adjustingCrop) { _, crop in if crop { state.showsOptions = false } }
        .onChange(of: document.textDraft?.id) { _, id in if id != nil { state.showsOptions = false } }
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18) }
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 30) }
            .help(title).accessibilityLabel(title)
    }
    private func toolButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if document.textDraft != nil { finishText() }
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 30)
                .foregroundStyle(active ? accent : .white.opacity(0.85))
                .background(active ? accent.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.help(title).accessibilityLabel(title)
    }
}

/// An optional card in the same NSPanel as the selection, never a popover window.
struct ScreenshotToolOptionsView: View {
    @ObservedObject var document: ScreenshotDocument
    private let colors = [NSColor.systemRed, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .white, .black]
    private var activeTool: ScreenshotTool { document.textDraft?.tool ?? document.selected?.tool ?? document.tool }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activeTool.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if document.selected != nil && document.textDraft == nil {
                    Button { document.deleteSelection() } label: { Image(systemName: "trash").frame(width: 22, height: 20) }
                        .help("Удалить объект").accessibilityLabel("Удалить объект")
                }
            }
            if activeTool.isEffect {
                HStack {
                    Text("Сила").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: styleBinding(\.effectStrength), in: 4...60, step: 2, onEditingChanged: styleEditing)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Button {
                            var style = document.style; style.color = AnnotationColor(color); document.updateStyle(style)
                        } label: {
                            Circle().fill(Color(nsColor: color)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(document.style.color == AnnotationColor(color) ? .white : .clear, lineWidth: 1.5))
                        }.help(color.accessibilityName).accessibilityLabel(color.accessibilityName)
                    }
                }
                if activeTool == .text { sizePresets([16, 20, 28, 36], title: "Размер", key: \.fontSize) }
                else if activeTool == .marker { sizePresets([12, 20, 32], title: "Толщина", key: \.lineWidth, multiplier: 0.25) }
                else if activeTool != .redact { sizePresets([2, 3, 5, 8], title: "Толщина", key: \.lineWidth) }
                HStack(spacing: 5) {
                    if [.arrow, .rectangle, .ellipse, .pen].contains(activeTool) { flag("Контур", key: \.outline) }
                    if activeTool == .rectangle { flag("Скругление", key: \.rounded) }
                    if [.rectangle, .ellipse].contains(activeTool) { flag("Заливка", key: \.filled) }
                    if activeTool == .text { flag("Подложка", key: \.textBackground) }
                }
                if activeTool == .text {
                    Text("Углы — размер букв · Бока — переносы").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if activeTool == .arrow {
                    Text("Потяни за концы, чтобы изменить стрелку").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12).frame(width: 254)
        .modifier(ScreenshotPaletteSurface())
        .buttonStyle(ScreenshotPaletteButtonStyle())
        .disabled(document.exporting)
    }

    private func flag(_ title: String, key: WritableKeyPath<AnnotationStyle, Bool>) -> some View {
        Button {
            var style = document.style; style[keyPath: key].toggle(); document.updateStyle(style)
        } label: {
            Text(title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).frame(height: 24)
                .foregroundStyle(document.style[keyPath: key] ? .white : .secondary)
                .background(.white.opacity(document.style[keyPath: key] ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 5))
        }.accessibilityLabel(title).accessibilityValue(document.style[keyPath: key] ? "Включено" : "Выключено")
    }
    private func sizePresets(_ values: [CGFloat], title: String, key: WritableKeyPath<AnnotationStyle, CGFloat>, multiplier: CGFloat = 1) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ForEach(values, id: \.self) { value in
                let selected = abs(document.style[keyPath: key] - value * multiplier * document.pixelScale) < 0.1
                Button {
                    var style = document.style; style[keyPath: key] = value * multiplier * document.pixelScale; document.updateStyle(style)
                } label: {
                    Text("\(Int(value))").font(.system(size: 11, weight: selected ? .semibold : .regular)).frame(width: 27, height: 24)
                        .background(.white.opacity(selected ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 5))
                }.help("\(Int(value)) pt").accessibilityLabel("\(title): \(Int(value))")
            }
        }
    }
    private func styleBinding(_ key: WritableKeyPath<AnnotationStyle, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { document.style[keyPath: key] }, set: { value in
            var style = document.style; style[keyPath: key] = value; document.updateStyle(style)
        })
    }
    private func styleEditing(_ editing: Bool) {
        if editing { document.beginEdit() } else { document.commitEdit() }
    }
}

private struct ScreenshotPaletteSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.10, green: 0.115, blue: 0.125), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.3, green: 0.75, blue: 0.75))
    }
}

private struct ScreenshotPaletteButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.85))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
            .contentShape(Rectangle())
    }
}
