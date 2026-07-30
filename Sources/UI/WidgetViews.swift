import SwiftUI
import AppKit

// MARK: - Task reminder card (floating nudge about open tasks)

struct TaskReminderView: View {
    let controller: TaskReminderController
    @ObservedObject private var tasks = TaskStore.shared
    @ObservedObject private var loc = L11n.shared

    var body: some View {
        let open = tasks.open
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(Color.pAccent.opacity(0.16)).frame(width: 26, height: 26)
                    Image(systemName: "bell.fill").font(.system(size: 12)).foregroundStyle(Color.pAccent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Открытые задачи", "Open tasks")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.pInk1)
                    Text(L("\(open.count) \(MeetingView.plural(open.count, "задача", "задачи", "задач")) ждут",
                           "\(open.count) task\(open.count == 1 ? "" : "s") waiting")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                }
                Spacer(minLength: 8)
                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.pInk3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)

            Hairline(color: .pLine2)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(open.prefix(4)) { t in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.pAccent.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 6)
                        Text(t.text).font(.system(size: 12.5)).foregroundStyle(Color.pInk1).lineLimit(2)
                    }
                }
                if open.count > 4 {
                    Text(L("ещё \(open.count - 4)", "\(open.count - 4) more")).font(.system(size: 11)).foregroundStyle(Color.pInk3).padding(.leading, 12)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)

            Hairline(color: .pLine2)

            HStack(spacing: 8) {
                Button { controller.snooze() } label: {
                    Text(L("Отложить", "Snooze")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.pInk2)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                }.buttonStyle(.plain)
                Button { controller.openTasks() } label: {
                    Text(L("Открыть задачи", "Open tasks")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color.pAccent).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .frame(width: 360)
        .background(Color.pWidgetBG)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
    }
}

// MARK: - Floating widget root (puck ↔ compact ↔ expanded, + error)

struct WidgetRootView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var loc = L11n.shared
    var body: some View {
        Group {
            if case .error = store.status, store.isRecording {
                WidgetError(store: store)
            } else {
                switch store.widgetSize {
                case .puck: PuckView(store: store)
                case .expanded: ExpandedWidget(store: store)
                }
            }
        }
        .preferredColorScheme(nil)
        // Right-click anywhere on the widget → hide it (also in the menu-bar popover + Settings).
        .contextMenu {
            Button(L("Скрыть виджет", "Hide widget")) { store.widgetHidden = true }
            Button(L("Открыть ZVON", "Open ZVON")) {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
            }
        }
    }
}

// MARK: - Collapsed puck (62×62 app-icon tile) — states 1 & 2

struct PuckView: View {
    @ObservedObject var store: TranscriptStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var live: Bool { store.isRecording && !store.isPaused }

