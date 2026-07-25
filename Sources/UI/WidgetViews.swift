import SwiftUI
import AppKit

// MARK: - Floating widget root (puck ↔ compact ↔ expanded, + error)

struct WidgetRootView: View {
    @ObservedObject var store: TranscriptStore
    var body: some View {
        Group {
            if case .error = store.status, store.isRecording {
                WidgetError(store: store)
            } else {
                switch store.widgetSize {
                case .puck: PuckView(store: store)
                case .compact: CompactWidget(store: store)
                case .expanded: ExpandedWidget(store: store)
                }
            }
        }
        .preferredColorScheme(nil)
        // Right-click anywhere on the widget → hide it (also in the menu-bar popover + Settings).
        .contextMenu {
            Button("Скрыть виджет") { store.widgetHidden = true }
            Button("Открыть Parley") {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
            }
        }
    }
}

// MARK: - Puck (56×56) with equalizer mark

struct PuckView: View {
    @ObservedObject var store: TranscriptStore
    private var live: Bool { store.isRecording && !store.isPaused }   // accent + motion only when truly recording
    private var dictating: Bool { store.isDictating }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PRadius.puck).fill(Color.pPuck)
                .overlay(RoundedRectangle(cornerRadius: PRadius.puck)
                    .strokeBorder(dictating ? Color.pAccent : Color.pWidgetBorder, lineWidth: dictating ? 1.5 : 1))
            EqualizerMark(active: live || dictating, color: (store.isRecording || dictating) ? .pInk1 : .pInk2)
            // Accent recording dot — fully inside the top-right corner (no halo, reads on any wallpaper).
            if live {
                Circle().fill(Color.pAccent).frame(width: 10, height: 10).offset(x: 16, y: -16)
            }
        }
        .frame(width: 56, height: 56)
        // Disclosure chip at the bottom edge — signals "opens a panel" (spec §1).
        .overlay(alignment: .bottom) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.pInk2)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.pPuck))
                .overlay(Circle().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
                .offset(y: 8)
                .accessibilityHidden(true)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
        .padding(22)
        .contentShape(Rectangle())
        // Tap → context-aware: Compact when idle, Expanded (live monitor) while recording.
        .onTapGesture { store.widgetSize = store.isRecording ? .expanded : .compact }
        // Press-and-hold the puck → push-to-talk dictation (release inserts). Hotkey ⌥Space also works.
        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 10,
                            pressing: { pressing in if !pressing { store.stopDictation() } },
                            perform: { store.startDictation() })
        .accessibilityLabel(store.isRecording ? "Идёт запись" : "Parley")
    }
}

/// The 3-bar Parley mark as a slow organic equalizer while recording (not a spinner).
struct EqualizerMark: View {
    var active: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var s: [CGFloat] = [1, 1, 1]
    private let base: [CGFloat] = [12, 20, 15]
    private let dur: [Double] = [1.1, 1.35, 0.95]
    private let delay: [Double] = [0.0, 0.18, 0.34]
    private let low: [CGFloat] = [0.5, 0.55, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                // Fixed height + scaleEffect (a transform) — animating the *height* invalidates
                // layout every frame, which crashes NSISEngine inside a .preferredContentSize panel.
                // This also matches the mockup's `transform: scaleY(...)`.
                Capsule().fill(color)
                    .frame(width: 3, height: base[i])
                    .scaleEffect(x: 1, y: s[i], anchor: .center)
            }
        }
        .frame(width: 15, height: 20)
        .onAppear { animate() }
        .onChange(of: active) { _, _ in animate() }
    }

    private func animate() {
        guard active, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.3)) { s = [1, 1, 1] }
            return
        }
        for i in 0..<3 {
            s[i] = 1
            withAnimation(.easeInOut(duration: dur[i]).repeatForever(autoreverses: true).delay(delay[i])) {
                s[i] = low[i]
            }
        }
    }
}

// MARK: - Compact (300)

