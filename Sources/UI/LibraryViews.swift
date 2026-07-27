import SwiftUI

/// Which view the main pane shows — switched from the sidebar nav (single window).
enum MainView: String, CaseIterable, Identifiable {
    case meeting, records, tasks, gloss, commands
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meeting: return L("Встреча", "Meeting")
        case .records: return L("Записи", "Records")
        case .tasks:   return L("Задачи", "Tasks")
        case .gloss:   return L("Словарь", "Glossary")
        case .commands: return L("Команды", "Commands")
        }
    }
    var icon: String {
        switch self {
        case .meeting: return "waveform"
        case .records: return "rectangle.stack"
        case .tasks:   return "checklist"
        case .gloss:   return "character.book.closed"
        case .commands: return "bolt"
        }
    }
}

// MARK: - Shared bits

/// Initials avatar.
struct Avatar: View {
    let initials: String
    var size: CGFloat = 22
    var body: some View {
        Text(initials).font(.system(size: size * 0.43, weight: .semibold)).foregroundStyle(Color.pInk2)
            .frame(width: size, height: size)
            .background(Color.pSelection).clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.pCanvas, lineWidth: 2))
    }
}

/// 16pt task checkbox — unchecked outline, checked filled with a check.
struct TaskCheck: View {
    let done: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(done ? Color.pInk1 : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(done ? Color.clear : Color.pControlBorder, lineWidth: 1.5))
            if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.pCanvas) }
        }
        .frame(width: 16, height: 16)
    }
}

private func initials(_ name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
    let s = parts.map { String($0.prefix(1)) }.joined()
    return s.isEmpty ? "•" : s.uppercased()
}

private func dayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return L("Сегодня", "Today") }
    if cal.isDateInYesterday(date) { return L("Вчера", "Yesterday") }
    let f = DateFormatter(); f.locale = Locale(identifier: _uiLang == .en ? "en_US" : "ru_RU"); f.dateFormat = "d MMMM"
    return f.string(from: date)
}

private func groupByDay<T>(_ items: [T], _ date: (T) -> Date) -> [(String, [T])] {
    var order: [String] = []; var map: [String: [T]] = [:]
    for it in items {
        let k = dayLabel(date(it))
        if map[k] == nil { map[k] = []; order.append(k) }
        map[k]?.append(it)
    }
    return order.map { ($0, map[$0] ?? []) }
}

private func libraryColumn<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
    }
    .background(Color.pCanvas)
}

/// Same column, but exposes a ScrollViewProxy so a view can scroll to a tagged row (e.g. the
/// tasks-menu deep-link scrolling to a specific task).
private func libraryColumn<C: View>(@ViewBuilder _ content: @escaping (ScrollViewProxy) -> C) -> some View {
    ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content(proxy) }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 40)
        }
        .background(Color.pCanvas)
    }
}

// MARK: - Tasks (aggregator across meetings)

