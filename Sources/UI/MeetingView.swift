import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app shell: sidebar (history) + main pane (transcript · footer · status bar). Single column,
/// no right rail (spec §1). Traffic lights float over the sidebar's top row.
struct MeetingView: View {
    @EnvironmentObject var store: TranscriptStore
    @EnvironmentObject var models: ModelManager
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var taskStore = TaskStore.shared
    @ObservedObject private var glossary = GlossaryStore.shared
    @State private var search = ""
    @State private var selectedId: UUID?
    @State private var mainView: MainView = .meeting
    @State private var showingSettings = false
    @State private var showShare = false
    @State private var shareCopied = false
    @State private var showRecipes = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if showingSettings {
                ParleySettingsView(onClose: { showingSettings = false })
                    .environmentObject(store)
                    .environmentObject(models)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    mainPane
                }
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(Color.pCanvas)
        .background(WindowConfigurator())   // full-size content so the shell reaches the top
        .ignoresSafeArea()                  // content flush under the (hidden) title bar — no dead band
        .onAppear { store.onAppear() }
        // Any record start (button OR ⌘⇧R hotkey) takes over the live pane, even from a past session.
        .onChange(of: store.isRecording) { _, rec in if rec { selectedId = nil; mainView = .meeting } }
        // "Недавние" in the menu-bar popover asks the main window to open a session.
        .onChange(of: store.pendingOpenSession) { _, id in
            if let id { selectedId = id; mainView = .meeting; showingSettings = false; store.pendingOpenSession = nil }
        }
        // ⌘, or menu-bar «Настройки» → switch this window to the settings page (no separate window).
        .onChange(of: store.pendingOpenSettings) { _, want in
            if want { showingSettings = true; store.pendingOpenSettings = false }
        }
        // "Открыть" on the voice task-created card → jump to Задачи.
        .onChange(of: store.pendingOpenTasks) { _, want in
            if want { selectedId = nil; mainView = .tasks; showingSettings = false; store.pendingOpenTasks = false }
        }
        // Tasks-menu row click → Задачи, scrolled to that task (TasksView reads pendingOpenTaskId).
        .onChange(of: store.pendingOpenTaskId) { _, id in
            if id != nil { selectedId = nil; mainView = .tasks; showingSettings = false }
        }
        .sheet(isPresented: $showRecipes) {
            RecipesSheet(store: store, material: { meetingMaterial() }, onClose: { showRecipes = false })
        }
    }

    /// The meeting content fed to a recipe: the structured recap + the transcript.
    private func meetingMaterial() -> String {
        let e = currentExport()
        var m = e.shareText()
        let tr = e.transcript.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        if !tr.isEmpty { m += "\n\nРАСШИФРОВКА:\n" + tr }
        return m
    }

    private var selected: SessionRecord? {
        guard let id = selectedId else { return nil }
        return sessions.sessions.first { $0.id == id }
    }
    private var viewingPast: Bool { selected != nil && !store.isRecording }

    // MARK: - Sidebar (256)

    private var sidebar: some View {
        VStack(spacing: 0) {
            // (1) Traffic-lights band — the window buttons float here; no app content.
            Color.clear.frame(height: 44)
            // (2) Brand — its own row, left-aligned to the same margin as everything below.
            HStack(spacing: 9) {
                brandMark
                Text("Parley").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.pInk1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                Button {
                    if store.canRecord { selectedId = nil; mainView = .meeting; store.start() }
                } label: {
                    HStack(spacing: PSpace.xs) {
                        Circle().fill(Color.pAccent).frame(width: 8, height: 8)
                        Text("Новая запись")
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.parley(0x232120, 0xF4EFEA))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Color.pAccent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pAccent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!store.canRecord)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.pInk3)
                    // During a live meeting → ask about IT; otherwise → ask across the whole archive.
                    TextField(store.isRecording ? "Вопрос по встрече" : "Спросить по всем встречам", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.pInk1)
                        .focused($searchFocused)
                        .onSubmit {
                            let q = search.trimmingCharacters(in: .whitespaces)
                            guard !q.isEmpty else { return }
                            selectedId = nil; mainView = .meeting; showingSettings = false
                            store.isRecording ? store.ask(q) : store.askArchive(q)
                        }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine, lineWidth: 1))
                .focusRing(searchFocused, radius: 8)
                .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)

            navSection

            historyList

            Divider().overlay(Color.pLine)
            Button { showingSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Color.pInk2)
                    Text("Настройки").font(PFont.secondary).foregroundStyle(Color.pInk1)
                    Spacer()
                    Text("⌘,").font(PFont.mono).foregroundStyle(Color.pInk3)
                }
                .padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 256)
        .background(Color.pRail)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.pLine).frame(width: 1) }
    }

    private var brandMark: some View {
        HStack(spacing: 1.5) {
            ForEach([CGFloat(7), 11, 8], id: \.self) { h in
                Capsule().fill(Color.white).frame(width: 2, height: h)
            }
        }
        .frame(width: 24, height: 24).background(Color.pAccent).clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var navSection: some View {
        VStack(spacing: 2) {
            navRow(.all); navRow(.tasks); navRow(.dict); navRow(.gloss)
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func navRow(_ item: MainView) -> some View {
        let active = mainView == item && selectedId == nil
        return Button { mainView = item; selectedId = nil } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 12)).foregroundStyle(active ? Color.pInk1 : Color.pInk2).frame(width: 16)
                Text(item.title).font(PFont.secondary).foregroundStyle(Color.pInk1)
                Spacer()
                if item == .tasks, taskStore.open.count > 0 {
                    Text("\(taskStore.open.count)").font(PFont.mono).foregroundStyle(Color.pInk3)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.pSelection).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if store.isRecording {
                    liveRow
                }
                let groups = sessions.grouped(filter: .all, search: search)
                if groups.isEmpty && !store.isRecording {
                    Text(search.isEmpty ? "Пока нет записей." : "Ничего не найдено.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.pInk3)
                        .padding(.horizontal, 10).padding(.top, 12)
                }
                ForEach(groups, id: \.0) { label, rows in
                    Text(label.uppercased()).font(PFont.label).tracking(0.4)
                        .foregroundStyle(Color.pInk3).padding(.leading, 8).padding(.top, 12).padding(.bottom, 4)
                    ForEach(rows) { row in sessionRow(row) }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("СЕГОДНЯ").font(PFont.label).tracking(0.4)
                .foregroundStyle(Color.pInk3).padding(.leading, 8).padding(.top, 8)
            Button {
                selectedId = nil; mainView = .meeting
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.pAccent).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.notes.topics.first ?? "Новая запись").font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                        if let s = store.recordingStartedAt {
                            HStack(spacing: 4) {
                                Text(store.isPaused ? "На паузе ·" : "Идёт запись ·").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                                ElapsedText(since: s, color: .pInk3).font(.system(size: 11))
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.pSelection))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Текущая запись")
        }
    }

    private func sessionRow(_ r: SessionRecord) -> some View {
        Button { selectedId = r.id; mainView = .meeting } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.title).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                        if r.hasSummary { Text("✦").font(.system(size: 10)).foregroundStyle(Color.pAccent) }
                    }
                    Text(r.subtitle).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selectedId == r.id ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            content
            Hairline()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(paneTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1)
                Text(paneSubtitle).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).lineLimit(1)
            }
            Spacer()
            if store.isRecording {
                toolbarButton(danger: true, label: "Стоп") { store.stop() }
            } else {
                toolbarButton(danger: false, accentDot: true, label: "Запись") { if store.canRecord { selectedId = nil; mainView = .meeting; store.start() } }
                    .disabled(!store.canRecord)
            }
            if mainView == .meeting {
                if store.hasTranscript || !store.notes.isEmpty || viewingPast {
                    toolbarButton(danger: false, label: "Рецепты") { showRecipes = true }
                }
                toolbarButton(danger: false, label: "Поделиться") { showShare = true }
                    .popover(isPresented: $showShare, arrowEdge: .bottom) { sharePopover }
            }
        }
        .padding(.horizontal, 20).frame(height: 56)
        .background(Color.pCanvas)
    }

    private func toolbarButton(danger: Bool, accentDot: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if danger { RoundedRectangle(cornerRadius: 2).fill(Color.pDanger).frame(width: 9, height: 9) }
                else if accentDot { Circle().fill(Color.pAccent).frame(width: 9, height: 9) }
                Text(label)
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pButtonBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var paneTitle: String {
        if mainView != .meeting { return mainView.title }
        if viewingPast, let s = selected { return s.title }
        if store.isRecording { return store.notes.topics.first ?? "Идёт запись" }
        return "Готово к записи"
    }
    private var paneSubtitle: String {
        switch mainView {
        case .meeting:
            if viewingPast, let s = selected { return s.subtitle }
            let lang = store.language == "auto" ? "авто" : store.language.uppercased()
            return "Сегодня · \(lang)"
        case .tasks:
            let done = taskStore.tasks.count - taskStore.open.count
            return "\(taskStore.open.count) открытых · \(done) завершено"
        case .dict: return "За последние дни"
        case .all:  return "\(sessions.sessions.count) записей"
        case .gloss: return "\(glossary.terms.count) терминов"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch mainView {
        case .meeting: meetingContent
        case .tasks:   TasksView(store: store)
        case .dict:    DictView(store: store)
        case .all:     AllView(store: store) { id in selectedId = id; mainView = .meeting }
        case .gloss:   GlossaryView()
        }
    }

    private var meetingContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 0) {
                        if viewingPast { pastBody }
                        else { liveBody }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: PMetric.notesMeasure, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 20)
            }
            .onChange(of: store.lines.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .background(Color.pCanvas)
        }
    }

    @ViewBuilder
    private var liveBody: some View {
        switch store.stage {
        case .needsModel:
            EmptyStateView(icon: "arrow.down.circle", title: "Модель ещё не загружена",
                           subtitle: "\(ModelCatalog.info(store.selectedModel)?.title ?? "Модель") · \(ModelCatalog.info(store.selectedModel)?.sizeMB ?? 0) МБ, разово.",
                           action: ("Скачать", store.downloadAndPrepare))
        case .downloading(let f):
            LoadingLine(text: "Скачиваю модель — \(Int(f*100))%", progress: f)
        case .preparing:
            LoadingLine(text: "Готовлю модель…", progress: nil)
        case .error(let m):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Что-то пошло не так", subtitle: m,
                           action: ("Повторить", store.downloadAndPrepare), danger: true)
        case .ready, .listening:
            if store.hasTranscript || !store.notes.isEmpty || store.askQuestion != nil || store.notesError != nil {
                liveContent
            } else {
                EmptyStateView(icon: "waveform", title: "Готово к записи",
                               subtitle: "Нажмите «Запись» или \(Hotkeys.record).", action: nil)
            }
        }
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            participantsRow(Set(store.lines.map(\.speaker.title)))
            if store.askQuestion != nil { askCard }
            if let err = store.notesError, store.notes.isEmpty { notesErrorCard(err) }
            if !store.notes.isEmpty { summaryCard(store.notes) }
            meetingTasks(store.currentSessionId)

            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(store.lines) { line in
                    TranscriptBlock(speaker: line.speaker.title, text: line.text, partial: !line.isFinal)
                }
            }

            if store.notesGenerating {
                HStack(spacing: 8) {
                    Circle().fill(Color.pInk3).frame(width: 6, height: 6)
                    Text("Parley пишет заметки").font(PFont.secondary).foregroundStyle(Color.pInk3)
                }
            }

            Color.clear.frame(height: 24)
            liveFooter
        }
    }

    private func participantsRow(_ speakers: Set<String>) -> some View {
        let names = speakers.isEmpty
            ? (store.captureMode == .micAndSystem ? ["Вы", "Собеседник"] : ["Вы"])
            : Array(speakers).sorted()
        return HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(names.prefix(5), id: \.self) { Avatar(initials: String($0.prefix(1)).uppercased()) }
                if names.count > 5 { Avatar(initials: "+\(names.count - 5)") }
            }
            let lang = store.language == "auto" ? "авто" : store.language.uppercased()
            Text("\(names.count) \(Self.plural(names.count, "участник", "участника", "участников")) · \(lang)")
                .font(.system(size: 12.5)).foregroundStyle(Color.pInk2)
        }
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    @ViewBuilder
    private func meetingTasks(_ sessionId: UUID) -> some View {
        let items = taskStore.forSession(sessionId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Задачи")
                ForEach(items) { t in
                    HStack(spacing: 14) {
                        Button { taskStore.toggle(t.id) } label: {
                            TaskCheck(done: t.done).frame(width: 28, height: 40).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text(t.text).font(.system(size: 14))
                            .foregroundStyle(t.done ? Color.pInk3 : Color.pInk1)
                            .strikethrough(t.done, color: Color.pInk3)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let o = t.owner, !o.isEmpty { Avatar(initials: String(o.prefix(2)).uppercased()) }
                        if let d = t.due, !d.isEmpty { Text(d).font(PFont.mono).foregroundStyle(t.done ? Color.pInk3 : Color.pAccent) }
                    }
                    .frame(minHeight: 40)
                }
            }
        }
    }

    private var liveFooter: some View {
        HStack(spacing: 10) {
            Circle().fill(store.isRecording && !store.isPaused ? Color.pAccent : Color.pControlBorder).frame(width: 7, height: 7)
            Text(store.isPaused ? "На паузе" : store.isRecording ? "Слушаю разговор" : "Готов")
                .font(.system(size: 12.5)).foregroundStyle(Color.pInk2)
            LevelMeterView(levels: store.levels, active: store.isRecording && !store.isPaused, bars: 3, leading: 2)
            Spacer()
            Button { store.regenerateNotes() } label: {
                HStack(spacing: 6) {
                    if store.notesGenerating { PSpinner(size: 14) }
                    else { Text("✦").foregroundStyle(Color.pAccent) }
                    Text(store.notesGenerating ? "Пишу…" : store.notes.isEmpty ? "Подвести итог" : "Обновить итог")
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.parley(0x232120, 0xF4EFEA))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Color.pAccent.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pAccent.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(store.notesGenerating || !store.hasTranscript)
            .help("Подвести итог встречи (⌘⇧S)")
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(Color.pLine2).frame(height: 1) }
    }

    @ViewBuilder
    private var pastBody: some View {
        if let s = selected {
            let blocks = parseTranscript(s.transcript ?? s.title)
            VStack(alignment: .leading, spacing: 20) {
                participantsRow(Set(blocks.map(\.0).filter { !$0.isEmpty }))
                let pastNotes = MeetingNotes(summary: s.noteSummary ?? [], decisions: s.noteDecisions ?? [],
                                             actions: [], topics: s.noteTopics ?? [])
                if !pastNotes.isEmpty { summaryCard(pastNotes) }   // full card: Итог + Решения + Темы
                meetingTasks(s.id)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        TranscriptBlock(speaker: block.0, text: block.1, partial: false)
                    }
                }
            }
        }
    }

    // MARK: Notes card

    private func summaryCard(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) { Text("✦").foregroundStyle(Color.pAccent); Text("Итог").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1) }
            if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: PSpace.xs) {
                    ForEach(Array(notes.summary.enumerated()), id: \.offset) { _, s in NoteBullet(text: s) }
                }
            }
            if !notes.decisions.isEmpty { notesSection("Решения", notes.decisions.map { ($0, nil as String?) }) }
            // Задачи render below as a checkable section (from TaskStore) — not here.
            if !notes.topics.isEmpty {
                Text("Темы: " + notes.topics.joined(separator: " · ")).font(PFont.secondary).foregroundStyle(Color.pInk3)
            }
        }
        .padding(PSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: PRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func summaryCardBullets(_ title: String, _ bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) { Text("✦").foregroundStyle(Color.pAccent); Text("Итог").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1) }
            ForEach(Array(bullets.enumerated()), id: \.offset) { _, s in NoteBullet(text: s) }
        }
        .padding(PSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: PRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func notesSection(_ label: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: PSpace.xs) {
            Text(label.uppercased()).font(PFont.label).tracking(0.5).foregroundStyle(Color.pInk3)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: PSpace.xs) {
                    Circle().fill(Color.pInk3).frame(width: 4, height: 4).padding(.top, 7)
                    Text(row.0).font(PFont.secondary).foregroundStyle(Color.pInk1).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let owner = row.1 { Text(owner).font(PFont.label).foregroundStyle(Color.pInk3) }
                }
            }
        }
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            HStack(alignment: .top, spacing: PSpace.xs) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Color.pAccent).padding(.top, 1)
                Text(store.askQuestion ?? "").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PSpace.s)
                Button { store.dismissAsk() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.pInk3)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Закрыть")
            }
            if store.asking {
                HStack(spacing: PSpace.xs) { PSpinner(size: 14); Text("Parley думает…").font(PFont.secondary).foregroundStyle(Color.pInk3) }
            } else if let err = store.askError {
                Text(err).font(PFont.secondary).foregroundStyle(Color.pDanger).fixedSize(horizontal: false, vertical: true)
            } else if let a = store.askAnswer {
                Text(a).font(PFont.body).lineSpacing(4).foregroundStyle(Color.pInk1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if store.askAnswer != nil, !store.askSources.isEmpty {
                Divider().overlay(Color.pLine2).padding(.vertical, 2)
                Text("Источники").font(PFont.label).foregroundStyle(Color.pInk3)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(store.askSources) { s in
                        Button { selectedId = s.id; mainView = .meeting } label: {
                            Text(s.title).font(.system(size: 11)).foregroundStyle(Color.pAccent).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.pAccent.opacity(0.12)).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(PSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: PRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func notesErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(Color.pDanger).padding(.top, 1)
            VStack(alignment: .leading, spacing: PSpace.xs) {
                Text("AI-заметки недоступны").font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Text(message).font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PSpace.s) {
                    Button("Повторить") { store.regenerateNotes() }.buttonStyle(PBorderedButtonStyle())
                    Button("Открыть настройки") { showingSettings = true }.buttonStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pAccent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(PSpace.m)
        .background(Color.pDanger.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: PRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pDanger.opacity(0.35), lineWidth: 1))
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(store.isRecording && !store.isPaused ? Color.pAccent : Color.pControlBorder).frame(width: 7, height: 7)
                if let s = store.recordingStartedAt, store.isRecording {
                    ElapsedText(since: s, color: .pInk2).font(PFont.mono)
                } else {
                    Text("00:00").font(PFont.mono).foregroundStyle(Color.pInk3)
                }
            }
            meterCluster("Мик", store.levels)
            meterCluster("Дин", store.levelsThem)
            Spacer()
            HStack(spacing: 16) {
                KeyHintView(keys: Hotkeys.search, label: "Поиск")
                KeyHintView(keys: Hotkeys.record, label: "Запись")
                KeyHintView(keys: "Space", label: "Пауза")
            }
        }
        .padding(.horizontal, 16).frame(height: 32)
        .background(Color.pChrome)
    }

    private func meterCluster(_ label: String, _ levels: [Float]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.pInk3)
            LevelMeterView(levels: levels, active: store.isRecording && !store.isPaused, bars: 3, leading: 2)
        }
    }

    // MARK: Helpers

    private func parseTranscript(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").map { line in
            if let colon = line.firstIndex(of: ":") {
                return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return ("", String(line))
        }
    }

    // MARK: - Export / share

    private var sharePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ShareMenuRow(title: shareCopied ? "Скопировано ✓" : "Копировать текст",
                         icon: shareCopied ? "checkmark" : "doc.on.doc", tint: shareCopied) { copyShare() }
            ShareMenuRow(title: "Сохранить PDF…", icon: "arrow.down.doc") { savePDF() }
            ShareMenuRow(title: "Поделиться…", icon: "square.and.arrow.up") { systemShare() }
        }
        .padding(6).frame(width: 226)
    }

    private func currentExport() -> MeetingExport {
        if viewingPast, let s = selected {
            let turns: [MeetingExport.Turn] = (s.transcript ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).map { line in
                    if let c = line.firstIndex(of: ":") {
                        return .init(role: String(line[..<c]).trimmingCharacters(in: .whitespaces),
                                     text: String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces))
                    }
                    return .init(role: "", text: String(line))
                }
            let tasks = taskStore.forSession(s.id).map { MeetingExport.TaskLine(text: $0.text, owner: $0.owner, due: $0.due, done: $0.done) }
            return MeetingExport(title: s.title, date: s.date, durationSec: s.durationSec, participants: [],
                                 summary: s.noteSummary ?? [], decisions: s.noteDecisions ?? [],
                                 tasks: tasks, transcript: turns, includeTranscript: false)
        }
        let parts = Array(Set(store.lines.map(\.speaker.title))).sorted()
        let turns = store.lines.map { MeetingExport.Turn(role: $0.speaker.title, text: $0.text) }
        let tasks = taskStore.forSession(store.currentSessionId).map { MeetingExport.TaskLine(text: $0.text, owner: $0.owner, due: $0.due, done: $0.done) }
        return MeetingExport(title: store.notes.topics.first ?? "Встреча",
                             date: store.recordingStartedAt ?? Date(),
                             durationSec: store.recordingStartedAt.map { Date().timeIntervalSince($0) },
                             participants: parts, summary: store.notes.summary, decisions: store.notes.decisions,
                             tasks: tasks, transcript: turns, includeTranscript: false)
    }

    private func copyShare() {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(currentExport().shareText(), forType: .string)
        shareCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { shareCopied = false; showShare = false }
    }

    private func savePDF() {
        let export = currentExport()
        showShare = false
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(export.title).pdf"
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url { try? export.pdfData().write(to: url) }
    }

    private func systemShare() {
        let export = currentExport()
        showShare = false
        var items: [Any] = [export.shareText()]
        if let pdf = export.pdfTempURL() { items.append(pdf) }
        guard let view = NSApp.keyWindow?.contentView else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            let anchor = NSRect(x: view.bounds.maxX - 220, y: view.bounds.maxY - 56, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }
}