struct CompactWidget: View {
    @ObservedObject var store: TranscriptStore
    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            WidgetHeader(store: store, onCollapse: { store.widgetSize = .puck })
            if store.isRecording {
                liveLine(store.latestLine)
                HStack(spacing: PSpace.xs) {
                    WidgetTapButton(title: store.isPaused ? "Продолжить" : "Пауза") { store.togglePause() }
                    WidgetTapButton(title: "Развернуть") { store.widgetSize = .expanded }
                }
            } else {
                WidgetTapButton(title: "Начать запись") { if store.canRecord { store.toggle() } }
            }
        }
        .padding(PSpace.m)
        .frame(width: 300)
        .widgetPanel()
    }

    @ViewBuilder
    private func liveLine(_ line: TranscriptLine?) -> some View {
        // Fixed two-line height so streaming text can't resize the NSPanel every tick (that constant
        // frame churn on a .preferredContentSize panel is the NSISEngine crash class).
        Group {
            if let line {
                (Text(line.speaker.title + " ").font(PFont.secondaryStrong).foregroundColor(line.speaker == .me ? Color.pInk1 : Color.pAccent)
                    + Text(line.isFinal ? line.text : line.text + "…").font(PFont.secondary).foregroundColor(line.isFinal ? Color.pInk2 : Color.pInk3))
                    .lineLimit(2)
            } else {
                Text("Слушаю…").font(PFont.secondary).foregroundStyle(Color.pInk3)
            }
        }
        .frame(height: 38, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Expanded (440) — dialogue by side, ✦ Итог footer

struct ExpandedWidget: View {
    @ObservedObject var store: TranscriptStore
    private var meterActive: Bool { store.isRecording && !store.isPaused }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(store: store, onCollapse: { store.widgetSize = .puck })
                .padding(.horizontal, PSpace.m).padding(.vertical, 14)
            Hairline(color: .pLine2)
            dialogue
            Hairline(color: .pLine2)
            HStack(spacing: PSpace.xs) {
                itogButton
                Spacer()
                Text("Открыть заметки").font(PFont.secondary).foregroundStyle(Color.pInk2)
                    .contentShape(Rectangle()).onTapGesture { openNotes() }
            }
            .padding(.horizontal, PSpace.m).padding(.vertical, PSpace.s)
        }
        .frame(width: 440)
        .widgetPanel()
    }

    private var itogButton: some View {
        HStack(spacing: 6) { Text("✦").foregroundStyle(Color.pAccent); Text("Итог") }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pOnAccent)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Color.pAccent.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pAccent.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { store.regenerateNotes(); openNotes() }
    }

    private var dialogue: some View {
        let lastId = store.lines.last?.id
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.lines.isEmpty {
                        Text(store.isRecording ? "Parley слушает разговор…" : "Нажмите «Начать запись».")
                            .font(PFont.secondary).foregroundStyle(Color.pInk3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, PSpace.xs)
                    } else {
                        ForEach(Array(store.lines.enumerated()), id: \.element.id) { idx, line in
                            MessageBubble(line: line,
                                          showLabel: idx == 0 || store.lines[idx - 1].speaker != line.speaker,
                                          showMeter: line.id == lastId && meterActive,
                                          levels: line.speaker == .me ? store.levels : store.levelsThem,
                                          meterActive: meterActive).id(line.id)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 236)
            .onChange(of: store.lines.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func openNotes() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
    }
}

/// A chat bubble with a source label above: Собеседник left/neutral, Вы right/accent-tinted.
/// The label shows only when the speaker changes (grouped, iMessage-style) so runs of the same
/// speaker don't get a redundant label between every bubble.
struct MessageBubble: View {
    let line: TranscriptLine
    var showLabel: Bool = true
    var showMeter: Bool = false
    var levels: [Float] = []
    var meterActive: Bool = false
    private var mine: Bool { line.speaker == .me }
    private var sourceLabel: String { mine ? "Микрофон · Вы" : "Динамик · Собеседник" }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if showLabel || showMeter {
                HStack(spacing: 8) {
                    if mine && showMeter { LevelMeterView(levels: levels, active: meterActive, bars: 3, leading: 2) }
                    if showLabel { Text(sourceLabel).font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(Color.pInk3) }
                    if !mine && showMeter { LevelMeterView(levels: levels, active: meterActive, bars: 3, leading: 2) }
                }
            }
            Text(line.isFinal ? line.text : line.text + "…")
                .font(.system(size: 14)).lineSpacing(3)
                .foregroundStyle(mine ? Color.pOnAccent : Color.pInk1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(mine ? Color.pAccent.opacity(0.24) : Color.pSelection)
                .clipShape(bubbleShape)
                .overlay(bubbleShape.strokeBorder(mine ? Color.pAccent.opacity(0.42) : Color.pWidgetBorder, lineWidth: 1))
                .frame(maxWidth: 340, alignment: mine ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        mine ? UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14)
             : UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14)
    }
}

