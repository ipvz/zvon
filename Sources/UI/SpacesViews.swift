import SwiftUI
import AppKit

// MARK: - Пространства (grouping of meetings into projects / clients)

/// Parse "#RRGGBB" → Color; falls back to the brand accent on anything malformed.
func spaceColor(_ hex: String) -> Color {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt64(s, radix: 16) else { return .pAccent }
    return Color(red: Double((v >> 16) & 0xFF) / 255,
                 green: Double((v >> 8) & 0xFF) / 255,
                 blue: Double(v & 0xFF) / 255)
}

/// Color → "#RRGGBB" for the custom colour-picker.
func spaceHex(_ c: Color) -> String {
    let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
    let r = Int((ns.redComponent * 255).rounded())
    let g = Int((ns.greenComponent * 255).rounded())
    let b = Int((ns.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
}

private let spaceDayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMMM"; return f
}()
private func spaceDateMeta(_ s: SessionRecord) -> String {
    let f = spaceDayFmt; f.locale = Locale(identifier: _uiLang == .en ? "en_US" : "ru_RU")
    let day = f.string(from: s.date)
    if let d = s.durationSec { return "\(day) · \(Int((d / 60).rounded())) \(L("мин", "min"))" }
    return day
}

// MARK: Overview grid

struct SpacesView: View {
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var loc = L11n.shared
    var onOpen: (UUID) -> Void

    @State private var editing: Space?
    @State private var creating = false

    var body: some View {
        libraryColumn {
            Text(L("Группируй встречи по проектам и клиентам. Дальше — сводка, общий список решений и задач и вопросы по всей группе.",
                   "Group meetings by project or client. Then get a digest, one rolled-up list of decisions and tasks, and questions across the whole group."))
                .font(PFont.secondary).foregroundStyle(Color.pInk3)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)

            HStack {
                SectionLabel(text: L("Пространства · \(store.spaces.count)", "Spaces · \(store.spaces.count)"))
                Spacer()
                Button { creating = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(L("Новое", "New")).font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(Color.pAccent)
                }.buttonStyle(.plain)
            }.padding(.bottom, 10)

            if store.spaces.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(store.spaces) { sp in
                        SpaceCard(space: sp, meetings: members(sp),
                                  onOpen: { onOpen(sp.id) }, onEdit: { editing = sp })
                    }
                }
            }
        }
        .sheet(item: $editing) { sp in SpaceEditor(space: sp) }
        .sheet(isPresented: $creating) { SpaceEditor(space: nil) }
    }

    private func members(_ sp: Space) -> [SessionRecord] {
        sessions.sessions.filter { sp.meetingIds.contains($0.id) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Пока нет пространств.", "No spaces yet."))
                .font(PFont.secondary).foregroundStyle(Color.pInk2)
            Button { creating = true } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text(L("Создать пространство", "Create a space")) }
            }.buttonStyle(PPrimaryButtonStyle())
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

private struct SpaceCard: View {
    let space: Space
    let meetings: [SessionRecord]
    var onOpen: () -> Void
    var onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(spaceColor(space.colorHex)).frame(width: 9, height: 9)
                    Text(space.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(meetings.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.pInk3)
                }
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)

                Hairline(color: .pLine2)

                VStack(alignment: .leading, spacing: 5) {
                    if meetings.isEmpty {
                        Text(L("Пусто — добавьте встречи", "Empty — add meetings"))
                            .font(.system(size: 12)).foregroundStyle(Color.pInk3)
                    } else {
                        ForEach(meetings.prefix(3)) { m in
                            HStack(spacing: 7) {
                                Circle().fill(Color.pInk3.opacity(0.5)).frame(width: 3, height: 3)
                                Text(m.title).font(.system(size: 12.5)).foregroundStyle(Color.pInk2).lineLimit(1)
                            }
                        }
                        if meetings.count > 3 {
                            Text(L("ещё \(meetings.count - 3)", "\(meetings.count - 3) more"))
                                .font(.system(size: 11.5)).foregroundStyle(Color.pInk3).padding(.leading, 10)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? Color.pAccent.opacity(0.55) : Color.pLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Переименовать / цвет", "Rename / colour"), action: onEdit)
        }
    }
}