/// A row in the share popover with a subtle accent hover highlight.
private struct ShareMenuRow: View {
    let title: String
    let icon: String
    var tint: Bool = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint ? Color.pAccent : Color.pInk2).frame(width: 18)
                Text(title).font(PFont.secondary).foregroundStyle(tint ? Color.pAccent : Color.pInk1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.pAccent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Full-size content so the shell reaches the very top; the traffic lights stay at their natural
/// top-left position (we reserve a 44pt band for them in the sidebar — standard NSToolbar+sidebar).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One transcript block — speaker name over the line (a readable record, not a chat bubble).
struct TranscriptBlock: View {
    let speaker: String
    let text: String
    let partial: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !speaker.isEmpty {
                Text(speaker).font(PFont.secondaryStrong).foregroundStyle(Color.pInk2)
            }
            (Text(text).foregroundColor(Color.pInk1) + Text(partial ? " …" : "").foregroundColor(Color.pInk3))
                .font(PFont.body).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small subviews

struct ElapsedText: View {
    let since: Date
    var color: Color = .pInk2
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text(String(format: "%02d:%02d", s / 60, s % 60))
                .font(PFont.monoSecondary).foregroundStyle(color)
        }
    }
}

private struct LoadingLine: View {
    let text: String
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            Text(text).font(PFont.body).foregroundStyle(Color.pInk2)
            if let p = progress {
                ProgressView(value: p).tint(Color.pAccent).frame(maxWidth: 320)
            } else {
                PSpinner(size: 24)
            }
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (String, () -> Void)? = nil
    var danger: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: PSpace.s) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(danger ? Color.pDanger : Color.pInk3)
            Text(title).font(PFont.heading).foregroundStyle(Color.pInk1)
            Text(subtitle).font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
            if let (label, act) = action {
                Button(label, action: act).buttonStyle(PPrimaryButtonStyle()).padding(.top, PSpace.xxs)
            }
        }
        .padding(.top, PSpace.l)
    }
}

// Type-erased button style so a conditional can pick between two styles.
struct AnyButtonStyle: ButtonStyle {
    private let _make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { _make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { _make(configuration) }
}
