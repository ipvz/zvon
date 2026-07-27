import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app shell: sidebar (history) + main pane (transcript · footer · status bar). Single column,
/// no right rail (spec §1). Traffic lights float over the sidebar's top row.
struct MeetingView: View {
    @EnvironmentObject var store: TranscriptStore
    @EnvironmentObject var models: ModelManager
    @ObservedObject private var loc = L11n.shared
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var taskStore = TaskStore.shared
    @ObservedObject private var glossary = GlossaryStore.shared
    @ObservedObject private var commandStore = CommandStore.shared
    @ObservedObject private var spaceStore = SpaceStore.shared
    @State private var search = ""
    @State private var selectedId: UUID?
    @State private var selectedSpaceId: UUID?
    @State private var newSpaceForMeeting: UUID?    // record context-menu → «Новое пространство…»
    @State private var mainView: MainView = .meeting
    @State private var showingSettings = false
    @State private var showShare = false
    @State private var shareCopied = false
    @State private var showRecipes = false
    @State private var recFilter: RecordFilter = .all
    @State private var detailTab: DetailTab = .summary
    @State private var detailAsk = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var detailAskFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Which pane of a meeting's detail is showing (spec: Итог first, Транскрипт second).
    enum DetailTab { case summary, transcript }

    /// Записи is the 3-column home (list + detail); .meeting is an alias kept for existing callers.
    private var atHome: Bool { mainView == .records || mainView == .meeting }

    /// Пространства pane: grid overview, or one space's detail when selected.
    @ViewBuilder private var spacesPane: some View {
        if let sid = selectedSpaceId, spaceStore.space(sid) != nil {
            SpaceDetailView(spaceId: sid,
                            onOpenMeeting: { id in selectedSpaceId = nil; selectedId = id; mainView = .records },
                            onBack: { selectedSpaceId = nil })
        } else {
            SpacesView(onOpen: { selectedSpaceId = $0 })
        }
    }

