import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkeys, stt, llm, audio, priv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Общие"
        case .hotkeys: return "Горячие клавиши"
        case .stt:     return "Речь"
        case .llm:     return "AI-модель"
        case .audio:   return "Аудио"
        case .priv:    return "Приватность"
        }
    }
}

struct ParleySettingsView: View {
    @EnvironmentObject var store: TranscriptStore
    @EnvironmentObject var models: ModelManager
    @State private var tab: SettingsTab = .general
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let onClose { settingsTopBar(onClose) }
            HStack(spacing: 0) {
                sidebar
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading).padding(32)
                }
                .background(Color.pCanvas)
            }
        }
        .frame(minWidth: 820, idealWidth: 880, maxWidth: .infinity, minHeight: 560, idealHeight: 600, maxHeight: .infinity)
        .background(Color.pCanvas)
    }

    private func settingsTopBar(_ onClose: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 44)   // traffic-lights band
            HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left").font(PFont.secondaryStrong).foregroundStyle(Color.pInk2)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.pSelection)).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Назад")
                Text("Настройки").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.pInk1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .background(Color.pChrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.pLine).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.title)
                        .font(PFont.secondary)
                        .foregroundStyle(tab == t ? Color.pOnFill : Color.pInk1)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tab == t ? Color.pAccent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 220)
        .background(Color.pRail)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.pLine).frame(width: 1) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: generalTab
        case .hotkeys: hotkeysTab
        case .stt:     sttTab
        case .llm:     llmTab
        case .audio:   audioTab
        case .priv:    privTab
        }
    }

    private func head(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(desc).font(PFont.secondary).foregroundStyle(Color.pInk2)
        }
    }

    /// A titled card unit: caption hugs its card (8pt), optional footnote below.
    private func group<C: View>(_ caption: String? = nil, footnote: String? = nil,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption { SectionCaption(caption) }
            PCardGroup { content() }
            if let footnote {
                Text(footnote).font(.system(size: 12)).foregroundStyle(Color.pInk3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Общие

    @State private var launchAtLogin = false

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head("Общие", "Запуск, строка меню и внешний вид.")
            group {
                PRow("Запускать при входе") {
                    ParleyToggle(on: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                }
                PDivider()
                PRow("Показывать в строке меню") { ParleyToggle(on: $store.showMenuBar) }
                PDivider()
                PRow("Плавающий виджет") {
                    ParleyToggle(on: Binding(get: { !store.widgetHidden }, set: { store.widgetHidden = !$0 }))
                }
                PDivider()
                PRow("Тема") { PSegmented(selection: $store.themePref, options: ThemePref.allCases.map { ($0, $0.title) }) }
                PDivider()
                PRow("Язык интерфейса") { Text("Русский").font(PFont.secondary).foregroundStyle(Color.pInk2) }
            }
        }
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            DebugLog.log("launchAtLogin \(on) failed: \(error.localizedDescription)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Горячие клавиши

    @State private var axTrusted = false

    private var hotkeysTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head("Горячие клавиши", "Нажми на сочетание, чтобы изменить его.")
            group("Диктовка",
                  footnote: "Быстрый тап той же клавиши или клавиша+буква (⌘C) диктовку не запускают.") {
                PRow("Как активировать", sub: "Удерживать — говоришь и отпускаешь; переключать — клик вкл/выкл") {
                    PSegmented(selection: $store.dictationMode, options: DictationMode.allCases.map { ($0, $0.title) })
                }
                PDivider()
                PRow("Клавиша-триггер", sub: "Одна клавиша (⌘, Fn, ⌥…) — выбери здесь. Рекордер ниже — только для сочетаний.") {
                    Picker("", selection: $store.dictationTrigger) {
                        ForEach(DictationTrigger.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if store.dictationTrigger == .combo {
                    PDivider()
                    PRow("Сочетание (модификатор + клавиша)") { KeyboardShortcuts.Recorder(for: .dictation) }
                }
                PDivider()
                PRow("Универсальный доступ", sub: "Для авто-вставки и одиночной клавиши-триггера") {
                    if axTrusted {
                        Label("Разрешён", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
                    } else {
                        Button("Разрешить") {
                            TextInserter.requestAccessibility()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                            axTrusted = TextInserter.canAutoPaste
                        }.buttonStyle(PBorderedButtonStyle())
                    }
                }
            }
            .onAppear { axTrusted = TextInserter.canAutoPaste }
            group("Остальные") {
                PRow("Начать / остановить запись") { KeyboardShortcuts.Recorder(for: .toggleRecording) }
                PDivider()
                PRow("Подвести итог") { KeyboardShortcuts.Recorder(for: .summarize) }
                PDivider()
                PRow("Открыть заметки") { keycap("⌘↩") }
                PDivider()
                PRow("Поиск и вопросы") { keycap("⌘K") }
                PDivider()
                PRow("Свернуть панель") { keycap("Esc") }
                PDivider()
                PRow("Пауза / продолжить") { keycap("Space") }
            }
        }
    }

    // MARK: Речь

    private var sttTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head("Речь", "Распознавание речи — на устройстве.")
            group(footnote: "Parakeet TDT v3 (NVIDIA, через FluidAudio) — точный русский на устройстве, ~реалтайм на Apple Silicon (Neural Engine). Модель подгружается автоматически; аудио не покидает Mac.") {
                PRow("Движок") { Text("Parakeet TDT v3").font(PFont.secondary).foregroundStyle(Color.pInk1) }
                PDivider()
                PRow("Язык распознавания") {
                    Picker("", selection: $store.language) {
                        Text("Авто").tag("auto"); Text("Русский").tag("ru"); Text("English").tag("en")
                    }.labelsHidden().fixedSize()
                }
                PDivider()
                PRow("Статус") {
                    Label("Локально · на устройстве", systemImage: "checkmark.circle.fill")
                        .font(PFont.secondary).foregroundStyle(Color.pSuccess)
                }
            }
            group("Улучшение через ИИ",
                  footnote: "Неуверенно распознанные фразы отправляются в AI-модель, которая правит только явные ошибки распознавания (имена, термины, похожие по звучанию слова), не меняя смысл. Работает только с подключённой AI-моделью; распознавание остаётся локальным.") {
                PRow("Исправлять ошибки распознавания", sub: "Только неуверенные фразы — точечно, через выбранную AI-модель") {
                    ParleyToggle(on: $store.aiTranscriptRepairEnabled)
                }
            }
            group("Обработка диктовки",
                  footnote: "Только для диктовки (удержание/переключение) — не для записи встреч. Убирает слова-паразиты и оговорки, чинит пунктуацию через ИИ. Если модель недоступна — текст вставится как есть.") {
                PRow("Чистить через ИИ", sub: "Нужна настроенная AI-модель") {
                    ParleyToggle(on: $store.aiDictationEnabled)
                }
                if store.aiDictationEnabled {
                    PDivider()
                    PRow("Стиль") {
                        PSegmented(selection: $store.aiDictationStyle, options: DictationStyle.allCases.map { ($0, $0.title) })
                    }
                }
            }
        }
    }

    // MARK: AI-модель

    @State private var apiKey = ""
    @State private var modelText = ""

    private var llmTab: some View {
        let p = store.llmProvider
        return VStack(alignment: .leading, spacing: PSpace.l) {
            head("AI-модель", "Подключи облачный ключ (OpenAI / Anthropic) или свою модель.")
            group("Провайдер") {
                ForEach(LLMProvider.allCases) { prov in
                    providerRow(prov)
                    if prov != LLMProvider.allCases.last { PDivider() }
                }
            }

            group("Подключение", footnote: p.needsKey
                  ? "Ключ хранится в Keychain (не в файлах). У каждого провайдера — свой ключ."
                  : "Локальная модель: ключ не нужен, всё на устройстве.") {
                PRow("Модель") {
                    fieldInput($modelText, p.defaultModel)
                        .onChange(of: modelText) { _, v in store.setProviderModel(store.llmProvider, v) }
                }
                PDivider()
                if p.editableEndpoint {
                    PRow("Endpoint") { fieldInput($store.llmEndpoint, "http://…/v1") }
                } else {
                    PRow("Endpoint") {
                        Text(p.fixedEndpoint ?? "").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.pInk3).textSelection(.enabled)
                    }
                }
                if p.needsKey {
                    PDivider()
                    PRow("API-ключ") { keyField }
                }
                PDivider()
                PRow("Связь") {
                    HStack(spacing: 10) {
                        connectionStatusInline
                        Button(store.llmTest == "…" ? "Проверяю…" : "Проверить") { store.testLLM() }
                            .buttonStyle(PBorderedButtonStyle()).disabled(store.llmTest == "…")
                    }
                }
            }
            .onAppear { reloadProviderFields() }
            .onChange(of: store.llmProvider) { _, _ in reloadProviderFields() }

            group("Задачи", footnote: "Извлечение задач срабатывает на голосовые команды («создай задачу…», «напомни…») — не на всю расшифровку.") {
                PRow("Саммари и Итог") { ParleyToggle(on: $store.summariesEnabled) }
                PDivider()
                PRow("Извлечение задач") { ParleyToggle(on: $store.taskExtractionEnabled) }
            }
        }
    }

    private func reloadProviderFields() {
        let p = store.llmProvider
        apiKey = p.needsKey ? (Keychain.get(account: p.keyAccount) ?? "") : ""
        modelText = store.rawProviderModel(p)
    }

    private var keyField: some View {
        SecureField(store.llmProvider == .anthropic ? "sk-ant-…" : "sk-…", text: $apiKey)
            .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
            .frame(width: 320, height: 32).padding(.horizontal, 10)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: PRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            .onChange(of: apiKey) { _, v in
                let acc = store.llmProvider.keyAccount
                v.isEmpty ? Keychain.delete(account: acc) : Keychain.set(v, account: acc)
            }
    }

    @ViewBuilder private var connectionStatusInline: some View {
        switch store.llmTest {
        case "": EmptyView()
        case "…": PSpinner(size: 14)
        case "ok": Label("Подключено", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
        default: Text(store.llmTest).font(.system(size: 11)).foregroundStyle(Color.pDanger).lineLimit(2).frame(maxWidth: 300)
        }
    }

    private func providerRow(_ p: LLMProvider) -> some View {
        Button { store.llmProvider = p } label: {
            HStack(spacing: 14) {
                ParleyRadio(selected: store.llmProvider == p)
                Text(p.title).font(PFont.secondary).foregroundStyle(Color.pInk1)
                Spacer()
                Text(p.subtitle).font(.system(size: 11)).foregroundStyle(Color.pInk3)
            }
            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(p.title)
    }

    private func fieldInput(_ text: Binding<String>, _ placeholder: String) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
            .frame(width: 320, height: 32).padding(.horizontal, 10)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: PRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
    }

    // MARK: Аудио

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head("Аудио", "Что писать — микрофон или ещё и динамик.")
            group(footnote: store.captureMode == .micAndSystem
                  ? "Звук динамика — системные аудио-краны (macOS 14.2+). При первом запуске система попросит «Запись звука системы»."
                  : store.captureMode.note) {
                PRow("Источник") {
                    PSegmented(selection: $store.captureMode, options: CaptureMode.allCases.map { ($0, $0.title) })
                }
            }
        }
    }

    // MARK: Приватность

    private var privTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head("Приватность", "Обработка на устройстве по умолчанию.")
            group(footnote: "Распознавание идёт локально — аудио не покидает Mac. Итог и вопросы уходят только на выбранный AI-эндпоинт.") {
                PRow("Распознавание речи") { Text("На устройстве").font(PFont.secondary).foregroundStyle(Color.pInk2) }
                PDivider()
                PRow("AI-заметки") { Text("Только на ваш эндпоинт").font(PFont.secondary).foregroundStyle(Color.pInk2) }
            }
        }
    }

    // MARK: Shared

    private func keycap(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.pInk1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.pButtonBorder, lineWidth: 1))
    }
}