// MARK: Detail

private enum SpaceTab: CaseIterable { case summary, questions, meetings, decisions, tasks
    var title: String {
        switch self {
        case .summary:   return L("Сводка", "Digest")
        case .questions: return L("Вопросы", "Ask")
        case .meetings:  return L("Встречи", "Meetings")
        case .decisions: return L("Решения", "Decisions")
        case .tasks:     return L("Задачи", "Tasks")
        }
    }
}

struct SpaceDetailView: View {
    let spaceId: UUID
    var onOpenMeeting: (UUID) -> Void
    var onBack: () -> Void

    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var tasks = TaskStore.shared
    @ObservedObject private var loc = L11n.shared
    @EnvironmentObject private var tx: TranscriptStore   // LLM digest lives here

    @State private var tab: SpaceTab = .summary
    @State private var editing = false
    @State private var picking = false
    @State private var q = ""                            // search within the space
    @State private var copied = false
    @State private var askText = ""                      // «Вопросы» input

    private var space: Space? { store.space(spaceId) }
    private var members: [SessionRecord] {
        guard let sp = space else { return [] }
        return sessions.sessions.filter { sp.meetingIds.contains($0.id) }
    }
    /// Members narrowed by the in-space search (title or transcript).
    private var searchedMembers: [SessionRecord] {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return members }
        return members.filter { $0.title.lowercased().contains(query) || ($0.transcript?.lowercased().contains(query) ?? false) }
    }
    private var latestMemberDate: Date? { members.map(\.date).max() }

    var body: some View {
        libraryColumn {
            if let sp = space {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(L("Пространства", "Spaces")).font(.system(size: 12))
                    }.foregroundStyle(Color.pInk3)
                }.buttonStyle(.plain).padding(.bottom, 12)

                HStack(spacing: 10) {
                    Circle().fill(spaceColor(sp.colorHex)).frame(width: 12, height: 12)
                    Text(sp.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.pInk1)
                    Button { editing = true } label: {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.pInk3)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer()
                }.padding(.bottom, 12)

                statsStrip.padding(.bottom, 14)

                tabBar.padding(.bottom, 12)

                if tab == .meetings || tab == .decisions || tab == .tasks { searchField.padding(.bottom, 12) }

                switch tab {
                case .summary:   summaryTab
                case .questions: questionsTab
                case .meetings:  meetingsTab
                case .decisions: decisionsTab
                case .tasks:     tasksTab
                }
            } else {
                Text(L("Пространство удалено.", "Space deleted."))
                    .font(PFont.secondary).foregroundStyle(Color.pInk3)
            }
        }
        .sheet(isPresented: $editing) {
            if let sp = space { SpaceEditor(space: sp, onDeleted: onBack) }
        }
        .sheet(isPresented: $picking) { SpaceMeetingPicker(spaceId: spaceId) }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SpaceTab.allCases, id: \.self) { t in
                let on = tab == t
                Button { tab = t } label: {
                    Text(t.title).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.pAccent : Color.pInk2)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.pAccent.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // Statistics strip: meetings · total duration · date span --------------

    private var statsStrip: some View {
        let dur = members.compactMap { $0.durationSec }.reduce(0, +)
        return HStack(spacing: 0) {
            statCell("\(members.count)", L("встреч", "meetings"))
            statDivider
            statCell(durationText(dur), L("суммарно", "total"))
            statDivider
            statCell(rangeText, L("период", "span"))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }
    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(Color.pInk3)
        }.frame(maxWidth: .infinity).padding(.horizontal, 6)
    }
    private var statDivider: some View { Rectangle().fill(Color.pLine2).frame(width: 1, height: 30) }

    private func durationText(_ sec: Double) -> String {
        let m = Int((sec / 60).rounded())
        if m < 60 { return L("\(m) мин", "\(m) min") }
        let h = m / 60, r = m % 60
        return r == 0 ? L("\(h) ч", "\(h) h") : L("\(h) ч \(r) м", "\(h)h \(r)m")
    }
    private var rangeText: String {
        let ds = members.map(\.date).sorted()
        guard let first = ds.first, let last = ds.last else { return "—" }
        let f = spaceDayFmt; f.locale = Locale(identifier: _uiLang == .en ? "en_US" : "ru_RU")
        let a = f.string(from: first), b = f.string(from: last)
        return a == b ? a : "\(a) – \(b)"
    }

    // In-space search ------------------------------------------------------

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.pInk3)
            TextField(L("Поиск по пространству", "Search this space"), text: $q)
                .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.pInk3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine, lineWidth: 1))
    }

    // Сводка ("summary of summaries") --------------------------------------

    private var summaryTab: some View {
        let busy = tx.spaceSummarizing.contains(spaceId)
        let text = space?.summary
        let stale = store.summaryStale(spaceId, latestMemberDate: latestMemberDate)
        return VStack(alignment: .leading, spacing: 12) {
            if members.isEmpty {
                emptyLine(L("Добавьте встречи — и ZVON соберёт общую сводку по проекту.", "Add meetings — ZVON rolls them into a project digest."))
            } else if let text, !text.isEmpty {
                GroupCard {
                    digestBody(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    if let at = space?.summaryAt {
                        Text(L("Обновлено \(spaceStamp(at))", "Updated \(spaceStamp(at))")).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                    }
                    if stale { Text(L("· есть новые встречи", "· new meetings")).font(.system(size: 11)).foregroundStyle(Color.pAccent) }
                    Spacer()
                    Button { copyDigest(text) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                            Text(copied ? L("Скопировано", "Copied") : L("Копировать", "Copy")).font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(copied ? Color.pSuccess : Color.pInk2)
                    }.buttonStyle(.plain)
                    Button { tx.summarizeSpace(spaceId) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            Text(L("Обновить", "Refresh")).font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(busy ? Color.pInk3 : Color.pAccent)
                    }.buttonStyle(.plain).disabled(busy)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Сводка соберёт итоги всех встреч пространства в один связный дайджест: темы, прогресс, решения, следующие шаги.",
                           "The digest rolls every meeting's summary into one project brief: themes, progress, decisions, next steps."))
                        .font(PFont.secondary).foregroundStyle(Color.pInk2).fixedSize(horizontal: false, vertical: true)
                    Button { tx.summarizeSpace(spaceId) } label: {
                        HStack(spacing: 6) { Image(systemName: "sparkles"); Text(L("Собрать сводку", "Build digest")) }
                    }.buttonStyle(PPrimaryButtonStyle()).disabled(busy)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
            }

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Собираю сводку…", "Building digest…")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                }
            }
            if let e = tx.spaceSummaryError[spaceId] {
                Text(e).font(.system(size: 12)).foregroundStyle(Color.pDanger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func spaceStamp(_ d: Date) -> String {
        let f = spaceDayFmt; f.locale = Locale(identifier: _uiLang == .en ? "en_US" : "ru_RU")
        return "\(f.string(from: d)), \(SessionStore.time.string(from: d))"
    }

    // Вопросы (scoped Q&A over the space's meetings, with cited sources) --------

    private var questionsTab: some View {
        let state = tx.spaceAsks[spaceId]
        let busy = state?.asking == true
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(L("Спросить по пространству — «что решили по…»", "Ask this space — \"what did we decide about…\""), text: $askText)
                    .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
                    .frame(height: 34).padding(.horizontal, 12)
                    .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.pLine, lineWidth: 1))
                    .onSubmit(fireAsk)
                Button(action: fireAsk) {
                    Text(L("Спросить", "Ask")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.pOnAccent)
                        .padding(.horizontal, 16).frame(height: 34)
                        .background(Color.pAccent.opacity(canAsk ? 1 : 0.5)).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!canAsk)
            }

            if members.isEmpty {
                emptyLine(L("Добавьте встречи — и можно будет спрашивать по всей группе.", "Add meetings — then you can ask across the whole group."))
            }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Ищу по встречам пространства…", "Searching this space's meetings…")).font(PFont.secondary).foregroundStyle(Color.pInk3)
                }
            }
            if let e = state?.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Color.pDanger).fixedSize(horizontal: false, vertical: true)
            }
            if let answer = state?.answer {
                GroupCard {
                    Text(answer).font(.system(size: 13)).foregroundStyle(Color.pInk1).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                if let src = state?.sources, !src.isEmpty {
                    Text(L("Источники", "Sources")).font(.system(size: 10.5, weight: .medium)).tracking(0.5)
                        .foregroundStyle(Color.pInk3).padding(.top, 2)
                    FlowLayout(spacing: 7, lineSpacing: 7) {
                        ForEach(src) { s in
                            Button { onOpenMeeting(s.id) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.pAccent).frame(width: 4, height: 4)
                                    Text(s.title).font(.system(size: 11.5)).foregroundStyle(Color.pInk2).lineLimit(1)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.pField).clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.pLine, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    private var canAsk: Bool { !askText.trimmingCharacters(in: .whitespaces).isEmpty && !members.isEmpty && tx.spaceAsks[spaceId]?.asking != true }
    private func fireAsk() {
        guard canAsk else { return }
        tx.askSpace(spaceId, askText)
    }

    private func copyDigest(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    /// Render the plain-text digest as structured blocks: accent-ticked section headings, teal-bulleted
    /// lists with a bold lead-in, and airy paragraphs — instead of one flat wall of text.
    @ViewBuilder private func digestBody(_ text: String) -> some View {
        let blocks = Self.parseDigest(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                switch b {
                case .heading(let h):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.pAccent).frame(width: 3, height: 13)
                        Text(h).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.pInk1)
                    }
                    .padding(.top, i == 0 ? 0 : 18).padding(.bottom, 9)
                case .bullet(let t):
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(Color.pAccent.opacity(0.75)).frame(width: 4, height: 4).padding(.top, 7)
                        bulletText(t).font(.system(size: 12.5)).foregroundStyle(Color.pInk2)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.padding(.bottom, 7)
                case .para(let t):
                    Text(t).font(.system(size: 12.5)).foregroundStyle(Color.pInk2)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                }
            }
        }
    }

    /// Bold a short "Лейбл:" lead-in so bullets scan quickly.
    private func bulletText(_ t: String) -> Text {
        if let r = t.range(of: ": "), t.distance(from: t.startIndex, to: r.lowerBound) <= 24 {
            let head = String(t[..<r.lowerBound]), rest = String(t[r.upperBound...])
            return Text(head + ": ").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.pInk1) + Text(rest)
        }
        return Text(t)
    }

    enum DigestBlock { case heading(String), bullet(String), para(String) }
    static func parseDigest(_ text: String) -> [DigestBlock] {
        var out: [DigestBlock] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let f = line.first, "-–•*".contains(f) {
                out.append(.bullet(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line.count <= 64 && line.split(separator: " ").count <= 8 && !line.hasSuffix(".") {
                out.append(.heading(line.hasSuffix(":") ? String(line.dropLast()) : line))
            } else {
                out.append(.para(line))
            }
        }
        return out
    }

    // Встречи ------------------------------------------------------------

    private var meetingsTab: some View {
        let rows = searchedMembers
        return VStack(alignment: .leading, spacing: 0) {
            if members.isEmpty {
                emptyLine(L("Пока нет встреч. Добавьте существующие записи.", "No meetings yet. Add existing recordings."))
            } else if rows.isEmpty {
                emptyLine(L("Ничего не найдено.", "Nothing found."))
            } else {
                GroupCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                        if i > 0 { Hairline(color: .pLine2) }
                        Button { onOpenMeeting(m.id) } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(m.kind == .meeting ? Color.pAccent : Color.pInk3)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1).lineLimit(1)
                                    Text(spaceDateMeta(m)).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                                }
                                Spacer(minLength: 8)
                                Button { store.toggle(meeting: m.id, in: spaceId) } label: {
                                    Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Color.pInk3)
                                        .frame(width: 26, height: 26).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(L("Убрать из пространства", "Remove from space"))
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.pInk3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            addMeetingsButton.padding(.top, 12)
        }
    }

    private var addMeetingsButton: some View {
        Button { picking = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(PFont.secondary).foregroundStyle(Color.pAccent)
                Text(L("Добавить встречи", "Add meetings")).font(PFont.secondary).foregroundStyle(Color.pInk3)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // Решения ------------------------------------------------------------

    private var decisions: [(text: String, session: SessionRecord)] {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        return members.flatMap { s in (s.noteDecisions ?? []).map { (text: $0, session: s) } }
            .filter { query.isEmpty || $0.text.lowercased().contains(query) || $0.session.title.lowercased().contains(query) }
    }

    private var decisionsTab: some View {
        Group {
            if decisions.isEmpty {
                emptyLine(L("Решений пока нет — они собираются из «Итога» встреч группы.",
                            "No decisions yet — they're collected from the meetings' summaries."))
            } else {
                GroupCard {
                    ForEach(Array(decisions.enumerated()), id: \.offset) { i, d in
                        if i > 0 { Hairline(color: .pLine2) }
                        Button { onOpenMeeting(d.session.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color.pAccent).frame(width: 5, height: 5).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.text).font(.system(size: 13)).foregroundStyle(Color.pInk1)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(d.session.title).font(.system(size: 11)).foregroundStyle(Color.pInk3).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // Задачи -------------------------------------------------------------

    private var spaceTasks: [TaskItem] {
        guard let sp = space else { return [] }
        let ids = Set(sp.meetingIds)
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        return tasks.tasks.filter { t in
            guard let sid = t.sessionId, ids.contains(sid) else { return false }
            return query.isEmpty || t.text.lowercased().contains(query)
        }
    }

    private var tasksTab: some View {
        let open = spaceTasks.filter { !$0.done }
        let done = spaceTasks.filter { $0.done }
        return Group {
            if spaceTasks.isEmpty {
                emptyLine(L("Задач пока нет — появятся из встреч этого пространства.",
                            "No tasks yet — they'll appear from this space's meetings."))
            } else {
                GroupCard {
                    ForEach(Array(open.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Hairline(color: .pLine2) }
                        taskRow(t)
                    }
                    if !done.isEmpty {
                        ForEach(Array(done.enumerated()), id: \.element.id) { _, t in
                            Hairline(color: .pLine2); taskRow(t)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ t: TaskItem) -> some View {
        let src = t.sessionId.flatMap { id in sessions.sessions.first { $0.id == id }?.title }
        return HStack(alignment: .top, spacing: 10) {
            Button { tasks.toggle(t.id) } label: { TaskCheck(done: t.done) }.buttonStyle(.plain).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.text).font(.system(size: 13)).foregroundStyle(t.done ? Color.pInk3 : Color.pInk1)
                    .strikethrough(t.done, color: .pInk3).fixedSize(horizontal: false, vertical: true)
                let meta = [t.subtitle.isEmpty ? nil : t.subtitle, src].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundStyle(Color.pInk3).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyLine(_ s: String) -> some View {
        Text(s).font(PFont.secondary).foregroundStyle(Color.pInk3).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }
}

/// Card shell shared by the detail tabs — same tokens as the glossary/commands cards.
private struct GroupCard<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }
}

// MARK: Create / rename / recolour

struct SpaceEditor: View {
    let space: Space?
    var onDeleted: (() -> Void)?
    var onCreated: ((Space) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SpaceStore.shared

    @State private var name = ""
    @State private var color = SpaceStore.palette[0]
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(space == nil ? L("Новое пространство", "New space") : L("Пространство", "Space"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Название", "Name")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                TextField(L("Онбординг b2b", "b2b onboarding"), text: $name)
                    .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
                    .focused($nameFocused)
                    .frame(height: 32).padding(.horizontal, 10)
                    .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(nameFocused ? Color.pAccent : Color.pButtonBorder, lineWidth: 1))
                    .onSubmit(commit)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Цвет", "Colour")).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                FlowLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(SpaceStore.palette, id: \.self) { hex in
                        let on = hex == color
                        Circle().fill(spaceColor(hex)).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.pInk1.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-3))
                            .contentShape(Circle())
                            .onTapGesture { color = hex }
                    }
                }
                ColorPicker(selection: Binding(get: { spaceColor(color) }, set: { color = spaceHex($0) }),
                            supportsOpacity: false) {
                    Text(L("Свой цвет", "Custom colour")).font(.system(size: 12)).foregroundStyle(Color.pInk2)
                }
            }

            HStack {
                if space != nil {
                    Button(L("Удалить", "Delete")) {
                        if let id = space?.id { store.delete(id) }
                        dismiss(); onDeleted?()
                    }.buttonStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pDanger)
                }
                Spacer()
                Button(L("Отмена", "Cancel")) { dismiss() }.buttonStyle(PBorderedButtonStyle())
                Button(L("Сохранить", "Save"), action: commit).buttonStyle(PPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 420)
        .background(Color.pCanvas)
        .onAppear {
            if let sp = space { name = sp.name; color = sp.colorHex }
            DispatchQueue.main.async { nameFocused = true }   // cursor in the field so it's clearly empty & typeable
        }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let sp = space {
            store.rename(sp.id, n); store.recolor(sp.id, color)
        } else {
            let created = store.create(name: n, colorHex: color)   // MUST run unconditionally —
            onCreated?(created)                                     // `onCreated?(create())` would skip create() when the callback is nil
        }
        dismiss()
    }
}

// MARK: Add existing meetings to a space

struct SpaceMeetingPicker: View {
    let spaceId: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    @State private var query = ""
    @State private var filter: RecordFilter = .meeting

    private var rows: [SessionRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.sessions.filter { filter.matches($0) && (q.isEmpty || $0.title.lowercased().contains(q)) }
    }

    var body: some View {
        let all = sessions.sessions
        let counts: [RecordFilter: Int] = [
            .all: all.count,
            .meeting: all.filter { $0.kind == .meeting }.count,
            .dict: all.filter { $0.kind == .dictation }.count,
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Добавить записи", "Add recordings")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1)

            RecordFilterBar(filter: $filter, counts: counts)

            TextField(L("Поиск записи", "Search recordings"), text: $query)
                .textFieldStyle(.plain).font(PFont.secondary).foregroundStyle(Color.pInk1)
                .frame(height: 32).padding(.horizontal, 10)
                .background(Color.pField).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.pButtonBorder, lineWidth: 1))

            ScrollView {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(L("Ничего не найдено.", "Nothing found."))
                            .font(PFont.secondary).foregroundStyle(Color.pInk3).padding(.vertical, 16)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Hairline(color: .pLine2) }
                        let on = store.contains(spaceId, meeting: s.id)
                        Button { store.toggle(meeting: s.id, in: spaceId) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15)).foregroundStyle(on ? Color.pAccent : Color.pInk3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.pInk1).lineLimit(1)
                                    Text(spaceDateMeta(s)).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                                }
                                Spacer(minLength: 8)
                                TypeBadge(meeting: s.kind == .meeting)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 320)
            .background(Color.pRail).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))

            HStack {
                Spacer()
                Button(L("Готово", "Done")) { dismiss() }.buttonStyle(PPrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 460)
        .background(Color.pCanvas)
    }
}
