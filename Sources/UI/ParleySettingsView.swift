import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkeys, stt, llm, integrations, audio, priv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("Общие", "General")
        case .hotkeys: return L("Горячие клавиши", "Shortcuts")
        case .stt:     return L("Речь", "Speech")
        case .llm:     return L("AI-модель", "AI model")
        case .integrations: return L("Интеграции", "Integrations")
        case .audio:   return L("Аудио", "Audio")
        case .priv:    return L("Приватность", "Privacy")
        }
    }
}

struct ParleySettingsView: View {
    @EnvironmentObject var store: TranscriptStore
    @EnvironmentObject var models: ModelManager
    @ObservedObject private var loc = L11n.shared
    @ObservedObject private var taskStore = TaskStore.shared
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
                }.buttonStyle(.plain).accessibilityLabel(L("Назад", "Back"))
                Text(L("Настройки", "Settings")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.pInk1)
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
        case .integrations: integrationsTab
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
            head(L("Общие", "General"), L("Запуск, строка меню и внешний вид.", "Startup, menu bar, and appearance."))
            group {
                PRow(L("Запускать при входе", "Launch at login")) {
                    ParleyToggle(on: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                }
                PDivider()
                PRow(L("Показывать в строке меню", "Show in menu bar")) { ParleyToggle(on: $store.showMenuBar) }
                PDivider()
                PRow(L("Плавающий виджет", "Floating widget")) {
                    ParleyToggle(on: Binding(get: { !store.widgetHidden }, set: { store.widgetHidden = !$0 }))
                }
                PDivider()
                PRow(L("Тема", "Theme")) { PSegmented(selection: $store.themePref, options: ThemePref.allCases.map { ($0, $0.title) }) }
                PDivider()
                PRow(L("Язык интерфейса", "Interface language")) {
                    PSegmented(selection: $loc.lang, options: AppLang.allCases.map { ($0, $0.title) })
                }
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
            head(L("Горячие клавиши", "Shortcuts"), L("Нажми на сочетание, чтобы изменить его.", "Click a shortcut to change it."))
            group(L("Диктовка", "Dictation"),
                  footnote: L("Быстрый тап той же клавиши или клавиша+буква (⌘C) диктовку не запускают.", "A quick tap of the same key, or key+letter (⌘C), won't start dictation.")) {
                PRow(L("Как активировать", "How to activate"), sub: L("Удерживать — говоришь и отпускаешь; переключать — клик вкл/выкл", "Hold — speak and release; toggle — click on/off")) {
                    PSegmented(selection: $store.dictationMode, options: DictationMode.allCases.map { ($0, $0.title) })
                }
                PDivider()
                PRow(L("Клавиша-триггер", "Trigger key"), sub: L("Одна клавиша (⌘, Fn, ⌥…) — выбери здесь. Рекордер ниже — только для сочетаний.", "A single key (⌘, Fn, ⌥…) — pick it here. The recorder below is for combos only.")) {
                    Picker("", selection: $store.dictationTrigger) {
                        ForEach(DictationTrigger.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if store.dictationTrigger == .combo {
                    PDivider()
                    PRow(L("Сочетание (модификатор + клавиша)", "Shortcut (modifier + key)")) { KeyboardShortcuts.Recorder(for: .dictation) }
                }
                PDivider()
                PRow(L("Универсальный доступ", "Accessibility"), sub: L("Для авто-вставки и одиночной клавиши-триггера", "For auto-paste and a single trigger key")) {
                    if axTrusted {
                        Label(L("Разрешён", "Allowed"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
                    } else {
                        Button(L("Разрешить", "Allow")) {
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
            group(L("Остальные", "Other")) {
                PRow(L("Начать / остановить запись", "Start / stop recording")) { KeyboardShortcuts.Recorder(for: .toggleRecording) }
                PDivider()
                PRow(L("Подвести итог", "Summarize")) { KeyboardShortcuts.Recorder(for: .summarize) }
                PDivider()
                PRow(L("Открыть заметки", "Open notes")) { keycap("⌘↩") }
                PDivider()
                PRow(L("Поиск и вопросы", "Search & ask")) { keycap("⌘K") }
                PDivider()
                PRow(L("Свернуть панель", "Collapse panel")) { keycap("Esc") }
                PDivider()
                PRow(L("Пауза / продолжить", "Pause / resume")) { keycap("Space") }
            }
        }
    }

    // MARK: Речь

    private var sttTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head(L("Речь", "Speech"), L("Распознавание речи — на устройстве.", "Speech recognition — on device."))
            group(footnote: L("Parakeet TDT v3 (NVIDIA, через FluidAudio) — точный русский на устройстве, ~реалтайм на Apple Silicon (Neural Engine). Модель подгружается автоматически; аудио не покидает Mac.", "Parakeet TDT v3 (NVIDIA, via FluidAudio) — accurate on-device Russian, near real-time on Apple Silicon (Neural Engine). The model downloads automatically; audio never leaves your Mac.")) {
                PRow(L("Движок", "Engine")) { Text("Parakeet TDT v3").font(PFont.secondary).foregroundStyle(Color.pInk1) }
                PDivider()
                PRow(L("Язык распознавания", "Recognition language")) {
                    Picker("", selection: $store.language) {
                        Text(L("Авто", "Auto")).tag("auto"); Text(L("Русский", "Russian")).tag("ru"); Text("English").tag("en")
                    }.labelsHidden().fixedSize()
                }
                PDivider()
                PRow(L("Статус", "Status")) {
                    Label(L("Локально · на устройстве", "Local · on device"), systemImage: "checkmark.circle.fill")
                        .font(PFont.secondary).foregroundStyle(Color.pSuccess)
                }
            }
            group(L("Улучшение через ИИ", "AI enhancement"),
                  footnote: L("Неуверенно распознанные фразы отправляются в AI-модель, которая правит только явные ошибки распознавания (имена, термины, похожие по звучанию слова), не меняя смысл. Работает только с подключённой AI-моделью; распознавание остаётся локальным.", "Low-confidence phrases are sent to the AI model, which fixes only clear recognition errors (names, terms, similar-sounding words) without changing the meaning. Works only with a connected AI model; recognition stays local.")) {
                PRow(L("Исправлять ошибки распознавания", "Fix recognition errors"), sub: L("Только неуверенные фразы — точечно, через выбранную AI-модель", "Low-confidence phrases only — targeted, via the selected AI model")) {
                    ParleyToggle(on: $store.aiTranscriptRepairEnabled)
                }
            }
            group(L("Обработка диктовки", "Dictation processing"),
                  footnote: L("Только для диктовки (удержание/переключение) — не для записи встреч. Убирает слова-паразиты и оговорки, чинит пунктуацию через ИИ. Если модель недоступна — текст вставится как есть.", "For dictation only (hold/toggle) — not for meeting recordings. Removes filler words and slips, fixes punctuation via AI. If the model is unavailable, text is inserted as-is.")) {
                PRow(L("Чистить через ИИ", "Clean up with AI"), sub: L("Нужна настроенная AI-модель", "Requires a configured AI model")) {
                    ParleyToggle(on: $store.aiDictationEnabled)
                }
                if store.aiDictationEnabled {
                    PDivider()
                    PRow(L("Стиль", "Style")) {
                        PSegmented(selection: $store.aiDictationStyle, options: DictationStyle.allCases.map { ($0, $0.title) })
                    }
                }
            }
        }
    }

    // MARK: AI-модель

    @State private var apiKey = ""
    @State private var modelText = ""
    @State private var tgToken = ""
    @State private var tgChat = ""
    @State private var tgTest = ""   // "" idle · "…" testing · "ok" · error text
    @State private var calAuth = false

    private var llmTab: some View {
        let p = store.llmProvider
        return VStack(alignment: .leading, spacing: PSpace.l) {
            head(L("AI-модель", "AI model"), L("Подключи облачный ключ (OpenAI / Anthropic) или свою модель.", "Connect a cloud key (OpenAI / Anthropic) or your own model."))
            group(L("Провайдер", "Provider")) {
                ForEach(LLMProvider.allCases) { prov in
                    providerRow(prov)
                    if prov != LLMProvider.allCases.last { PDivider() }
                }
            }

            group(L("Подключение", "Connection"), footnote: p.needsKey
                  ? L("Ключ хранится в Keychain (не в файлах). У каждого провайдера — свой ключ.", "The key is stored in the Keychain (not in files). Each provider has its own key.")
                  : L("Локальная модель: ключ не нужен, всё на устройстве.", "Local model: no key needed, everything on device.")) {
                PRow(L("Модель", "Model")) {
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
                    PRow(L("API-ключ", "API key")) { keyField }
                }
                PDivider()
                PRow(L("Связь", "Connectivity")) {
                    HStack(spacing: 10) {
                        connectionStatusInline
                        Button(store.llmTest == "…" ? L("Проверяю…", "Testing…") : L("Проверить", "Test")) { store.testLLM() }
                            .buttonStyle(PBorderedButtonStyle()).disabled(store.llmTest == "…")
                    }
                }
            }
            .onAppear { reloadProviderFields() }
            .onChange(of: store.llmProvider) { _, _ in reloadProviderFields() }

            group(L("Задачи", "Tasks"), footnote: L("Извлечение задач срабатывает на голосовые команды («создай задачу…», «напомни…») — не на всю расшифровку.", "Task extraction triggers on voice commands (“create a task…”, “remind me…”) — not on the whole transcript.")) {
                PRow(L("Саммари и Итог", "Summaries & recap")) { ParleyToggle(on: $store.summariesEnabled) }
                PDivider()
                PRow(L("Извлечение задач", "Task extraction")) { ParleyToggle(on: $store.taskExtractionEnabled) }
                PDivider()
                PRow(L("Напоминания о задачах", "Task reminders"), sub: L("Настраиваются в разделе «Задачи»", "Configured in the Tasks section")) {
                    ParleyToggle(on: $taskStore.reminderEnabled)
                }
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
        case "ok": Label(L("Подключено", "Connected"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
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

    // MARK: Интеграции

    private var integrationsTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head(L("Интеграции", "Integrations"),
                 L("Доставка тезисов и протоколов наружу. Уходит только текст, каждый канал — по вашему действию.",
                   "Deliver theses and minutes. Only text goes out, per your action."))
            group(L("Telegram", "Telegram"),
                  footnote: L("Создайте бота у @BotFather, вставьте токен. Chat ID — узнать у @userinfobot (личный) или использовать ID канала, где бот — админ. Токен хранится в Keychain. Сообщения бота проходят через облако Telegram (не E2E).",
                              "Create a bot with @BotFather and paste the token. Get the chat ID from @userinfobot (personal), or a channel ID where the bot is an admin. The token is stored in the Keychain. Bot messages go through Telegram's cloud (not E2E).")) {
                PRow(L("Токен бота", "Bot token")) {
                    SecureField("123456:ABC-DEF…", text: $tgToken)
                        .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
                        .frame(width: 320, height: 32).padding(.horizontal, 10)
                        .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: PRadius.control))
                        .overlay(RoundedRectangle(cornerRadius: PRadius.control).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                        .onChange(of: tgToken) { _, v in Telegram.setToken(v); tgTest = "" }
                }
                PDivider()
                PRow(L("Chat ID", "Chat ID")) {
                    HStack(spacing: 10) {
                        fieldInput($tgChat, "-1001234567890")
                            .onChange(of: tgChat) { _, v in Telegram.setChatId(v); tgTest = "" }
                    }
                }
                PDivider()
                PRow(L("Проверка", "Test")) {
                    HStack(spacing: 10) {
                        Button(L("Отправить тест", "Send test")) { runTelegramTest() }
                            .buttonStyle(PBorderedButtonStyle()).disabled(!Telegram.isConfigured || tgTest == "…")
                        telegramTestStatus
                    }
                }
            }
            group(L("Календарь", "Calendar"),
                  footnote: L("Добавьте Яндекс-календарь в macOS (Системные настройки → Интернет-аккаунты → CalDAV: caldav.yandex.ru, пароль приложения). ZVON возьмёт название встречи и участников — читается локально, ничего не отправляется.",
                              "Add your Yandex calendar to macOS (System Settings → Internet Accounts → CalDAV: caldav.yandex.ru, app-password). ZVON reads the meeting title and attendees — locally, nothing is sent.")) {
                PRow(L("Называть запись по встрече из календаря", "Name recordings from the calendar")) {
                    ParleyToggle(on: $store.calendarEnabled)
                }
                PDivider()
                PRow(L("Напоминать о начале встречи", "Nudge when a meeting starts"),
                     sub: L("Карточка поверх других окон с кнопкой «Начать запись»",
                            "A floating card with a Start recording button")) {
                    ParleyToggle(on: $store.meetingPromptEnabled)
                }
                if store.meetingPromptEnabled {
                    PDivider()
                    PRow(L("Звук напоминания о встрече", "Meeting nudge sound")) {
                        ParleyToggle(on: $store.meetingPromptSound)
                    }
                }
                PDivider()
                PRow(L("Доступ к календарю", "Calendar access")) {
                    if calAuth {
                        Label(L("Разрешён", "Granted"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
                    } else {
                        Button(L("Разрешить", "Grant")) { requestCalendar() }.buttonStyle(PBorderedButtonStyle())
                    }
                }
            }
        }
        .onAppear { tgToken = Telegram.token; tgChat = Telegram.chatId; calAuth = CalendarService.shared.authorized }
    }

    private func requestCalendar() {
        Task { let ok = await CalendarService.shared.requestAccess(); await MainActor.run { calAuth = ok } }
    }

    @ViewBuilder private var telegramTestStatus: some View {
        switch tgTest {
        case "": EmptyView()
        case "…": PSpinner(size: 14)
        case "ok": Label(L("Отправлено", "Sent"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pSuccess)
        default: Text(tgTest).font(.system(size: 11)).foregroundStyle(Color.pDanger).lineLimit(2).frame(maxWidth: 280)
        }
    }

    private func runTelegramTest() {
        tgTest = "…"
        Task {
            do { try await Telegram.test(); await MainActor.run { tgTest = "ok" } }
            catch { await MainActor.run { tgTest = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription } }
        }
    }

    // MARK: Аудио

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head(L("Аудио", "Audio"), L("Что писать — микрофон или ещё и динамик.", "What to capture — mic only, or the speaker too."))
            group(footnote: store.captureMode == .micAndSystem
                  ? L("Звук динамика — системные аудио-краны (macOS 14.2+). При первом запуске система попросит «Запись звука системы».", "Speaker audio uses system audio taps (macOS 14.2+). On first launch, the system will ask for “System Audio Recording”.")
                  : store.captureMode.note) {
                PRow(L("Источник", "Source")) {
                    PSegmented(selection: $store.captureMode, options: CaptureMode.allCases.map { ($0, $0.title) })
                }
            }
        }
    }

    // MARK: Приватность

    private var privTab: some View {
        VStack(alignment: .leading, spacing: PSpace.l) {
            head(L("Приватность", "Privacy"), L("Обработка на устройстве по умолчанию.", "On-device processing by default."))
            group(footnote: L("Распознавание идёт локально — аудио не покидает Mac. Итог и вопросы уходят только на выбранный AI-эндпоинт.", "Recognition runs locally — audio never leaves your Mac. Summaries and questions go only to the selected AI endpoint.")) {
                PRow(L("Распознавание речи", "Speech recognition")) { Text(L("На устройстве", "On device")).font(PFont.secondary).foregroundStyle(Color.pInk2) }
                PDivider()
                PRow(L("AI-заметки", "AI notes")) { Text(L("Только на ваш эндпоинт", "Only to your endpoint")).font(PFont.secondary).foregroundStyle(Color.pInk2) }
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