    var body: some View {
        tile
            // State 2: recording → red dot in the corner. Ring in the canvas colour so it separates
            // from the teal tile and reads on any window under the widget (spec §2).
            .overlay(alignment: .topTrailing) {
                if store.isRecording {
                    Circle().fill(Color.pRecording).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.pCanvas, lineWidth: 2.5))
                        .opacity(live && !reduceMotion ? (pulse ? 0.4 : 1) : 1)
                        .animation(live && !reduceMotion ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : .default, value: pulse)
                        .offset(x: 5, y: -5)
                }
            }
            // Bottom chip: chevron ⌄ when idle (state 1) → a mono timer pill while recording (state 2).
            .overlay(alignment: .bottom) { bottomChip.offset(y: 11) }
            .padding(20)
            .contentShape(Rectangle())
            .onTapGesture { store.widgetSize = .expanded }
            // Press-and-hold → push-to-talk dictation (release inserts). Hotkey ⌥Space also works.
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 10,
                                pressing: { p in if !p { store.stopDictation() } },
                                perform: { store.startDictation() })
            .onAppear { pulse = true }
            .accessibilityLabel(store.isRecording ? L("Идёт запись", "Recording") : "ZVON")
    }

    // §1: the app-icon tile one-to-one, radius 17, soft shadow.
    private var tile: some View {
        Group {
            if let mark = Brand.mark { Image(nsImage: mark).resizable() }
            else { RoundedRectangle(cornerRadius: PRadius.puck, style: .continuous).fill(Color.pAccent) }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: PRadius.puck, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 8)
    }

    @ViewBuilder private var bottomChip: some View {
        if store.isRecording, let s = store.recordingStartedAt {
            ElapsedText(since: s, color: .pInk1, font: .system(size: 10.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7).frame(height: 18)
                .background(Color.pWidgetBG).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        } else if !store.isRecording {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.pInk2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.pWidgetBG))
                .overlay(Circle().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Expanded panel (376 fixed width) — states 3 & 4

struct ExpandedWidget: View {
    @ObservedObject var store: TranscriptStore
    @State private var appeared = false
    private var recording: Bool { store.isRecording }
    private var meterActive: Bool { store.isRecording && !store.isPaused }
    private var mine: TranscriptLine? { store.latestLine(for: .me) }
    private var them: TranscriptLine? { store.latestLine(for: .them) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(store: store, onCollapse: { store.widgetSize = .puck })
                .padding(.horizontal, 13).frame(height: 44)
            Hairline(color: .pLine2)
            if recording {
                tracks
                Hairline(color: .pLine2)
                footer
            } else {
                idleBody
            }
        }
        .frame(width: 376)
        .widgetPanel()
        // Appearance (spec §3): 200ms cubic-bezier(.2,.8,.2,1) — opacity + rise + subtle scale.
        // All three are transforms/opacity (not layout) so they don't churn the panel's constraints.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
        .offset(y: appeared ? 0 : 8)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2), value: appeared)
        .onAppear { appeared = true }
    }

    // §2 body: only the last replica of each side; never accumulate, never scroll.
    private var tracks: some View {
        VStack(alignment: .leading, spacing: 11) {
            if mine == nil && them == nil {
                Text(meterActive ? L("Слушаю разговор…", "Listening to the conversation…") : L("На паузе", "Paused"))
                    .font(.system(size: 12.5)).foregroundStyle(Color.pInk3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let m = mine {
                TrackRow(mine: true, text: m.isFinal ? m.text : m.text + "…", active: meterActive)
            }
            if let t = them {
                TrackRow(mine: false, text: t.isFinal ? t.text : t.text + "…", active: meterActive)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // §2 footer: «Подвести итог» (solid accent — stop + open summary), «Заметки», ⌘M hint.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(L("Подвести итог", "Summarize"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Color.pAccent).clipShape(RoundedRectangle(cornerRadius: PRadius.control))
                .contentShape(Rectangle())
                .onTapGesture { if store.isRecording { store.stop() }; store.regenerateNotes(); openMain() }
            Text(L("Заметки", "Notes")).font(.system(size: 12)).foregroundStyle(Color.pInk2)
                .contentShape(Rectangle()).onTapGesture { openMain() }
            Spacer(minLength: 0)
            Text(Hotkeys.mark).font(PFont.mono).foregroundStyle(Color.pInk3)
        }
        .padding(.horizontal, 13).frame(height: 44)
    }

    // §4: idle expanded — one Start button + the always-on privacy line. No recents, no menu.
    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(L("Начать запись", "Start recording"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.pAccent.opacity(store.canRecord ? 1 : 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { if store.canRecord { store.start() } }
            HStack(spacing: 9) {
                Circle().fill(Color.pAccent).frame(width: 6, height: 6)
                Text(L("Слышу микрофон и звук встречи. Бот в звонок не заходит", "Captures your mic and the meeting audio. No bot joins the call"))
                    .font(.system(size: 11.5)).foregroundStyle(Color.pInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine2, lineWidth: 1))
        }
        .padding(.horizontal, 13).padding(.vertical, 14)
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.makeKeyAndOrderFront(nil) }
    }
}

/// One dialogue track — the last replica of one side. Mic (Вы): right-aligned, accent bubble, live
/// level bars left of the label. Собеседник: left-aligned, grey bubble, three "speaking" dots.
struct TrackRow: View {
    let mine: Bool
    let text: String
    var active: Bool = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 7) {
                if mine { MicBars(active: active) }
                Text(mine ? L("МИКРОФОН · ВЫ", "MIC · YOU") : L("ДИНАМИК · СОБЕСЕДНИК", "SPEAKER · THEM"))
                    .font(.system(size: 10)).tracking(0.6)
                    .foregroundStyle(mine ? Color.pStatusLocal : Color.pInk3)
                if !mine { SpeakingDots(active: active) }
            }
            Text(text)
                .font(.system(size: 12.5)).lineSpacing(2)
                .foregroundStyle(mine ? Color.pMicBubbleText : Color.pInk1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(mine ? Color.pAccent.opacity(0.16) : Color.pSelection)
                .clipShape(shape)
                .overlay(shape.strokeBorder(mine ? Color.pAccent.opacity(0.28) : Color.clear, lineWidth: 1))
                .frame(maxWidth: 376 * (mine ? 0.76 : 0.82), alignment: mine ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var shape: UnevenRoundedRectangle {
        mine ? UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10)
             : UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 3)
    }
}

/// Four thin accent bars for the mic track — periods 560–700 ms, each its own phase (spec §3).
/// Fixed height + scaleY (a transform, not layout) so it never churns the panel's constraints.
struct MicBars: View {
    var active: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    private let periods: [Double] = [0.62, 0.70, 0.56, 0.66]
    private let lo: [CGFloat] = [0.35, 0.30, 0.42, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color.pAccent)
                    .frame(width: 2.5, height: 18)
                    .scaleEffect(x: 1, y: phase ? lo[i] : 1, anchor: .center)
                    .animation(active && !reduceMotion ? .easeInOut(duration: periods[i]).repeatForever(autoreverses: true) : .default, value: phase)
            }
        }
        .frame(width: 17, height: 18)
        .opacity(active ? 1 : 0.4)
        .onAppear { phase = true }
    }
}

