import Foundation
import SQLite3

/// Thin SQLite store for the meeting/dictation history. Uses the system libsqlite3 (`import SQLite3`)
/// — zero external dependencies, the engine already ships with macOS. Replaces the old
/// "one JSON blob in UserDefaults" scheme: single-row INSERT/DELETE instead of rewriting the whole
/// array on every save, an index on `date`, and no artificial record cap.
final class SessionDB {
    private var db: OpaquePointer?
    // SQLite wants to know whether the bound bytes outlive the call; TRANSIENT tells it to copy.
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { sqlite3_close(db); return nil }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS sessions(
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              date REAL NOT NULL,
              duration REAL,
              hasSummary INTEGER NOT NULL DEFAULT 0,
              transcript TEXT,
              noteSummary TEXT,
              noteDecisions TEXT,
              noteTopics TEXT
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions(date DESC);")
    }

    deinit { sqlite3_close(db) }

    var isEmpty: Bool {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions;", -1, &s, nil) == SQLITE_OK else { return true }
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) == 0 : true
    }

    func insert(_ r: SessionRecord) {
        let sql = """
            INSERT OR REPLACE INTO sessions
            (id,kind,title,date,duration,hasSummary,transcript,noteSummary,noteDecisions,noteTopics)
            VALUES (?,?,?,?,?,?,?,?,?,?);
        """
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        bind(s, 1, r.id.uuidString)
        bind(s, 2, r.kind.rawValue)
        bind(s, 3, r.title)
        sqlite3_bind_double(s, 4, r.date.timeIntervalSinceReferenceDate)
        if let d = r.durationSec { sqlite3_bind_double(s, 5, d) } else { sqlite3_bind_null(s, 5) }
        sqlite3_bind_int(s, 6, r.hasSummary ? 1 : 0)
        bindOpt(s, 7, r.transcript)
        bindOpt(s, 8, jsonArray(r.noteSummary))
        bindOpt(s, 9, jsonArray(r.noteDecisions))
        bindOpt(s, 10, jsonArray(r.noteTopics))
        sqlite3_step(s)
    }

    func delete(_ id: UUID) {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        bind(s, 1, id.uuidString)
        sqlite3_step(s)
    }

    /// Every record, newest first — mirrors the old in-memory ordering.
    func all() -> [SessionRecord] {
        var out: [SessionRecord] = []
        let sql = "SELECT id,kind,title,date,duration,hasSummary,transcript,noteSummary,noteDecisions,noteTopics FROM sessions ORDER BY date DESC;"
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return out }
        while sqlite3_step(s) == SQLITE_ROW {
            guard let idStr = text(s, 0), let id = UUID(uuidString: idStr),
                  let kindStr = text(s, 1), let kind = SessionRecord.Kind(rawValue: kindStr) else { continue }
            var r = SessionRecord(id: id, kind: kind, title: text(s, 2) ?? "",
                                  date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 3)))
            if sqlite3_column_type(s, 4) != SQLITE_NULL { r.durationSec = sqlite3_column_double(s, 4) }
            r.hasSummary = sqlite3_column_int(s, 5) != 0
            r.transcript = text(s, 6)
            r.noteSummary = array(text(s, 7))
            r.noteDecisions = array(text(s, 8))
            r.noteTopics = array(text(s, 9))
            out.append(r)
        }
        return out
    }

    // MARK: - helpers

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
    private func bind(_ s: OpaquePointer?, _ i: Int32, _ v: String) { sqlite3_bind_text(s, i, v, -1, TRANSIENT) }
    private func bindOpt(_ s: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(s, i, v, -1, TRANSIENT) } else { sqlite3_bind_null(s, i) }
    }
    private func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
    private func jsonArray(_ a: [String]?) -> String? {
        guard let a, let d = try? JSONEncoder().encode(a) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private func array(_ s: String?) -> [String]? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: d)
    }
}