// MARK: - Settings building blocks (dark cards)

private struct PCardGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.pRail)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

private struct PDivider: View {
    var body: some View { Rectangle().fill(Color.pLine2).frame(height: 1) }
}

private struct PRow<Control: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder var control: Control
    init(_ label: String, sub: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label; self.sub = sub; self.control = control()
    }
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(PFont.secondary).foregroundStyle(Color.pInk1)
                if let sub { Text(sub).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
    }
}

private struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(PFont.label).tracking(0.4)
            .foregroundStyle(Color.pInk3)
    }
}

/// Monochrome toggle (ON = ink-1, knob = card color).
struct ParleyToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            RoundedRectangle(cornerRadius: 11)
                .fill(on ? Color.pInk1 : Color.pField)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? Color.clear : Color.pControlBorder, lineWidth: 1))
                .frame(width: 36, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(on ? Color.pCard : Color.pInk3).frame(width: 18, height: 18).padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// Inline segmented pill (selected = control-border fill, ink-1 text). Consistent with the app —
/// avoids the native green `.segmented` control that clashes with the dark theme.
struct PSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { opt in
                Button { selection = opt.0 } label: {
                    Text(opt.1).font(.system(size: 12, weight: selection == opt.0 ? .medium : .regular))
                        .foregroundStyle(selection == opt.0 ? Color.pInk1 : Color.pInk2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == opt.0 ? Color.pButtonBorder : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.1)
            }
        }
        .padding(3).background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
