import SwiftUI
import AppKit

/// First-run walkthrough: what Parley is + the OS permissions it needs (mic, Accessibility, system
/// audio). Shown as an overlay over the main window until finished/skipped. Local-first framing.
struct OnboardingView: View {
    @EnvironmentObject var store: TranscriptStore
    @ObservedObject private var perms = PermissionsManager.shared
    @ObservedObject private var loc = L11n.shared
    @State private var step = 0
    private let last = 4

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            card
        }
        .onAppear { perms.refresh() }
        // Re-check after the user grants something in System Settings and returns to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 24)
            footer
        }
        .frame(width: 480)
        .background(Color.pCard)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.pWidgetBorder, lineWidth: 1))
        .shadow(color: .pShadow3, radius: 40, x: 0, y: 22)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: permStep(icon: "mic.fill", title: L("Микрофон", "Microphone"),
                         desc: L("Нужен, чтобы записывать вашу речь на встрече и работать диктовке.", "Needed to record your voice in meetings and to power dictation."),
                         state: perms.mic, action: { Task { await perms.requestMic() } },
                         openPane: .microphone)
        case 2: permStep(icon: "accessibility", title: L("Универсальный доступ", "Accessibility"),
                         desc: L("Чтобы вставлять диктовку в активное поле и запускать её одной клавишей (push-to-talk).", "To insert dictation into the active field and trigger it with a single key (push-to-talk)."),
                         state: perms.accessibility, action: { perms.requestAccessibility() },
                         openPane: .accessibility)
        case 3: infoStep(icon: "speaker.wave.2.fill", title: L("Звук собеседника", "Other party's audio"),
                         desc: L("Чтобы записывать вторую сторону звонка (Zoom, Meet, телефон). Разрешение запросится автоматически при первой записи звонка — включать заранее не обязательно.", "To capture the other side of a call (Zoom, Meet, phone). Permission is requested automatically the first time you record a call — no need to enable it in advance."))
        default: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            ParleyMark(heights: [16, 26, 20], color: .pAccent)
                .frame(width: 60, height: 60)
                .background(Color.pAccent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(L("Добро пожаловать в Parley", "Welcome to Parley")).font(PFont.heading).foregroundStyle(Color.pInk1)
                .multilineTextAlignment(.center)
            Text(L("Локальный ассистент встреч и диктовки. Распознавание и обработка — на вашем Mac, без облака.", "A local assistant for meetings and dictation. Recognition and processing run on your Mac, no cloud."))
                .font(PFont.secondary).foregroundStyle(Color.pInk2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                featureLine("waveform", L("Запись встреч с расшифровкой и итогом", "Record meetings with transcript and summary"))
                featureLine("text.bubble", L("Диктовка в любое поле с AI-чисткой", "Dictate into any field with AI cleanup"))
                featureLine("lock.fill", L("Приватность: данные и ключи не покидают устройство", "Privacy: your data and keys never leave the device"))
            }
            .padding(.top, 4)
        }
    }

    private func featureLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.pAccent).frame(width: 18)
            Text(text).font(PFont.secondary).foregroundStyle(Color.pInk1)
            Spacer(minLength: 0)
        }
    }

    private func permStep(icon: String, title: String, desc: String, state: PermState,
                          action: @escaping () -> Void, openPane: PermissionsManager.Pane) -> some View {
        VStack(spacing: 16) {
            stepIcon(icon)
            Text(title).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(desc).font(PFont.secondary).foregroundStyle(Color.pInk2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            statusPill(state)
            if state == .granted {
                EmptyView()
            } else if state == .denied {
                Button(L("Открыть системные настройки", "Open System Settings")) { perms.openSettings(openPane) }
                    .buttonStyle(PPrimaryButtonStyle())
            } else {
                Button(L("Разрешить", "Allow")) { action() }.buttonStyle(PPrimaryButtonStyle())
            }
        }
    }

    private func infoStep(icon: String, title: String, desc: String) -> some View {
        VStack(spacing: 16) {
            stepIcon(icon)
            Text(title).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(desc).font(PFont.secondary).foregroundStyle(Color.pInk2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(L("Открыть настройки приватности", "Open Privacy Settings")) { perms.openSettings(.microphone) }
                .buttonStyle(PBorderedButtonStyle())
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Color.pAccent)
            Text(L("Готово", "Done")).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(L("Можно записывать встречу или диктовать. Разрешения и провайдера ИИ всегда можно изменить в настройках (⌘,).", "You're ready to record a meeting or dictate. Permissions and the AI provider can always be changed in Settings (⌘,)."))
                .font(PFont.secondary).foregroundStyle(Color.pInk2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepIcon(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Color.pAccent)
            .frame(width: 60, height: 60)
            .background(Color.pAccent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusPill(_ s: PermState) -> some View {
        let (text, color): (String, Color) = {
            switch s {
            case .granted: return (L("Разрешено", "Granted"), .pSuccess)
            case .denied:  return (L("Отклонено — включите в настройках", "Denied — enable it in Settings"), .pDanger)
            default:       return (L("Не запрошено", "Not requested"), .pInk3)
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: s == .granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
            Text(text).font(PFont.label)
        }
        .foregroundStyle(color)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step == 0 {
                Button(L("Пропустить", "Skip")) { finish() }.buttonStyle(.plain)
                    .font(PFont.secondary).foregroundStyle(Color.pInk3)
            } else {
                Button(L("Назад", "Back")) { withAnimation { step -= 1 } }.buttonStyle(.plain)
                    .font(PFont.secondary).foregroundStyle(Color.pInk2)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...last, id: \.self) { i in
                    Circle().fill(i == step ? Color.pAccent : Color.pControlBorder).frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(step == last ? L("Начать работу", "Get started") : L("Далее", "Next")) {
                if step == last { finish() } else { withAnimation { step += 1 } }
            }.buttonStyle(PPrimaryButtonStyle())
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Color.pField)
        .overlay(alignment: .top) { Rectangle().fill(Color.pLine2).frame(height: 1) }
    }

    private func finish() { withAnimation { store.onboardingDone = true } }
}