struct TasksView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var tasks = TaskStore.shared
    @State private var flash: UUID?

    var body: some View {
        libraryColumn { (proxy: ScrollViewProxy) in
            let open = tasks.tasks.filter { !$0.done }
            let done = tasks.tasks.filter { $0.done }
            SectionLabel(text: L("Открытые", "Open"))
            if open.isEmpty { emptyLine(L("Задачи появятся из встреч или добавьте вручную.", "Tasks will appear from meetings, or add them manually.")) }
            ForEach(open) { row($0) }
            addTaskRow
            if !done.isEmpty {
                HStack {
                    SectionLabel(text: L("Завершено", "Done"))
                    Spacer()
                    Button(L("Очистить", "Clear")) { tasks.clearDone() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                }.padding(.top, 24)
                ForEach(done) { row($0) }
            }
            // Deep-link from the tasks menu-bar: scroll to + flash the target task (proxy in scope).
            Color.clear.frame(height: 0)
                .onChange(of: store.pendingOpenTaskId) { _, id in scrollTo(id, proxy) }
                .onAppear { scrollTo(store.pendingOpenTaskId, proxy) }
        }
    }

    @ViewBuilder private func row(_ t: TaskItem) -> some View {
        TaskCard(task: t)
            .id(t.id)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(flash == t.id ? Color.pAccent.opacity(0.12) : Color.clear)
                    .padding(.horizontal, -8)
            )
    }

    private func scrollTo(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {   // let the list lay out first
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        flash = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if flash == id { flash = nil } }
        store.pendingOpenTaskId = nil
    }

    @State private var adding = false
    @State private var newText = ""

    private var addTaskRow: some View {
        Group {
            if adding {
                HStack(spacing: 12) {
                    TaskCheck(done: false)
                    TextField(L("Новая задача", "New task"), text: $newText).textFieldStyle(.plain).font(.system(size: 14))
                        .onSubmit { commitAdd() }
                    Button(L("Добавить", "Add")) { commitAdd() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.pAccent)
                }
                .padding(.horizontal, 4).frame(minHeight: 44)
            } else {
                Button { adding = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(PFont.secondary).foregroundStyle(Color.pAccent).frame(width: 16)
                        Text(L("Добавить задачу", "Add task")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                    }.padding(.horizontal, 4).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private func commitAdd() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { tasks.addManual(text: t) }
        newText = ""; adding = false
    }

    private func emptyLine(_ s: String) -> some View {
        Text(s).font(PFont.secondary).foregroundStyle(Color.pInk3).padding(.vertical, 8)
    }
}

/// A task row that expands into a full editor: title, checklist sub-items, owner, due, note, delete.
struct TaskCard: View {
    let task: TaskItem
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    @State private var expanded = false
    @State private var newSub = ""
    // local edit buffers so store writes don't fight the text cursor
    @State private var title = ""
    @State private var owner = ""
    @State private var due = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { detail.padding(.leading, 44).padding(.trailing, 4).padding(.bottom, 10) }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(expanded ? Color.pRail : Color.clear))
        .overlay(alignment: .bottom) { if !expanded { Rectangle().fill(Color.pLine2).frame(height: 1).padding(.leading, 44) } }
        .onChange(of: expanded) { _, e in if e { title = task.text; owner = task.owner ?? ""; due = task.due ?? ""; note = task.notes } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { store.toggle(task.id) } label: {
                TaskCheck(done: task.done).frame(width: 30, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.text).font(.system(size: 14))
                        .foregroundStyle(task.done ? Color.pInk3 : Color.pInk1)
                        .strikethrough(task.done, color: Color.pInk3)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    let p = task.subtaskProgress
                    if sourceTitle != nil || p.total > 0 {
                        HStack(spacing: 6) {
                            if let src = sourceTitle { Text(src).font(.system(size: 11.5)).foregroundStyle(Color.pInk3) }
                            if p.total > 0 { Text("· \(p.done)/\(p.total)").font(.system(size: 11.5)).foregroundStyle(Color.pInk3) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let o = task.owner, !o.isEmpty { Avatar(initials: String(o.prefix(2)).uppercased()) }
            if let d = task.due, !d.isEmpty { Text(d).font(PFont.mono).foregroundStyle(task.done ? Color.pInk3 : Color.pAccent) }
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.pInk3)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
        .frame(minHeight: 44)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L("Название", "Title"), $title) { store.edit(task.id) { $0.text = title } }

            // checklist
            ForEach(task.subtasks) { sub in
                HStack(spacing: 10) {
                    Button { store.edit(task.id) { if let i = $0.subtasks.firstIndex(where: { $0.id == sub.id }) { $0.subtasks[i].done.toggle() } } } label: {
                        TaskCheck(done: sub.done).frame(width: 24, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(sub.text).font(PFont.secondary).foregroundStyle(sub.done ? Color.pInk3 : Color.pInk1).strikethrough(sub.done, color: Color.pInk3)
                    Spacer()
                    Button { store.edit(task.id) { $0.subtasks.removeAll { $0.id == sub.id } } } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Color.pInk3)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L("Удалить подпункт", "Delete subtask"))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.pAccent).frame(width: 16)
                TextField(L("Подпункт", "Subtask"), text: $newSub).textFieldStyle(.plain).font(PFont.secondary).onSubmit { addSub() }
            }

            HStack(spacing: 10) {
                field(L("Исполнитель", "Owner"), $owner) { store.edit(task.id) { $0.owner = owner.isEmpty ? nil : owner } }
                field(L("Срок", "Due"), $due) { store.edit(task.id) { $0.due = due.isEmpty ? nil : due } }
            }
            field(L("Заметка", "Note"), $note) { store.edit(task.id) { $0.notes = note } }

            Button { store.remove(task.id) } label: {
                HStack(spacing: 6) { Image(systemName: "trash"); Text(L("Удалить задачу", "Delete task")) }
                    .font(.system(size: 12)).foregroundStyle(Color.pDanger)
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }

    private func addSub() {
        let t = newSub.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        store.edit(task.id) { $0.subtasks.append(SubTask(text: t)) }; newSub = ""
    }
    private func field(_ placeholder: String, _ binding: Binding<String>, commit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: binding, onCommit: commit)
            .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pButtonBorder, lineWidth: 1))
            .onChange(of: binding.wrappedValue) { _, _ in commit() }
    }
    private var sourceTitle: String? {
        guard let sid = task.sessionId, let s = sessions.sessions.first(where: { $0.id == sid }) else { return nil }
        return s.title
    }
}

// MARK: - All records

enum RecordFilter: String, CaseIterable, Identifiable {
    case all, meeting, dict
    var id: String { rawValue }
    var title: String { self == .all ? L("Все", "All") : self == .meeting ? L("Встречи", "Meetings") : L("Диктовки", "Dictations") }
    func matches(_ s: SessionRecord) -> Bool {
        switch self { case .all: return true; case .meeting: return s.kind == .meeting; case .dict: return s.kind == .dictation }
    }
    var sessionFilter: SessionFilter {
        switch self { case .all: return .all; case .meeting: return .meetings; case .dict: return .dictation }
    }
}

/// «Записи» — meetings + dictations in one filtered list (spec §5.1). One object type, two origins.
struct RecordsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var sessions = SessionStore.shared
    var onOpen: (UUID) -> Void
    @State private var filter: RecordFilter = .all

    var body: some View {
        let all = sessions.sessions
        let shown = all.filter { filter.matches($0) }
        let counts: [RecordFilter: Int] = [
            .all: all.count,
            .meeting: all.filter { $0.kind == .meeting }.count,
            .dict: all.filter { $0.kind == .dictation }.count,
        ]
        return libraryColumn {
            if all.count > 1 || filter != .all {
                RecordFilterBar(filter: $filter, counts: counts).padding(.bottom, 16)
            }
            if shown.isEmpty {
                Text(all.isEmpty && !store.isRecording ? L("Пока нет записей.", "No records yet.")
                     : filter == .meeting ? L("Встреч пока нет.", "No meetings yet.") : filter == .dict ? L("Диктовок пока нет.", "No dictations yet.") : L("Пока нет записей.", "No records yet."))
                    .font(PFont.secondary).foregroundStyle(Color.pInk3).padding(.vertical, 8)
            }
            ForEach(groupByDay(shown, { $0.date }), id: \.0) { day, items in
                SectionLabel(text: day).padding(.bottom, 4)
                ForEach(items) { s in RecordRow(s: s, open: { onOpen(s.id) }) }
                .padding(.bottom, 10)
            }
        }
    }
}