/// Three pulsing dots after the Собеседник label while they're talking (spec §3).
struct SpeakingDots: View {
    var active: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.pInk3).frame(width: 3, height: 3)
                    .opacity(on ? 1 : 0.25)
                    .animation(active && !reduceMotion ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(Double(i) * 0.2) : .default, value: on)
            }
        }
        .opacity(active ? 1 : 0)
        .onAppear { on = true }
    }
}

// MARK: - Shared header + error + panel chrome

struct WidgetHeader: View {
    @ObservedObject var store: TranscriptStore
    var onCollapse: (() -> Void)?
    var body: some View {
        HStack(spacing: 9) {
            if store.isRecording && !store.isPaused {
                RecordingDot(size: 7)
                Text(L("Запись", "Recording")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pInk1)
                if let s = store.recordingStartedAt {
                    ElapsedText(since: s, color: .pInk2, font: .system(size: 12, design: .monospaced))
                }
                Spacer(minLength: 8)
                // «локально» — reassures the recording never leaves the Mac (spec §2 header).
                Text(L("локально", "on-device")).font(.system(size: 11.5)).foregroundStyle(Color.pStatusLocal)
            } else if store.isPaused {
                Circle().fill(Color.pControlBorder).frame(width: 7, height: 7)
                Text(L("Пауза", "Paused")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pInk1)
                if let s = store.recordingStartedAt {
                    ElapsedText(since: s, color: .pInk3, font: .system(size: 12, design: .monospaced))
                }
                Spacer(minLength: 8)
            } else {
                Circle().fill(isErrorStage ? Color.pDanger : Color.pAccent).frame(width: 7, height: 7)
                Text(idleStatus).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1)
                Spacer(minLength: 8)
                if store.stage == .ready { Text(Hotkeys.record).font(PFont.mono).foregroundStyle(Color.pInk3) }
            }
            if let onCollapse {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.pInk3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCollapse)
            }
        }
    }

    private var isErrorStage: Bool { if case .error = store.stage { return true }; return false }

    private var idleStatus: String {
        switch store.stage {
        case .ready, .listening: return L("Готово к записи", "Ready to record")
        case .preparing: return L("Готовлю модель…", "Preparing model…")
        case .downloading(let f): return L("Скачиваю \(Int(f * 100))%", "Downloading \(Int(f * 100))%")
        case .needsModel: return L("Модель не загружена", "Model not loaded")
        case .error: return L("Ошибка", "Error")
        }
    }
}