// MARK: - Shared header + error + panel chrome

struct WidgetHeader: View {
    @ObservedObject var store: TranscriptStore
    var onCollapse: (() -> Void)?
    var body: some View {
        HStack(spacing: PSpace.xs) {
            if store.isRecording && !store.isPaused {
                RecordingDot(size: 8)
                Text("Запись").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk2) }
            } else if store.isPaused {
                Circle().fill(Color.pControlBorder).frame(width: 8, height: 8)
                Text("Пауза").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk3) }
            } else {
                Circle().fill(isErrorStage ? Color.pDanger : Color.pControlBorder).frame(width: 8, height: 8)
                Text(idleStatus).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1).lineLimit(1)
                Spacer()
                if store.stage == .ready { Text(Hotkeys.record).font(PFont.mono).foregroundStyle(Color.pInk3) }
            }
            if let onCollapse {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.pInk2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCollapse)
            }
        }
    }

    private var isErrorStage: Bool { if case .error = store.stage { return true }; return false }

    private var idleStatus: String {
        switch store.stage {
        case .ready, .listening: return "Готов к записи"
        case .preparing: return "Готовлю модель…"
        case .downloading(let f): return "Скачиваю \(Int(f * 100))%"
        case .needsModel: return "Модель не загружена"
        case .error: return "Ошибка"
        }
    }
}

struct WidgetError: View {
    @ObservedObject var store: TranscriptStore
    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            HStack(spacing: PSpace.xs) {
                Circle().fill(Color.pDanger).frame(width: 8, height: 8)
                Text("Микрофон недоступен").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
            }
            Text("Запись на паузе. Аудио буферизуется локально, пока устройство не вернётся.")
                .font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PSpace.s) {
                Button("Повторить") { store.stop(); store.start() }.buttonStyle(PBorderedButtonStyle())
                Button("Настройки звука") { NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.plain)
                    .font(PFont.secondary).foregroundStyle(Color.pInk2)
            }
        }
        .padding(PSpace.m).frame(width: 300).widgetPanel()
    }
}

private struct WidgetPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.pCard)
            .clipShape(RoundedRectangle(cornerRadius: PRadius.widget))
            .overlay(RoundedRectangle(cornerRadius: PRadius.widget).strokeBorder(Color.pLine, lineWidth: 1))
            .shadow(color: Color(red: 45/255, green: 38/255, blue: 30/255).opacity(0.28), radius: 16, x: 0, y: 12)
            .padding(10)
    }
}
extension View { func widgetPanel() -> some View { modifier(WidgetPanelChrome()) } }