/// One record row — same shape for both types; the left marker distinguishes them.
private struct RecordRow: View {
    let s: SessionRecord
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                marker
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 14)).foregroundStyle(Color.pInk1).lineLimit(1)
                    Text(meta).font(PFont.mono).foregroundStyle(Color.pInk3)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.pSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
    @ViewBuilder private var marker: some View {
        if s.kind == .meeting {
            RoundedRectangle(cornerRadius: 3).fill(Color.pAccent).frame(width: 9, height: 9)
        } else {
            Circle().strokeBorder(Color.pInk3, lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
    private var meta: String {
        let t = SessionStore.time.string(from: s.date)
        switch s.kind {
        case .meeting:
            let d = s.durationSec.map { L(" · \(Int(($0 / 60).rounded())) мин", " · \(Int(($0 / 60).rounded())) min") } ?? ""
            return L("Встреча · \(t)\(d)", "Meeting · \(t)\(d)")
        case .dictation:
            let w = s.title.split { $0 == " " || $0 == "\n" }.count
            return L("Диктовка · \(t) · \(w) слов", "Dictation · \(t) · \(w) words")
        }
    }
}

/// Premium segmented filter — a raised pill slides under the active segment; each shows its count.
struct RecordFilterBar: View {
    @Binding var filter: RecordFilter
    let counts: [RecordFilter: Int]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RecordFilter.allCases) { f in
                let active = filter == f
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { filter = f }
                } label: {
                    HStack(spacing: 6) {
                        Text(f.title).font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.pInk1 : Color.pInk2)
                        if let c = counts[f], c > 0 {
                            Text("\(c)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(active ? Color.pAccent : Color.pInk3)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 8).fill(Color.pCard)
                                .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(f.title)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(Color.pField)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

struct TypeBadge: View {
    let meeting: Bool
    var body: some View {
        Text(meeting ? L("встреча", "meeting") : L("диктовка", "dictation"))
            .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.3)
            .foregroundStyle(meeting ? Color.pAccent : Color.pInk2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((meeting ? Color.pAccent.opacity(0.15) : Color.pSelection))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Glossary (in the main window)

struct GlossaryView: View {
    @ObservedObject var glossary = GlossaryStore.shared
    @State private var editing: GlossaryTerm?
    @State private var showAdd = false

    var body: some View {
        libraryColumn {
            Text(L("Правильные написания терминов и имён — и в расшифровке, и в саммари.", "Correct spellings of terms and names — in both the transcript and the summary."))
                .font(PFont.secondary).foregroundStyle(Color.pInk2).padding(.bottom, 24)

            SectionLabel(text: L("Как применять", "How it's applied")).padding(.bottom, 8)
            GlossCard {
                glossToggleRow(L("Локальная коррекция (офлайн)", "Local correction (offline)"),
                               L("Мгновенно правит финалы и диктовки — детерминированно, без сети", "Instantly fixes finals and dictations — deterministic, offline"),
                               $glossary.correctionEnabled)
                Hairline(color: .pLine2)
                glossToggleRow(L("Подставлять в промпт LLM", "Add to LLM prompt"),
                               L("Глоссарий уходит в системный промпт для Итога и вопросов", "The glossary is added to the system prompt for Summary and questions"),
                               $glossary.llmInjectEnabled)
            }

            SectionLabel(text: L("Термины · \(glossary.terms.count)", "Terms · \(glossary.terms.count)")).padding(.top, 22).padding(.bottom, 8)
            GlossCard {
                ForEach(Array(glossary.terms.enumerated()), id: \.element.id) { idx, term in
                    if idx > 0 { Hairline(color: .pLine2) }
                    termRow(term)
                }
                Hairline(color: .pLine2)
                Button { showAdd = true } label: {
                    HStack(spacing: 10) {
                        Text("+").font(PFont.body).foregroundStyle(Color.pAccent)
                        Text(L("Добавить термин", "Add term")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                    }.padding(.horizontal, 16).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            SectionLabel(text: L("Обучение на лету", "Learning on the fly")).padding(.top, 22).padding(.bottom, 8)
            GlossCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Выдели слово в транскрипте → «Добавить в словарь» — как в Wispr.", "Select a word in the transcript → \"Add to glossary\" — like Wispr."))
                        .font(PFont.secondary).foregroundStyle(Color.pInk2)
                    Text(L("Услышанное слово попадёт в варианты, каноничное можно поправить.", "The heard word becomes a variant; you can adjust the canonical form."))
                        .font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editing) { term in
            GlossaryEditor(term: term, onSave: { glossary.update($0) }, onDelete: { glossary.remove(term.id) })
        }
        .sheet(isPresented: $showAdd) {
            GlossaryEditor(term: GlossaryTerm(canonical: ""), onSave: { glossary.add($0) }, onDelete: nil)
        }
    }

    private func glossToggleRow(_ title: String, _ sub: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PFont.secondary).foregroundStyle(Color.pInk1)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Color.pInk3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ParleyToggle(on: binding)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
    }

    private func termRow(_ term: GlossaryTerm) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ParleyToggle(on: Binding(get: { term.enabled }, set: { var t = term; t.enabled = $0; glossary.update(t) })).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(term.canonical).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1)
                if !term.variants.isEmpty {
                    FlowChips(term.variants)
                }
            }
            Spacer(minLength: 8)
            Button { editing = term } label: {
                Image(systemName: "pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk2)
                    .frame(width: 30, height: 30)
                    .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pButtonBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Variant chips that actually wrap onto multiple lines within the card width.
struct FlowChips: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { v in
                Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.pInk2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.pLine, lineWidth: 1))
            }
        }
    }
}

/// A simple left-to-right wrapping layout (chips, tags) — flows children onto new rows as width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width { x = 0; y += rowH + lineSpacing; rowH = 0 }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

private struct GlossCard<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

/// Add/edit a glossary term.
struct GlossaryEditor: View {
    @State var term: GlossaryTerm
    var onSave: (GlossaryTerm) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var variantsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onDelete == nil ? L("Новый термин", "New term") : L("Термин", "Term")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Каноничное написание", "Canonical spelling")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                field($term.canonical, "Kubernetes")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Варианты (через запятую)", "Variants (comma-separated)")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                field($variantsText, L("кубернетис, кубернетес", "kubernetis, kubernetes"))
            }
            HStack {
                if let onDelete {
                    Button(L("Удалить", "Delete")) { onDelete(); dismiss() }.buttonStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pDanger)
                }
                Spacer()
                Button(L("Отмена", "Cancel")) { dismiss() }.buttonStyle(PBorderedButtonStyle())
                Button(L("Сохранить", "Save")) {
                    term.variants = variantsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !term.canonical.trimmingCharacters(in: .whitespaces).isEmpty { onSave(term) }
                    dismiss()
                }.buttonStyle(PPrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 420)
        .background(Color.pCanvas)
        .onAppear { variantsText = term.variants.joined(separator: ", ") }
    }
    private func field(_ text: Binding<String>, _ placeholder: String) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
            .frame(height: 32).padding(.horizontal, 10)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pButtonBorder, lineWidth: 1))
    }
}