    /// Calendar radar: an ongoing meeting/call is detected → offer one-tap record, pre-named from the event.
    @ViewBuilder private func radarBanner(_ m: CalendarEvent) -> some View {
        HStack(spacing: 11) {
            Circle().fill(Color.pRecording).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Идёт встреча", "Meeting in progress"))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.pInk3)
                Text(m.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.pInk1)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 14)
            Button { store.recordSuggestedMeeting() } label: {
                Text(L("Записать", "Record"))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Color.pAccent).clipShape(Capsule())
            }.buttonStyle(.plain)
            Button { store.dismissSuggestedMeeting() } label: {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.pInk3).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: 380)
        .background(Color.pCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.pLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(.top, 48).padding(.trailing, 18)   // clear the traffic-light band
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    var body: some View {
        Group {
            if showingSettings {
                ParleySettingsView(onClose: { showingSettings = false })
                    .environmentObject(store)
                    .environmentObject(models)
            } else {
                HStack(spacing: 0) {
                    sidebar                       // 238
                    if mainView == .tasks {
                        TasksView(store: store).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.pCanvas)
                    } else if mainView == .gloss {
                        GlossaryView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.pCanvas)
                    } else if mainView == .commands {
                        CommandsView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.pCanvas)
                    } else if mainView == .spaces {
                        spacesPane.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.pCanvas)
                    } else {
                        recordsColumn             // 308
                        detailColumn              // remainder (min 420)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let m = store.suggestedMeeting, !store.isRecording {
                        radarBanner(m)
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.suggestedMeeting?.key)
        .frame(minWidth: 1040, minHeight: 640)
        .background(Color.pCanvas)
        .background(WindowConfigurator())   // full-size content so the shell reaches the top
        .ignoresSafeArea()                  // content flush under the (hidden) title bar — no dead band
        .onAppear { store.onAppear() }
        // Any record start (button OR ⌘⇧R hotkey) takes over the live pane, even from a past session.
        .onChange(of: store.isRecording) { _, rec in
            // Live recording opens on the Транскрипт tab (the summary fills in over time); when the
            // recording stops, flip to Итог. The user can switch manually at any point.
            if rec { selectedId = nil; mainView = .records; detailTab = .transcript }
            else { detailTab = .summary }
        }
        // Selecting a past record shows its Итог first (per spec).
        .onChange(of: selectedId) { _, id in if id != nil { detailTab = .summary } }
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
        // Record context-menu → «Новое пространство…»: create it, then drop this record straight in.
        .sheet(isPresented: Binding(get: { newSpaceForMeeting != nil }, set: { if !$0 { newSpaceForMeeting = nil } })) {
            SpaceEditor(space: nil, onCreated: { sp in
                if let mid = newSpaceForMeeting { spaceStore.add(meeting: mid, to: sp.id) }
            })
        }
    }

    /// The content fed to a recipe: the dictation text, or the meeting recap + transcript.
    private func meetingMaterial() -> String {
        if viewingPast, let s = selected, s.kind == .dictation { return s.title }
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
            Color.clear.frame(height: 38)
            // (2) Brand (window-handoff §1): full wave + "ZVON", where ZV=accent, ON=ink (founders'
            // initials). No tile, no backing. Centred; sized to fill the column without dead air.
            HStack(spacing: 12) {
                if let wave = Brand.wave(dark: colorScheme == .dark) {
                    Image(nsImage: wave).resizable().scaledToFit().frame(width: 72)
                }
                (Text("ZV").foregroundColor(.pAccent) + Text("ON").foregroundColor(.pInk1))
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.32)   // −0.012em × 27pt
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)

            VStack(spacing: 8) {
                // «Начать запись» — solid accent primary (mockup §2.2: #00C4C4/#04201F, h36, r8) + ⌘⇧R.
                Button {
                    if store.canRecord { selectedId = nil; mainView = .records; store.start() }
                } label: {
                    HStack(spacing: 8) {
                        Text(L("Начать запись", "Start recording")).font(.system(size: 13.5, weight: .semibold))
                        Text(Hotkeys.record).font(.system(size: 11.5, design: .monospaced)).opacity(0.6)
                    }
                    .foregroundStyle(Color.pOnAccent)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Color.pAccent.opacity(store.canRecord ? 1 : 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!store.canRecord)

                // «Поиск и вопросы» — one field; live meeting → ask about it, else → ask the archive.
                HStack(spacing: 8) {
                    Circle().strokeBorder(Color.pInk3, lineWidth: 1.5).frame(width: 13, height: 13)
                    TextField(store.isRecording ? L("Вопрос по встрече", "Ask about the meeting") : L("Поиск и вопросы", "Search & ask"), text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color.pInk1)
                        .focused($searchFocused)
                        .onSubmit {
                            let q = search.trimmingCharacters(in: .whitespaces)
                            guard !q.isEmpty else { return }
                            selectedId = nil; mainView = .records; showingSettings = false
                            store.isRecording ? store.ask(q) : store.askArchive(q)
                        }
                    Text(Hotkeys.search).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.pInk3)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine, lineWidth: 1))
                .focusRing(searchFocused, radius: 8)
                .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
            }
            .padding(.horizontal, 12)

            navSection

            Spacer(minLength: 8)

            // Privacy plate — always in the sidebar (spec §2.5, §3): the one place the promise shows.
            HStack(spacing: 8) {
                Circle().fill(Color.pAccent).frame(width: 7, height: 7)
                Text(L("Распознавание локально\nаудио не покидает Mac", "Recognition runs on-device\naudio never leaves your Mac"))
                    .font(.system(size: 11.5)).foregroundStyle(Color.pInk2).lineSpacing(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine2, lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 8)

            // Compact interface-language switch — right here in the sidebar, above Settings.
            HStack(spacing: 3) {
                ForEach(AppLang.allCases) { l in
                    let on = loc.lang == l
                    Text(l == .ru ? "РУ" : "EN")
                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.pAccent : Color.pInk3)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.pAccent.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { loc.lang = l }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.pField))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine2, lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 8)

            Button { showingSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Color.pInk2).frame(width: 16)
                    Text(L("Настройки", "Settings")).font(.system(size: 13)).foregroundStyle(Color.pInk1)
                    Spacer()
                    Text("⌘,").font(PFont.mono).foregroundStyle(Color.pInk3)
                }
                .padding(.horizontal, 18).frame(height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: 238)
        .background(Color.pRail)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.pLine).frame(width: 1) }
    }

    @ViewBuilder private var brandMark: some View {
        if let m = Brand.mark {
            Image(nsImage: m).resizable().interpolation(.high).frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 7).fill(Color.pAccent).frame(width: 24, height: 24)
        }
    }

    private var navSection: some View {
        VStack(spacing: 2) {
            navRow(.records); navRow(.tasks)
            spacesNav
            navRow(.commands); navRow(.gloss)
        }
        .padding(.horizontal, 12).padding(.top, 16)
    }

    /// «Пространства» — a nav row that opens the grid, plus an inline list of spaces for quick jump.
    @ViewBuilder private var spacesNav: some View {
        let atSpaces = mainView == .spaces
        Button { mainView = .spaces; selectedSpaceId = nil } label: {
            HStack(spacing: 10) {
                Image(systemName: MainView.spaces.icon).font(.system(size: 12))
                    .foregroundStyle(atSpaces ? Color.pAccent : Color.pInk2).frame(width: 16)
                Text(MainView.spaces.title).font(.system(size: 13.5, weight: atSpaces ? .medium : .regular))
                    .foregroundStyle(atSpaces ? Color.pAccent : Color.pInk1)
                Spacer()
                if spaceStore.spaces.count > 0 {
                    Text("\(spaceStore.spaces.count)").font(.system(size: 12)).foregroundStyle(Color.pInk3)
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(atSpaces && selectedSpaceId == nil ? Color.pAccent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        ForEach(spaceStore.spaces) { sp in
            let on = atSpaces && selectedSpaceId == sp.id
            Button { mainView = .spaces; selectedSpaceId = sp.id } label: {
                HStack(spacing: 8) {
                    Circle().fill(spaceColor(sp.colorHex)).frame(width: 7, height: 7)
                    Text(sp.name).font(.system(size: 12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.pAccent : Color.pInk2).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(sp.meetingIds.count)").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                }
                .padding(.leading, 26).padding(.trailing, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.pAccent.opacity(0.1) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A sidebar nav row (spec §2.4): active = teal wash + #4FE0E0 text; a right-hand count/badge.
    private func navRow(_ item: MainView) -> some View {
        let active = (item == .records ? atHome : mainView == item)
        return Button { mainView = item; if item == .records { selectedId = nil } } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 12))
                    .foregroundStyle(active ? Color.pAccent : Color.pInk2).frame(width: 16)
                Text(item.title).font(.system(size: 13.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.pAccent : Color.pInk1)
                Spacer()
                navCount(item)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.pAccent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func navCount(_ item: MainView) -> some View {
        switch item {
        case .records:
            let n = sessions.sessions.count
            if n > 0 { Text("\(n)").font(.system(size: 12)).foregroundStyle(Color.pAccent.opacity(0.85)) }
        case .tasks:
            let n = taskStore.open.count
            if n > 0 {
                Text("\(n)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                    .padding(.horizontal, 7).frame(height: 18).background(Color.pAccent).clipShape(Capsule())
            }
        case .gloss:
            let n = glossary.terms.count
            if n > 0 { Text("\(n)").font(.system(size: 12)).foregroundStyle(Color.pInk3) }
        case .commands:
            let n = commandStore.commands.count
            if n > 0 { Text("\(n)").font(.system(size: 12)).foregroundStyle(Color.pInk3) }
        default: EmptyView()
        }
    }

    // MARK: - Records column (308) — day-grouped feed of meetings + dictations (spec §2 list)

    private var recordsColumn: some View {
        let all = sessions.sessions
        let counts: [RecordFilter: Int] = [
            .all: all.count,
            .meeting: all.filter { $0.kind == .meeting }.count,
            .dict: all.filter { $0.kind == .dictation }.count,
        ]
        let groups = sessions.grouped(filter: recFilter.sessionFilter, search: search)
        return VStack(spacing: 0) {
            Color.clear.frame(height: 44)   // align with the traffic-lights band
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Записи", "Records")).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.pInk1)
                    Spacer()
                    Text(L("\(store.totalDictatedWords.formatted()) слов", "\(store.totalDictatedWords.formatted()) words"))
                        .font(.system(size: 12)).foregroundStyle(Color.pInk3)
                }
                RecordFilterBar(filter: $recFilter, counts: counts)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.isRecording && recFilter != .dict { recordLiveRow }
                    if groups.isEmpty && !store.isRecording {
                        Text(search.isEmpty ? L("Пока нет записей.", "No records yet.") : L("Ничего не найдено.", "Nothing found."))
                            .font(.system(size: 12.5)).foregroundStyle(Color.pInk3).padding(10)
                    }
                    ForEach(groups, id: \.0) { day, items in
                        Text(day.uppercased()).font(.system(size: 11)).tracking(0.6)
                            .foregroundStyle(Color.pInk3).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                        ForEach(items) { s in recordRow(s) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(width: 308)
        .background(Color.pCanvas)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.pLine2).frame(width: 1) }
    }

    private var recordLiveRow: some View {
        Button { selectedId = nil; mainView = .records } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(Color.pRecording).frame(width: 7, height: 7)
                    Text(store.meetingTitle ?? store.notes.topics.first ?? L("Новая запись", "New recording"))
                        .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.pInk1).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(store.isPaused ? L("На паузе ·", "Paused ·") : L("Идёт запись ·", "Recording ·")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                    if let s = store.recordingStartedAt { ElapsedText(since: s, color: .pInk3, font: .system(size: 11.5, design: .monospaced)) }
                }
                .padding(.leading, 15)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7).fill(selectedId == nil && store.isRecording ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recordRow(_ s: SessionRecord) -> some View {
        let active = selectedId == s.id
        return Button { selectedId = s.id; mainView = .records } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if s.kind == .meeting {
                        RoundedRectangle(cornerRadius: 2).fill(Color.pAccent).frame(width: 7, height: 7)
                    } else {
                        Circle().strokeBorder(Color.pInk3, lineWidth: 1.5).frame(width: 7, height: 7)
                    }
                    Text(s.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.pInk1).lineLimit(1)
                }
                Text(recordMeta(s)).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).lineLimit(1).padding(.leading, 15)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { spaceMenu(for: s) }
    }

    /// Record right-click → toggle membership in each space, or spin up a new one seeded with this record.
    @ViewBuilder private func spaceMenu(for s: SessionRecord) -> some View {
        Section(L("В пространство", "Add to space")) {
            ForEach(spaceStore.spaces) { sp in
                Button {
                    spaceStore.toggle(meeting: s.id, in: sp.id)
                } label: {
                    if spaceStore.contains(sp.id, meeting: s.id) { Label(sp.name, systemImage: "checkmark") }
                    else { Text(sp.name) }
                }
            }
            Button(L("Новое пространство…", "New space…")) { newSpaceForMeeting = s.id }
        }
    }

    private func recordMeta(_ s: SessionRecord) -> String {
        let t = SessionStore.time.string(from: s.date)
        switch s.kind {
        case .meeting:
            let d = s.durationSec.map { L(" · \(Int(($0 / 60).rounded())) мин", " · \(Int(($0 / 60).rounded())) min") } ?? ""
            return L("Встреча · \(t)\(d)", "Meeting · \(t)\(d)")
        case .dictation:
            let w = s.title.split { $0 == " " || $0 == "\n" }.count
            return L("Диктовка · \(t) · \(w) \(Self.plural(w, "слово", "слова", "слов"))", "Dictation · \(t) · \(w) \(w == 1 ? "word" : "words")")
        }
    }

    // MARK: - Detail column (Итог / Транскрипт tabs + ask footer) — spec §2 detail

    private var detailIsDictation: Bool { viewingPast && selected?.kind == .dictation }
    private var detailHasContent: Bool { store.isRecording || viewingPast }
    private var detailSessionId: UUID { (viewingPast ? selected?.id : store.currentSessionId) ?? store.currentSessionId }

    private var detailNotes: MeetingNotes {
        if viewingPast, let s = selected {
            return MeetingNotes(summary: s.noteSummary ?? [], decisions: s.noteDecisions ?? [], actions: [], topics: s.noteTopics ?? [])
        }
        return store.notes
    }

    private var detailTitleText: String {
        if viewingPast, let s = selected { return s.kind == .dictation ? L("Диктовка", "Dictation") : s.title }
        if store.isRecording { return store.meetingTitle ?? store.notes.topics.first ?? L("Идёт запись", "Recording") }
        return L("Нет выбранной записи", "No record selected")
    }
    private var detailMetaText: String {
        if viewingPast, let s = selected { return s.subtitle }
        let lang = store.language == "auto" ? "RU" : store.language.uppercased()
        let src = store.captureMode == .micAndSystem ? L("2 источника", "2 sources") : L("микрофон", "microphone")
        return L("\(src) · \(lang) · локально", "\(src) · \(lang) · local")
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailHeader
            Hairline(color: .pLine2)
            if !detailHasContent {
                EmptyStateView(icon: "waveform", title: L("Готово к записи", "Ready to record"),
                               subtitle: L("Нажмите «Начать запись» или выберите запись слева.", "Press «Start recording» or pick a record on the left."), action: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detailIsDictation, let s = selected {
                ScrollView { dictationDetail(s).padding(.horizontal, 30).padding(.vertical, 26) }
            } else {
                detailScroll
                Hairline(color: .pLine2)
                detailAskFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pCanvas)
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(detailTitleText).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1)
                Text(detailMetaText).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.isRecording { toolbarButton(danger: true, label: L("Стоп", "Stop")) { store.stop() } }
            if detailHasContent && !detailIsDictation { detailTabControl }
            if detailHasContent {
                toolbarButton(danger: false, label: L("Собрать документ", "Build a document")) { showRecipes = true }
            }
        }
        .padding(.horizontal, 20).frame(height: 56)
        .background(Color.pCanvas)
    }

    private var detailTabControl: some View {
        HStack(spacing: 2) {
            detailTabSeg(L("Итог", "Summary"), .summary)
            detailTabSeg(L("Транскрипт", "Transcript"), .transcript)
        }
        .padding(2).background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func detailTabSeg(_ label: String, _ tab: DetailTab) -> some View {
        let active = detailTab == tab
        return Text(label).font(.system(size: 12.5, weight: active ? .medium : .regular))
            .foregroundStyle(active ? Color.pInk1 : Color.pInk2)
            .padding(.horizontal, 12).frame(height: 26)
            .background(active ? Color.pSelection : Color.clear).clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle()).onTapGesture { detailTab = tab }
    }

    private var detailScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.askQuestion != nil { askCard }
                    if let err = store.notesError, store.notes.isEmpty, detailTab == .summary { notesErrorCard(err) }
                    if detailTab == .summary { itogView } else { transcriptView }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 20)
            }
            .onChange(of: store.lines.count) { _, _ in
                if detailTab == .transcript { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    private var itogView: some View {
        let n = detailNotes
        let tasks = taskStore.forSession(detailSessionId)
        return VStack(alignment: .leading, spacing: 24) {
            if n.summary.isEmpty && n.decisions.isEmpty && tasks.isEmpty {
                if store.isRecording {
                    HStack(spacing: 8) {
                        Circle().fill(Color.pInk3).frame(width: 6, height: 6)
                        Text(store.notesGenerating ? L("ZVON пишет заметки…", "ZVON is writing notes…") : L("Итог появится по ходу встречи", "The summary will fill in as you go"))
                            .font(.system(size: 13)).foregroundStyle(Color.pInk3)
                    }
                } else {
                    Text(L("Итога пока нет.", "No summary yet.")).font(.system(size: 13)).foregroundStyle(Color.pInk3)
                }
            }
            if !n.summary.isEmpty { sumBlock(L("ТЕЗИСЫ", "KEY POINTS"), n.summary) }
            if !n.decisions.isEmpty { sumBlock(L("РЕШЕНИЯ", "DECISIONS"), n.decisions) }
            if !tasks.isEmpty { taskBlock(L("ЗАДАЧИ", "TASKS"), tasks) }
        }
    }

    private func blockHeader(_ label: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11)).tracking(0.9).foregroundStyle(Color.pInk3)
            Rectangle().fill(Color.pLine2).frame(height: 1)
        }
    }

    private func sumBlock(_ label: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            blockHeader(label)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Color.pInk3).frame(width: 5, height: 5).padding(.top, 8)
                    Text(r).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Color.pInk1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func taskBlock(_ label: String, _ items: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            blockHeader(label)
            ForEach(items) { t in
                HStack(alignment: .top, spacing: 12) {
                    Button { taskStore.toggle(t.id) } label: {
                        TaskCheck(done: t.done).frame(width: 14, height: 14).padding(.top, 2).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(t.text).font(.system(size: 14)).lineSpacing(3)
                        .foregroundStyle(t.done ? Color.pInk3 : Color.pInk1).strikethrough(t.done, color: .pInk3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let o = t.owner, !o.isEmpty { Text(o).font(PFont.mono).foregroundStyle(Color.pInk3) }
                }
            }
        }
    }

    @ViewBuilder private var transcriptView: some View {
        let blocks: [(String, String, Bool)] = {
            if viewingPast, let s = selected {
                return parseTranscript(s.transcript ?? s.title).map { ($0.0, $0.1, false) }
            }
            return store.lines.map { ($0.speaker.title, $0.text, !$0.isFinal) }
        }()
        if blocks.isEmpty {
            Text(store.isRecording ? L("Слушаю разговор…", "Listening…") : L("Транскрипт пуст.", "Transcript is empty."))
                .font(.system(size: 13)).foregroundStyle(Color.pInk3)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    TranscriptBlock(speaker: b.0, text: b.1, partial: b.2)
                }
            }
        }
    }

    private var detailAskFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField(L("Спросить по этой встрече…", "Ask about this meeting…"), text: $detailAsk)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.pInk1)
                    .focused($detailAskFocused)
                    .onSubmit {
                        let q = detailAsk.trimmingCharacters(in: .whitespaces)
                        guard !q.isEmpty else { return }
                        store.isRecording ? store.ask(q) : store.askArchive(q)
                        detailAsk = ""
                    }
                Text("⏎").font(PFont.mono).foregroundStyle(Color.pInk3)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pLine, lineWidth: 1))
            .focusRing(detailAskFocused, radius: 9)
            Text(L("ответ со ссылками на минуты", "answers cite the timestamps")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).fixedSize()
        }
        .padding(.horizontal, 30).padding(.vertical, 14)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if store.isRecording {
                    liveRow
                }
                let groups = sessions.grouped(filter: .all, search: search)
                if groups.isEmpty && !store.isRecording {
                    Text(search.isEmpty ? L("Пока нет записей.", "No records yet.") : L("Ничего не найдено.", "Nothing found."))
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
            Text(L("СЕГОДНЯ", "TODAY")).font(PFont.label).tracking(0.4)
                .foregroundStyle(Color.pInk3).padding(.leading, 8).padding(.top, 8)
            Button {
                selectedId = nil; mainView = .meeting
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.pRecording).frame(width: 6, height: 6)   // live recording = red
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.meetingTitle ?? store.notes.topics.first ?? L("Новая запись", "New recording")).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                        if let s = store.recordingStartedAt {
                            HStack(spacing: 4) {
                                Text(store.isPaused ? L("На паузе ·", "Paused ·") : L("Идёт запись ·", "Recording ·")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
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
            .accessibilityLabel(L("Текущая запись", "Current recording"))
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
                toolbarButton(danger: true, label: L("Стоп", "Stop")) { store.stop() }
            } else {
                toolbarButton(danger: false, accentDot: true, label: L("Запись", "Record")) { if store.canRecord { selectedId = nil; mainView = .meeting; store.start() } }
                    .disabled(!store.canRecord)
            }
            if mainView == .meeting {
                if store.hasTranscript || !store.notes.isEmpty || viewingPast {
                    toolbarButton(danger: false, label: L("Рецепты", "Recipes")) { showRecipes = true }
                }
                toolbarButton(danger: false, label: L("Поделиться", "Share")) { showShare = true }
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
        if viewingPast, let s = selected { return s.kind == .dictation ? L("Диктовка", "Dictation") : s.title }
        if store.isRecording { return store.meetingTitle ?? store.notes.topics.first ?? L("Идёт запись", "Recording") }
        return L("Готово к записи", "Ready to record")
    }
    private var paneSubtitle: String {
        switch mainView {
        case .meeting:
            if viewingPast, let s = selected { return s.subtitle }
            let lang = store.language == "auto" ? L("авто", "auto") : store.language.uppercased()
            return L("Сегодня · \(lang)", "Today · \(lang)")
        case .tasks:
            let done = taskStore.tasks.count - taskStore.open.count
            return L("\(taskStore.open.count) открытых · \(done) завершено", "\(taskStore.open.count) open · \(done) done")
        case .records:
            return L("\(sessions.sessions.count) записей · \(store.totalDictatedWords) слов надиктовано", "\(sessions.sessions.count) records · \(store.totalDictatedWords) words dictated")
        case .gloss: return L("\(glossary.terms.count) терминов", "\(glossary.terms.count) terms")
        case .commands: return L("\(CommandStore.shared.commands.count) команд", "\(CommandStore.shared.commands.count) commands")
        case .spaces: return L("\(spaceStore.spaces.count) пространств", "\(spaceStore.spaces.count) spaces")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch mainView {
        case .meeting: meetingContent
        case .tasks:   TasksView(store: store)
        case .records: RecordsView(store: store) { id in selectedId = id; mainView = .meeting }
        case .gloss:   GlossaryView()
        case .commands: CommandsView()
        case .spaces:  spacesPane
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
            EmptyStateView(icon: "arrow.down.circle", title: L("Модель ещё не загружена", "Model isn't downloaded yet"),
                           subtitle: L("\(ModelCatalog.info(store.selectedModel)?.title ?? "Модель") · \(ModelCatalog.info(store.selectedModel)?.sizeMB ?? 0) МБ, разово.", "\(ModelCatalog.info(store.selectedModel)?.title ?? "Model") · \(ModelCatalog.info(store.selectedModel)?.sizeMB ?? 0) MB, one time."),
                           action: (L("Скачать", "Download"), store.downloadAndPrepare))
        case .downloading(let f):
            LoadingLine(text: L("Скачиваю модель — \(Int(f*100))%", "Downloading model — \(Int(f*100))%"), progress: f)
        case .preparing:
            LoadingLine(text: L("Готовлю модель…", "Preparing model…"), progress: nil)
        case .error(let m):
            EmptyStateView(icon: "exclamationmark.triangle", title: L("Что-то пошло не так", "Something went wrong"), subtitle: m,
                           action: (L("Повторить", "Retry"), store.downloadAndPrepare), danger: true)
        case .ready, .listening:
            if store.hasTranscript || !store.notes.isEmpty || store.askQuestion != nil || store.notesError != nil {
                liveContent
            } else {
                EmptyStateView(icon: "waveform", title: L("Готово к записи", "Ready to record"),
                               subtitle: L("Нажмите «Запись» или \(Hotkeys.record).", "Press «Record» or \(Hotkeys.record)."), action: nil)
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
                    Text(L("ZVON пишет заметки", "ZVON is writing notes")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                }
            }

            Color.clear.frame(height: 24)
            liveFooter
        }
    }

    private func participantsRow(_ speakers: Set<String>) -> some View {
        let names = speakers.isEmpty
            ? (store.captureMode == .micAndSystem ? [L("Вы", "You"), L("Собеседник", "Them")] : [L("Вы", "You")])
            : Array(speakers).sorted()
        return HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(names.prefix(5), id: \.self) { Avatar(initials: String($0.prefix(1)).uppercased()) }
                if names.count > 5 { Avatar(initials: "+\(names.count - 5)") }
            }
            let lang = store.language == "auto" ? L("авто", "auto") : store.language.uppercased()
            Text(L("\(names.count) \(Self.plural(names.count, "участник", "участника", "участников")) · \(lang)", "\(names.count) \(names.count == 1 ? "participant" : "participants") · \(lang)"))
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
                SectionLabel(text: L("Задачи", "Tasks"))
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
            Text(store.isPaused ? L("На паузе", "Paused") : store.isRecording ? L("Слушаю разговор", "Listening") : L("Готов", "Ready"))
                .font(.system(size: 12.5)).foregroundStyle(Color.pInk2)
            LevelMeterView(levels: store.levels, active: store.isRecording && !store.isPaused, bars: 3, leading: 2)
            Spacer()
            Button { store.regenerateNotes() } label: {
                HStack(spacing: 6) {
                    if store.notesGenerating { PSpinner(size: 14) }
                    else { Text("✦").foregroundStyle(Color.pAccent) }
                    Text(store.notesGenerating ? L("Пишу…", "Writing…") : store.notes.isEmpty ? L("Подвести итог", "Summarize") : L("Обновить итог", "Update summary"))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.parley(0x232120, 0xF4EFEA))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Color.pAccent.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pAccent.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(store.notesGenerating || !store.hasTranscript)
            .help(L("Подвести итог встречи (⌘⇧S)", "Summarize the meeting (⌘⇧S)"))
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(Color.pLine2).frame(height: 1) }
    }

    @ViewBuilder
    private var pastBody: some View {
        if let s = selected {
            if s.kind == .dictation { dictationDetail(s) } else { meetingDetail(s) }
        }
    }

    private func meetingDetail(_ s: SessionRecord) -> some View {
        let blocks = parseTranscript(s.transcript ?? s.title)
        return VStack(alignment: .leading, spacing: 20) {
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

    /// A dictation has no итог — just the text, its word count/time, and a «Собрать документ» action.
    private func dictationDetail(_ s: SessionRecord) -> some View {
        let words = s.title.split { $0 == " " || $0 == "\n" }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(L("\(words) слов", "\(words) words")).font(PFont.mono).foregroundStyle(Color.pInk3)
                Text(SessionStore.time.string(from: s.date)).font(PFont.mono).foregroundStyle(Color.pInk3)
                Spacer()
                Button { showRecipes = true } label: {
                    HStack(spacing: 6) { Image(systemName: "doc.text"); Text(L("Собрать документ", "Build a document")) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.pInk1)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Color.pChrome).clipShape(RoundedRectangle(cornerRadius: PRadius.button))
                        .overlay(RoundedRectangle(cornerRadius: PRadius.button).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Text(s.title).font(PFont.body).lineSpacing(4).foregroundStyle(Color.pInk1)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Notes card

    private func summaryCard(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) { Text("✦").foregroundStyle(Color.pAccent); Text(L("Итог", "Summary")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1) }
            if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: PSpace.xs) {
                    ForEach(Array(notes.summary.enumerated()), id: \.offset) { _, s in NoteBullet(text: s) }
                }
            }
            if !notes.decisions.isEmpty { notesSection(L("Решения", "Decisions"), notes.decisions.map { ($0, nil as String?) }) }
            // Задачи render below as a checkable section (from TaskStore) — not here.
            if !notes.topics.isEmpty {
                Text(L("Темы: ", "Topics: ") + notes.topics.joined(separator: " · ")).font(PFont.secondary).foregroundStyle(Color.pInk3)
            }
        }
        .padding(PSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: PRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PRadius.card).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func summaryCardBullets(_ title: String, _ bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) { Text("✦").foregroundStyle(Color.pAccent); Text(L("Итог", "Summary")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1) }
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
                }.buttonStyle(.plain).accessibilityLabel(L("Закрыть", "Close"))
            }
            if store.asking {
                HStack(spacing: PSpace.xs) { PSpinner(size: 14); Text(L("ZVON думает…", "ZVON is thinking…")).font(PFont.secondary).foregroundStyle(Color.pInk3) }
            } else if let err = store.askError {
                Text(err).font(PFont.secondary).foregroundStyle(Color.pDanger).fixedSize(horizontal: false, vertical: true)
            } else if let a = store.askAnswer {
                Text(a).font(PFont.body).lineSpacing(4).foregroundStyle(Color.pInk1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if store.askAnswer != nil, !store.askSources.isEmpty {
                Divider().overlay(Color.pLine2).padding(.vertical, 2)
                Text(L("Источники", "Sources")).font(PFont.label).foregroundStyle(Color.pInk3)
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
                Text(L("AI-заметки недоступны", "AI notes unavailable")).font(PFont.secondaryStrong).foregroundStyle(Color.pInk1)
                Text(message).font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PSpace.s) {
                    Button(L("Повторить", "Retry")) { store.regenerateNotes() }.buttonStyle(PBorderedButtonStyle())
                    Button(L("Открыть настройки", "Open settings")) { showingSettings = true }.buttonStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pAccent)
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
            meterCluster(L("Мик", "Mic"), store.levels)
            meterCluster(L("Дин", "Spk"), store.levelsThem)
            Spacer()
            HStack(spacing: 16) {
                KeyHintView(keys: Hotkeys.search, label: L("Поиск", "Search"))
                KeyHintView(keys: Hotkeys.record, label: L("Запись", "Record"))
                KeyHintView(keys: "Space", label: L("Пауза", "Pause"))
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
            ShareMenuRow(title: shareCopied ? L("Скопировано ✓", "Copied ✓") : L("Копировать текст", "Copy text"),
                         icon: shareCopied ? "checkmark" : "doc.on.doc", tint: shareCopied) { copyShare() }
            ShareMenuRow(title: L("Сохранить PDF…", "Save PDF…"), icon: "arrow.down.doc") { savePDF() }
            ShareMenuRow(title: L("Поделиться…", "Share…"), icon: "square.and.arrow.up") { systemShare() }
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
        return MeetingExport(title: store.meetingTitle ?? store.notes.topics.first ?? L("Встреча", "Meeting"),
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
    var font: Font = PFont.monoSecondary
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text(String(format: "%02d:%02d", s / 60, s % 60))
                .font(font).foregroundStyle(color)
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
