import Foundation

/// A «Пространство» — a named collection meetings can be tagged into (project / client / team).
/// Membership is many-to-many (a meeting can live in several spaces), so this is a label, not a folder.
struct Space: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorHex: String                 // accent dot / rail marker
    var meetingIds: [UUID] = []          // most-recent-first; kept unique on insert
    var createdAt = Date()
    var summary: String?                 // cached rolled-up digest ("summary of summaries")
    var summaryAt: Date?                 // when the digest was last generated
}

@MainActor
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore()
    @Published private(set) var spaces: [Space] = []

    private static let key = "spaces"

    /// New-space swatch palette — teal-forward (brand) then a full spread; the editor also offers a
    /// system colour-picker for anything off-palette.
    static let palette = [
        "#00A7A7", "#12B5C9", "#3B82F6", "#6366F1", "#8B5CF6", "#B06FE6", "#D946A6", "#E0607E",
        "#EF5350", "#E0894A", "#F5A524", "#C9A227", "#84A83C", "#3CA877", "#2FB08A", "#64748B",
    ]

    init() { load() }

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func create(name: String, colorHex: String? = nil) -> Space {
        let color = colorHex ?? Self.palette[spaces.count % Self.palette.count]
        let s = Space(name: cleanName(name), colorHex: color)
        spaces.append(s); save(); return s
    }

    func rename(_ id: UUID, _ name: String) { mutate(id) { $0.name = cleanName(name) } }
    func recolor(_ id: UUID, _ hex: String) { mutate(id) { $0.colorHex = hex } }
    func delete(_ id: UUID) { spaces.removeAll { $0.id == id }; save() }
    func setSummary(_ id: UUID, _ text: String) { mutate(id) { $0.summary = text; $0.summaryAt = Date() } }

    /// A digest is stale if any member meeting is newer than when it was built (or membership changed).
    func summaryStale(_ id: UUID, latestMemberDate: Date?) -> Bool {
        guard let sp = space(id), let at = sp.summaryAt else { return false }
        guard let latest = latestMemberDate else { return false }
        return latest > at
    }

    func contains(_ spaceId: UUID, meeting: UUID) -> Bool { space(spaceId)?.meetingIds.contains(meeting) ?? false }
    func spacesFor(meeting id: UUID) -> [Space] { spaces.filter { $0.meetingIds.contains(id) } }

    /// Add if absent, remove if present — the checkmark toggle used by the record context menu.
    func toggle(meeting: UUID, in spaceId: UUID) {
        mutate(spaceId) { s in
            if let i = s.meetingIds.firstIndex(of: meeting) { s.meetingIds.remove(at: i) }
            else { s.meetingIds.insert(meeting, at: 0) }
        }
    }

    func add(meeting: UUID, to spaceId: UUID) {
        mutate(spaceId) { if !$0.meetingIds.contains(meeting) { $0.meetingIds.insert(meeting, at: 0) } }
    }

    /// Keep membership honest when a meeting is deleted from the library.
    func purge(meeting id: UUID) {
        var touched = false
        for i in spaces.indices where spaces[i].meetingIds.contains(id) {
            spaces[i].meetingIds.removeAll { $0 == id }; touched = true
        }
        if touched { save() }
    }

    // MARK: Internals

    private func cleanName(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func mutate(_ id: UUID, _ f: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        f(&spaces[i]); save()
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let items = try? JSONDecoder().decode([Space].self, from: d) else { return }
        spaces = items
    }

    private func save() {
        if let d = try? JSONEncoder().encode(spaces) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