// MARK: - Команды (voice command registry)

struct CommandsView: View {
    @ObservedObject private var store = CommandStore.shared

    var body: some View {
        libraryColumn {
            Text(L("Скажи во время диктовки «открой почту» / «запусти VPN» — ZVON выполнит команду. «Слово» — это то, что ты произносишь после глагола (открой / запусти / включи / покажи). Сайты открываются в браузере по умолчанию.", "Say \"open mail\" / \"launch VPN\" during dictation — ZVON runs the command. The \"word\" is what you say after the verb (open / launch / turn on / show). Sites open in your default browser."))
                .font(PFont.secondary).foregroundStyle(Color.pInk3)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)

            SectionLabel(text: L("Команды · \(store.commands.count)", "Commands · \(store.commands.count)")).padding(.bottom, 8)
            ForEach(store.commands) { c in commandRow(c) }

            Button { store.addBlank() } label: {
                HStack(spacing: 8) { Image(systemName: "plus"); Text(L("Добавить команду", "Add command")) }
                    .font(PFont.secondary).foregroundStyle(Color.pAccent)
            }
            .buttonStyle(.plain).padding(.top, 10)
        }
    }

    private func commandRow(_ c: CommandItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: c.kind.icon).font(.system(size: 13)).foregroundStyle(Color.pAccent).frame(width: 18)
                field(L("Слово, напр. «почта»", "Word, e.g. \"mail\""), str(c.id, \.phrase))
                kindMenu(c)
                Button { store.remove(c.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Color.pInk3)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            field(L("Ещё слова через запятую (gmail, мейл)", "More words, comma-separated (gmail, mail)"), aliasStr(c.id))
            HStack(spacing: 10) {
                if c.kind == .openApp { AppPickerField(value: str(c.id, \.value)) } else { field(c.kind.valueLabel, str(c.id, \.value)) }
                Toggle("", isOn: bool(c.id, \.needsConfirm)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Text(L("подтв.", "confirm")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
            }
        }
        .padding(12)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pLine, lineWidth: 1))
        .padding(.bottom, 10)
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.pInk1)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func kindMenu(_ c: CommandItem) -> some View {
        Menu {
            ForEach(CommandItem.Kind.allCases) { k in Button(k.title) { store.update(c.id) { $0.kind = k } } }
        } label: {
            HStack(spacing: 4) { Text(c.kind.title); Image(systemName: "chevron.down").font(.system(size: 9)) }
                .font(.system(size: 12)).foregroundStyle(Color.pInk2)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pLine, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // Bindings that read the live item and write through the store (persist on every edit).
    private func str(_ id: UUID, _ kp: WritableKeyPath<CommandItem, String>) -> Binding<String> {
        Binding(get: { store.commands.first { $0.id == id }?[keyPath: kp] ?? "" },
                set: { v in store.update(id) { $0[keyPath: kp] = v } })
    }
    private func bool(_ id: UUID, _ kp: WritableKeyPath<CommandItem, Bool>) -> Binding<Bool> {
        Binding(get: { store.commands.first { $0.id == id }?[keyPath: kp] ?? false },
                set: { v in store.update(id) { $0[keyPath: kp] = v } })
    }
    private func aliasStr(_ id: UUID) -> Binding<String> {
        Binding(get: { store.commands.first { $0.id == id }?.aliases.joined(separator: ", ") ?? "" },
                set: { s in store.update(id) { $0.aliases = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } })
    }
}

/// Searchable app picker: shows the current app; click opens a popover with a search field + the
/// filtered list of installed apps — start typing to narrow it, click a result to pick. Guarantees
/// the command points at a real bundle (no typos → the app always opens).
struct AppPickerField: View {
    @Binding var value: String
    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button { query = ""; open = true } label: {
            HStack(spacing: 6) {
                Text(value.isEmpty ? L("Выбрать приложение", "Choose app") : value)
                    .foregroundStyle(value.isEmpty ? Color.pInk3 : Color.pInk1).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Color.pInk3)
            }
            .font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 30).padding(.horizontal, 10)
            .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        let apps = CommandStore.installedApps()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? apps : apps.filter { $0.lowercased().contains(q) }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.pInk3)
                TextField(L("Поиск приложения", "Search app"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.pInk1).focused($searchFocused)
            }
            .padding(9).background(Color.pField)
            Divider().overlay(Color.pLine)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text(L("Ничего не найдено", "No matches")).font(.system(size: 12)).foregroundStyle(Color.pInk3).padding(10)
                    }
                    ForEach(matches, id: \.self) { name in
                        Button { value = name; open = false } label: {
                            Text(name).font(.system(size: 13)).foregroundStyle(Color.pInk1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(PopRowButtonStyle())
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
        .background(Color.pCard)
        .onAppear { searchFocused = true }
    }
}

/// A plain list-row button with a subtle hover highlight (for the app picker popover).
private struct PopRowButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover ? Color.pAccent.opacity(0.12) : Color.clear)
            .onHover { hover = $0 }
    }
}