struct WidgetError: View {
    @ObservedObject var store: TranscriptStore
    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            HStack(spacing: PSpace.xs) {
                Circle().fill(Color.pDanger).frame(width: 8, height: 8)
                Text(L("Микрофон недоступен", "Microphone unavailable")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
            }
            Text(L("Запись на паузе. Аудио буферизуется локально, пока устройство не вернётся.", "Recording paused. Audio is buffered on-device until the device is back."))
                .font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PSpace.s) {
                Button(L("Повторить", "Retry")) { store.stop(); store.start() }.buttonStyle(PBorderedButtonStyle())
                Button(L("Настройки звука", "Sound settings")) { NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.plain)
                    .font(PFont.secondary).foregroundStyle(Color.pInk2)
            }
        }
        .padding(PSpace.m).frame(width: 300).widgetPanel()
    }
}

private struct WidgetPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Spec §3: bg #101817, border #253130, radius 14, shadow 0 18 40 rgba(12,12,12,0.28).
            .background(Color.pWidgetBG)
            .clipShape(RoundedRectangle(cornerRadius: PRadius.widget, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PRadius.widget, style: .continuous).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 12)
            .padding(20)   // clears the shadow so it never clips into a hard rectangle
    }
}
extension View { func widgetPanel() -> some View { modifier(WidgetPanelChrome()) } }

// MARK: - Dictation HUD (spectrogram pill while dictating · no-field card on finish)

/// Host panel is a fixed frame with NO `.preferredContentSize` (that path crashes NSISEngine on
/// rapid content updates). The controller sizes the panel per mode from the statics below.
struct DictationHUDView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var loc = L11n.shared
    // Sizes include a margin ≥ the card/pill shadow radius so the shadow is never clipped into a
    // hard-edged rectangle (that clip is the "frame" artifact behind the card).
    static let pillSize = CGSize(width: 420, height: 100)
    static let processingSize = CGSize(width: 320, height: 100)
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
                if store.dictationCardIsCommand {
                    CommandRunCard(store: store, label: text)
                } else if store.dictationCardIsTask {
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

/// After a spoken command matched a registered action: a brief «выполняю» toast, or — for a command
/// the user flagged as needing confirmation — a tap-to-run card.
struct CommandRunCard: View {
    @ObservedObject var store: TranscriptStore
    let label: String

    var body: some View {
        if let cmd = store.pendingCommand { confirm(cmd) } else { toast }
    }

    private var toast: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(Color.pAccent)
            Text(L("Выполняю", "Running")).font(PFont.secondary).foregroundStyle(Color.pInk2)
            Text(label).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(Color.pCard).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
    }

    private func confirm(_ cmd: CommandItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").font(.system(size: 15)).foregroundStyle(Color.pAccent)
                Text(L("Выполнить команду?", "Run command?")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
            }
            Text(cmd.phrase.isEmpty ? cmd.value : cmd.phrase).font(PFont.body).foregroundStyle(Color.pInk1).lineLimit(2)
            Text("\(cmd.kind.title) · \(cmd.value)").font(.system(size: 11.5)).foregroundStyle(Color.pInk3).lineLimit(1)
            HStack(spacing: 10) {
                Spacer()
                Text(L("Отмена", "Cancel")).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk2)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                    .contentShape(Rectangle()).onTapGesture { store.dismissDictationCard() }
                Text(L("Выполнить", "Run")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Color.pAccent).clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle()).onTapGesture { store.confirmPendingCommand() }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 360, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
    }
}