/// Tap-based button — reliable inside a non-activating NSPanel where AppKit Buttons may not
/// receive clicks (the panel never becomes key). Styled like the bordered/primary buttons.
struct WidgetTapButton: View {
    let title: String
    var filled: Bool = false
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(PFont.secondaryStrong)
            .foregroundStyle(filled ? Color.pOnFill : Color.pInk1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PSpace.xs + 1)
            .background(filled ? Color.pInk1 : Color.pField)
            .clipShape(RoundedRectangle(cornerRadius: PRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(filled ? Color.clear : Color.pButtonBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: - Dictation HUD (spectrogram pill while dictating · no-field card on finish)

/// Host panel is a fixed frame with NO `.preferredContentSize` (that path crashes NSISEngine on
/// rapid content updates). The controller sizes the panel per mode from the statics below.
struct DictationHUDView: View {
    @ObservedObject var store: TranscriptStore
    // Sizes include a margin ≥ the card/pill shadow radius so the shadow is never clipped into a
    // hard-edged rectangle (that clip is the "frame" artifact behind the card).
    static let pillSize = CGSize(width: 150, height: 92)
    static let processingSize = CGSize(width: 220, height: 92)
    static let cardSize = CGSize(width: 424, height: 300)

    static func size(for store: TranscriptStore) -> CGSize {
        store.isDictating ? pillSize : cardSize
    }

    var body: some View {
        ZStack {
            if store.isDictating {
                SpectrogramPill(store: store)
            } else if store.dictationProcessing {
                ProcessingPill()
            } else if let text = store.dictationCard {
                if store.dictationCardIsTask {
                    TaskCreatedCard(store: store, text: text)
                } else {
                    NoFieldCard(store: store, text: text)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Shown while the LLM polishes a dictation before it's inserted (brief, dictation-only).
struct ProcessingPill: View {
    var body: some View {
        HStack(spacing: 9) {
            PSpinner(size: 15)
            Text("Обрабатываю…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk2)
        }
        .frame(height: 18).padding(.horizontal, 16)
        .background(Color.pCard).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 5)
    }
}

/// The dictating affordance: thin bars driven by the LIVE mic level (scaleY = transform, not
/// layout). Quiet → bars rest flat; speaking → they move. No perpetual canned animation.
struct SpectrogramPill: View {
    @ObservedObject var store: TranscriptStore
    private let count = 13
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(Color.pInk1)
                    .frame(width: 2, height: 14)
                    .scaleEffect(x: 1, y: scale(i), anchor: .center)
            }
        }
        .frame(height: 16).padding(.horizontal, 12)
        .background(Color.pCard).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 5)
        .animation(.easeOut(duration: 0.1), value: store.levels)
    }
    private func scale(_ i: Int) -> CGFloat {
        let base: CGFloat = 0.14   // near-flat when silent
        let w = Array(store.levels.suffix(count))
        let idx = i - (count - w.count)
        guard idx >= 0, idx < w.count else { return base }
        let v = CGFloat(max(0, min(1, w[idx] * 7)))
        return base + v * (1 - base)
    }
}

/// Shown when there was no editable field: the text was auto-copied; re-copy or dismiss.
struct NoFieldCard: View {
    @ObservedObject var store: TranscriptStore
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach([CGFloat(7), 13, 9, 11], id: \.self) { h in
                        Capsule().fill(Color.pInk2).frame(width: 2, height: h)
                    }
                }
                Text("Сначала выберите поле, затем диктуйте").font(PFont.secondary).foregroundStyle(Color.pInk3)
                Spacer()
                Button { store.dismissDictationCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Color.pInk2)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Закрыть")
            }
            Text(text).font(PFont.body).lineSpacing(3).foregroundStyle(Color.pInk1)
                .lineLimit(4).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Скопировано · закроется через 8с").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                Spacer()
                HStack(spacing: 7) { Text("⧉").foregroundStyle(Color.pAccent); Text("Скопировать") }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                    .contentShape(Rectangle()).onTapGesture { copy() }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 360, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
    }
    private func copy() {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
        store.dismissDictationCard()
    }
}

/// Confirmation shown after a spoken "создай задачу …" — the task is already in the tracker; the
/// wording is being refined by the LLM in the background.
struct TaskCreatedCard: View {
    @ObservedObject var store: TranscriptStore
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.pAccent)
                Text("Задача создана").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                Button { store.dismissDictationCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Color.pInk2)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Закрыть")
            }
            Text(text).font(PFont.body).lineSpacing(3).foregroundStyle(Color.pInk1)
                .lineLimit(3).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Уточняется через ИИ…").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                Spacer()
                Text("Открыть задачи")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                    .contentShape(Rectangle()).onTapGesture { openTasks() }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 360, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
    }
    private func openTasks() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
        store.pendingOpenTasks = true
        store.dismissDictationCard()
    }
}

