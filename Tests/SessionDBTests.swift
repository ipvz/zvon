import Foundation
import SQLite3

// SessionRecord's display-only formatter dependency; the database tests use the production record.
enum SessionStore { static let time = DateFormatter() }

@main struct SessionDBTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let db = SessionDB(path: path)!
        var record = SessionRecord(kind: .dictation, title: "Сохранённая фраза", date: Date())
        try db.insert(record)
        var rows = try db.all()
        precondition(rows == [record])
        record.userNotes = "Заметка"
        try db.insert(record)
        rows = try db.all()
        precondition(rows == [record])
        try db.delete(record.id)
        rows = try db.all()
        precondition(rows.isEmpty)
        print("PASS: history insert, update, reload and delete")

        var other: OpaquePointer?
        precondition(sqlite3_open(path, &other) == SQLITE_OK)
        precondition(sqlite3_exec(other, "DROP TABLE sessions", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(other)
        do { try db.insert(record); preconditionFailure("save error was swallowed") } catch {}
        do { try db.delete(record.id); preconditionFailure("delete error was swallowed") } catch {}
        do { _ = try db.all(); preconditionFailure("read error was swallowed") } catch {}
        print("PASS: failed writes, deletes and reads propagate errors")
    }
}