/// Fixed dark-capsule palette for the dictation pill (mockup «ZVON Pills» — always dark, theme-agnostic).
private enum PillC {
    static let bg        = Color(red: 14/255,  green: 22/255,  blue: 21/255).opacity(0.95)
    static let text      = Color(red: 242/255, green: 245/255, blue: 244/255)   // #F2F5F4
    static let muted     = Color(red: 139/255, green: 154/255, blue: 151/255)   // #8B9A97
    static let divider   = Color(red: 43/255,  green: 55/255,  blue: 54/255)    // #2B3736
    static let teal      = Color(red: 0,       green: 196/255, blue: 196/255)   // #00C4C4
    static let tealBright = Color(red: 79/255, green: 224/255, blue: 224/255)   // #4FE0E0
    static let idleBar   = Color(red: 91/255,  green: 104/255, blue: 102/255)   // #5B6866
}

/// After the key is released: the LLM polishes the text. Dark capsule + a light sweep (mockup §1).
struct ProcessingPill: View {
    @State private var sweep = false
    var body: some View {
        HStack(spacing: 11) {
            if let g = Brand.pillGlyph { Image(nsImage: g).resizable().scaledToFit().frame(width: 20, height: 14) }
            Text(L("Причёсываю текст…", "Polishing text…")).font(.system(size: 12)).foregroundStyle(PillC.tealBright).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PillC.bg)
        .overlay(
            GeometryReader { geo in
                LinearGradient(colors: [.clear, PillC.teal.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.38)
                    .offset(x: sweep ? geo.size.width * 1.25 : -geo.size.width * 0.5)   // transform-only
            }
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 10)
        .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { sweep = true } }
    }
}

/// The dictating capsule (mockup §1): white wave glyph · 7 live level bars · «Отпустите, чтобы
/// вставить» + the trigger-key hint. When the input is silent it reads «Слушаю…» with grey bars.
struct SpectrogramPill: View {
    @ObservedObject var store: TranscriptStore
    private var speaking: Bool { (store.levels.suffix(6).max() ?? 0) > 0.05 }
    var body: some View {
        HStack(spacing: 13) {
            if let g = Brand.pillGlyph { Image(nsImage: g).resizable().scaledToFit().frame(width: 24, height: 16) }
            PillLevelBars(levels: store.levels, speaking: speaking)
            if speaking {
                Text(L("Отпустите, чтобы вставить", "Release to insert")).font(.system(size: 12.5)).foregroundStyle(PillC.text).fixedSize()
                Text(store.dictationTrigger.shortHint)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(PillC.muted).fixedSize()
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) { Rectangle().fill(PillC.divider).frame(width: 1, height: 15) }
            } else {
                Text(L("Слушаю…", "Listening…")).font(.system(size: 12)).foregroundStyle(PillC.muted).fixedSize()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(PillC.bg).clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.30), radius: 17, x: 0, y: 14)
    }
}