// MARK: - Menu-bar popover content

struct MenuBarPopover: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var sessions = SessionStore.shared
    var closePopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            header
            primaryButton
            Hairline(color: .pLine2)
            VStack(alignment: .leading, spacing: 2) {
                let recent = Array(sessions.sessions.prefix(3))
                if !recent.isEmpty {
                    Text("Недавние").font(PFont.label).tracking(0.5).foregroundStyle(Color.pInk3).padding(.vertical, 4)
                    ForEach(recent) { s in
                        menuRow { store.pendingOpenSession = s.id; openMain(); closePopover() } content: {
                            Text(s.title).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                            Spacer(minLength: PSpace.s)
                            Text(Self.relativeShort(s.date)).font(PFont.mono).foregroundStyle(Color.pInk3)
                        }
                    }
                    Hairline(color: .pLine2).padding(.vertical, 4)
                }
                popRow("Открыть Parley", Hotkeys.openNotes) { openMain(); closePopover() }
                popRow(store.widgetHidden ? "Показать виджет" : "Скрыть виджет", "") {
                    if store.widgetHidden { FloatingWidgetController.shared?.reveal() } else { store.widgetHidden = true }
                    closePopover()
                }
                popRow("Настройки", Hotkeys.settings) { openMain(); store.pendingOpenSettings = true; closePopover() }
                popRow("Выйти", "⌘Q") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(PSpace.m)
        .frame(width: 300)
        .background(Color.pCard)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: PSpace.xs) {
            if store.isRecording && !store.isPaused {
                RecordingDot(size: 8)
                Text("Запись").font(PFont.secondaryStrong)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk2) }
            } else if store.isPaused {
                Circle().fill(Color.pControlBorder).frame(width: 8, height: 8)
                Text("Пауза").font(PFont.secondaryStrong)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk3) }
            } else {
                Circle().fill(Color.pControlBorder).frame(width: 8, height: 8)
                Text("Готов к записи").font(PFont.secondaryStrong)
                Spacer()
                Text(Hotkeys.record).font(PFont.mono).foregroundStyle(Color.pInk3)
            }
        }
    }

    /// Full-width accent-tinted primary (Start), or a bordered danger-square Stop while recording.
    @ViewBuilder private var primaryButton: some View {
        if store.isRecording {
            Button { store.stop(); closePopover() } label: {
                HStack(spacing: PSpace.xs) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.pDanger).frame(width: 9, height: 9)
                    Text("Остановить запись")
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            }.buttonStyle(.plain)
        } else {
            Button { if store.canRecord { store.start(); closePopover() } } label: {
                HStack(spacing: PSpace.xs) {
                    Circle().fill(Color.pAccent).frame(width: 9, height: 9)
                    Text("Начать запись")
                }
                .font(PFont.secondaryStrong).foregroundStyle(Color.pOnAccent)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.pAccent.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pAccent.opacity(0.45), lineWidth: 1))
                .opacity(store.canRecord ? 1 : 0.5)
            }.buttonStyle(.plain)
        }
    }

    /// A menu row with a subtle accent hover highlight.
    private func menuRow<C: View>(_ action: @escaping () -> Void, @ViewBuilder content: @escaping () -> C) -> some View {
        PopRowButton(action: action) { HStack(spacing: 0) { content() } }
    }

    private func popRow(_ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        menuRow(action) {
            Text(title).font(PFont.secondary).foregroundStyle(Color.pInk1)
            Spacer()
            Text(key).font(PFont.mono).foregroundStyle(Color.pInk3)
        }
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f }()
    private static let wd: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "EEEEEE"; return f }()
    private static let md: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"; return f }()
    static func relativeShort(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return hm.string(from: date) }
        if cal.isDateInYesterday(date) { return "вчера" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 { return wd.string(from: date) }
        return md.string(from: date)
    }
}

