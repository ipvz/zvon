import SwiftUI

/// Which view the main pane shows — switched from the sidebar nav (single window).
enum MainView: String, CaseIterable, Identifiable {
    case meeting, records, tasks, gloss
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meeting: return "Встреча"
        case .records: return "Записи"
        case .tasks:   return "Задачи"
        case .gloss:   return "Словарь"
        }
    }
    var icon: String {
        switch self {
        case .meeting: return "waveform"
        case .records: return "rectangle.stack"
        case .tasks:   return "checklist"
        case .gloss:   return "character.book.closed"
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
    if cal.isDateInToday(date) { return "Сегодня" }
    if cal.isDateInYesterday(date) { return "Вчера" }
    let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"
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
            SectionLabel(text: "Открытые")
            if open.isEmpty { emptyLine("Задачи появятся из встреч или добавьте вручную.") }
            ForEach(open) { row($0) }
            addTaskRow
            if !done.isEmpty {
                HStack {
                    SectionLabel(text: "Завершено")
                    Spacer()
                    Button("Очистить") { tasks.clearDone() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.pInk3)
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
                    TextField("Новая задача", text: $newText).textFieldStyle(.plain).font(.system(size: 14))
                        .onSubmit { commitAdd() }
                    Button("Добавить") { commitAdd() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.pAccent)
                }
                .padding(.horizontal, 4).frame(minHeight: 44)
            } else {
                Button { adding = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(PFont.secondary).foregroundStyle(Color.pAccent).frame(width: 16)
                        Text("Добавить задачу").font(PFont.secondary).foregroundStyle(Color.pInk3)
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
            field("Название", $title) { store.edit(task.id) { $0.text = title } }

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
                    }.buttonStyle(.plain).accessibilityLabel("Удалить подпункт")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.pAccent).frame(width: 16)
                TextField("Подпункт", text: $newSub).textFieldStyle(.plain).font(PFont.secondary).onSubmit { addSub() }
            }

            HStack(spacing: 10) {
                field("Исполнитель", $owner) { store.edit(task.id) { $0.owner = owner.isEmpty ? nil : owner } }
                field("Срок", $due) { store.edit(task.id) { $0.due = due.isEmpty ? nil : due } }
            }
            field("Заметка", $note) { store.edit(task.id) { $0.notes = note } }

            Button { store.remove(task.id) } label: {
                HStack(spacing: 6) { Image(systemName: "trash"); Text("Удалить задачу") }
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
    var title: String { self == .all ? "Все" : self == .meeting ? "Встречи" : "Диктовки" }
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
                Text(all.isEmpty && !store.isRecording ? "Пока нет записей."
                     : filter == .meeting ? "Встреч пока нет." : filter == .dict ? "Диктовок пока нет." : "Пока нет записей.")
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
            let d = s.durationSec.map { " · \(Int(($0 / 60).rounded())) мин" } ?? ""
            return "Встреча · \(t)\(d)"
        case .dictation:
            let w = s.title.split { $0 == " " || $0 == "\n" }.count
            return "Диктовка · \(t) · \(w) слов"
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
        Text(meeting ? "встреча" : "диктовка")
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
            Text("Правильные написания терминов и имён — и в расшифровке, и в саммари.")
                .font(PFont.secondary).foregroundStyle(Color.pInk2).padding(.bottom, 24)

            SectionLabel(text: "Как применять").padding(.bottom, 8)
            GlossCard {
                glossToggleRow("Локальная коррекция (офлайн)",
                               "Мгновенно правит финалы и диктовки — детерминированно, без сети",
                               $glossary.correctionEnabled)
                Hairline(color: .pLine2)
                glossToggleRow("Подставлять в промпт LLM",
                               "Глоссарий уходит в системный промпт для Итога и вопросов",
                               $glossary.llmInjectEnabled)
            }

            SectionLabel(text: "Термины · \(glossary.terms.count)").padding(.top, 22).padding(.bottom, 8)
            GlossCard {
                ForEach(Array(glossary.terms.enumerated()), id: \.element.id) { idx, term in
                    if idx > 0 { Hairline(color: .pLine2) }
                    termRow(term)
                }
                Hairline(color: .pLine2)
                Button { showAdd = true } label: {
                    HStack(spacing: 10) {
                        Text("+").font(PFont.body).foregroundStyle(Color.pAccent)
                        Text("Добавить термин").font(PFont.secondary).foregroundStyle(Color.pInk3)
                    }.padding(.horizontal, 16).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            SectionLabel(text: "Обучение на лету").padding(.top, 22).padding(.bottom, 8)
            GlossCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Выдели слово в транскрипте → «Добавить в словарь» — как в Wispr.")
                        .font(PFont.secondary).foregroundStyle(Color.pInk2)
                    Text("Услышанное слово попадёт в варианты, каноничное можно поправить.")
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
            Text(onDelete == nil ? "Новый термин" : "Термин").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Каноничное написание").font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                field($term.canonical, "Kubernetes")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Варианты (через запятую)").font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                field($variantsText, "кубернетис, кубернетес")
            }
            HStack {
                if let onDelete {
                    Button("Удалить") { onDelete(); dismiss() }.buttonStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pDanger)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(PBorderedButtonStyle())
                Button("Сохранить") {
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