/// 7 bars, 3px, height ≤20, driven by the live mic level via scaleY (a transform, never layout —
/// so it's safe inside the fixed-size HUD panel). Teal while speaking, grey at rest.
struct PillLevelBars: View {
    let levels: [Float]
    let speaking: Bool
    private let count = 7
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(speaking ? PillC.teal : PillC.idleBar)
                    .frame(width: 3, height: 20)
                    .scaleEffect(x: 1, y: scale(i), anchor: .center)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
    private func scale(_ i: Int) -> CGFloat {
        let base: CGFloat = speaking ? 0.25 : 0.2   // 0.2×20 = 4px rest (mockup idle height)
        let w = Array(levels.suffix(count))
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
                Text(L("Сначала выберите поле, затем диктуйте", "Select a field first, then dictate")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                Spacer()
                Button { store.dismissDictationCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Color.pInk2)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel(L("Закрыть", "Close"))
            }
            Text(text).font(PFont.body).lineSpacing(3).foregroundStyle(Color.pInk1)
                .lineLimit(4).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(L("Скопировано · закроется через 8с", "Copied · closes in 8s")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                Spacer()
                HStack(spacing: 7) { Text("⧉").foregroundStyle(Color.pAccent); Text(L("Скопировать", "Copy")) }
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
                Text(L("Задача создана", "Task created")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                Button { store.dismissDictationCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Color.pInk2)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel(L("Закрыть", "Close"))
            }
            Text(text).font(PFont.body).lineSpacing(3).foregroundStyle(Color.pInk1)
                .lineLimit(3).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(L("Уточняется через ИИ…", "Refining with AI…")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                Spacer()
                Text(L("Открыть задачи", "Open tasks"))
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
    @ObservedObject private var loc = L11n.shared
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
                    Text(L("Недавние", "Recent")).font(PFont.label).tracking(0.5).foregroundStyle(Color.pInk3).padding(.vertical, 4)
                    ForEach(recent) { s in
                        menuRow { store.pendingOpenSession = s.id; openMain(); closePopover() } content: {
                            Text(s.title).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                            Spacer(minLength: PSpace.s)
                            Text(Self.relativeShort(s.date)).font(PFont.mono).foregroundStyle(Color.pInk3)
                        }
                    }
                    Hairline(color: .pLine2).padding(.vertical, 4)
                }
                popRow(L("Открыть ZVON", "Open ZVON"), Hotkeys.openNotes) { openMain(); closePopover() }
                popRow(store.widgetHidden ? L("Показать виджет", "Show widget") : L("Скрыть виджет", "Hide widget"), "") {
                    if store.widgetHidden { FloatingWidgetController.shared?.reveal() } else { store.widgetHidden = true }
                    closePopover()
                }
                popRow(L("Настройки", "Settings"), Hotkeys.settings) { openMain(); store.pendingOpenSettings = true; closePopover() }
                popRow(L("Выйти", "Quit"), "⌘Q") { NSApplication.shared.terminate(nil) }
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
                Text(L("Запись", "Recording")).font(PFont.secondaryStrong)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk2) }
            } else if store.isPaused {
                Circle().fill(Color.pControlBorder).frame(width: 8, height: 8)
                Text(L("Пауза", "Paused")).font(PFont.secondaryStrong)
                Spacer()
                if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk3) }
            } else {
                Circle().fill(Color.pControlBorder).frame(width: 8, height: 8)
                Text(L("Готов к записи", "Ready to record")).font(PFont.secondaryStrong)
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
                    Text(L("Остановить запись", "Stop recording"))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            }.buttonStyle(.plain)
        } else {
            Button { if store.canRecord { store.start(); closePopover() } } label: {
                HStack(spacing: PSpace.xs) {
                    Circle().fill(Color.pOnAccent).frame(width: 8, height: 8)
                    Text(L("Начать запись", "Start recording"))
                }
                .font(PFont.secondaryStrong).foregroundStyle(Color.pOnAccent)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.pAccent).clipShape(RoundedRectangle(cornerRadius: 9))
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
        if cal.isDateInYesterday(date) { return L("вчера", "yesterday") }
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
    @ObservedObject private var loc = L11n.shared
    @ObservedObject private var tasks = TaskStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    var closePopover: () -> Void

    var body: some View {
        let open = tasks.open
        VStack(alignment: .leading, spacing: PSpace.s) {
            HStack {
                Text(L("Открытые задачи", "Open tasks")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Spacer()
                if !open.isEmpty {
                    Text("\(open.count)").font(PFont.label).foregroundStyle(Color.pInk2)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Color.pSelection).clipShape(Capsule())
                }
            }
            Hairline(color: .pLine2)
            if open.isEmpty {
                Text(L("Нет открытых задач", "No open tasks")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(open.prefix(8)) { taskRow($0) }
                }
                if open.count > 8 {
                    Text(L("ещё \(open.count - 8)", "\(open.count - 8) more")).font(.system(size: 11)).foregroundStyle(Color.pInk3).padding(.leading, 2)
                }
            }
            Hairline(color: .pLine2)
            PopRowButton(action: openAll) {
                HStack(spacing: 0) {
                    Text(L("Открыть все задачи", "Open all tasks")).font(PFont.secondary).foregroundStyle(Color.pInk1).fixedSize()
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