/// A popover row: single-click (real Button, unlike onTapGesture which needs two clicks in a
/// popover) with a subtle accent hover highlight.
private struct PopRowButton<C: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> C
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // Bleed slightly past the content edges so the highlight has a margin from the popover
            // rim (like a native macOS menu row) instead of looking clipped to the text column.
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.pAccent.opacity(0.14) : Color.clear)
                .padding(.horizontal, -8)
        )
        .onHover { hovering = $0 }
    }
}

/// One row of the tasks popover: checkbox (toggle only) + text (open only), separate hit targets so
/// closing a task from the bar never navigates to the window.
private struct TaskPopRow: View {
    let t: TaskItem
    let source: String?
    let toggle: () -> Void
    let openTask: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            // Big hit target (30pt) around the 16pt box — the tiny box alone was near-impossible to click.
            Button(action: toggle) {
                TaskCheck(done: t.done).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: openTask) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.text).font(PFont.secondary).foregroundStyle(t.done ? Color.pInk3 : Color.pInk1)
                        .strikethrough(t.done, color: .pInk3).lineLimit(1)
                    if let source {
                        Text(source).font(.system(size: 11)).foregroundStyle(Color.pInk3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.pAccent.opacity(0.14) : Color.clear)
                .padding(.horizontal, -8)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Tasks menu-bar popover (open tasks, checkable straight from the bar)

struct TasksMenuPopover: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var tasks = TaskStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    var closePopover: () -> Void

    var body: some View {
        let open = tasks.open
        VStack(alignment: .leading, spacing: PSpace.s) {
            HStack {
                Text("Открытые задачи").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                if !open.isEmpty {
                    Text("\(open.count)").font(PFont.label).foregroundStyle(Color.pInk2)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Color.pSelection).clipShape(Capsule())
                }
            }
            Hairline(color: .pLine2)
            if open.isEmpty {
                Text("Нет открытых задач").font(PFont.secondary).foregroundStyle(Color.pInk3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(open.prefix(8)) { taskRow($0) }
                }
                if open.count > 8 {
                    Text("ещё \(open.count - 8)").font(.system(size: 11)).foregroundStyle(Color.pInk3).padding(.leading, 2)
                }
            }
            Hairline(color: .pLine2)
            PopRowButton(action: openAll) {
                HStack(spacing: 0) {
                    Text("Открыть все задачи").font(PFont.secondary).foregroundStyle(Color.pInk1).fixedSize()
                    Spacer(minLength: PSpace.s)
                    Text(Hotkeys.openNotes).font(PFont.mono).foregroundStyle(Color.pInk3)
                }
            }
        }
        .padding(PSpace.m)
        .frame(width: 300)
        .background(Color.pCard)
    }

    private func taskRow(_ t: TaskItem) -> some View {
        // Two SEPARATE tap targets (NOT a Button inside a Button — that fires both): the checkbox
        // only toggles (close straight from the bar), the text only opens the task in the window.
        TaskPopRow(t: t, source: source(t), toggle: { tasks.toggle(t.id) }, openTask: { open(t) })
    }

    private func source(_ t: TaskItem) -> String? {
        var parts: [String] = []
        if let sid = t.sessionId, let title = sessions.sessions.first(where: { $0.id == sid })?.title, !title.isEmpty {
            parts.append(title)
        }
        if let d = t.due, !d.isEmpty, d.lowercased() != "null" { parts.append(d) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func open(_ t: TaskItem) {
        focusMain(); store.pendingOpenTaskId = t.id; closePopover()
    }
    private func openAll() {
        focusMain(); store.pendingOpenTasks = true; closePopover()
    }
    private func focusMain() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
    }
}
