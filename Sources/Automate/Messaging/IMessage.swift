import Foundation
import SQLite3
import AutomateCore

/// Sends iMessages through Messages.app (AppleScript) and reads replies from its database.
///
/// Sending needs the one-time "Automate wants to control Messages" OK. Reading replies needs Full Disk Access for
/// Automate (System Settings → Privacy & Security), because chat.db is protected.
enum IMessage {
    /// Tests point this at a stand-in database.
    nonisolated(unsafe) static var databaseURL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")

    /// Runs off the main thread; returns an error message, or nil on success.
    static func send(_ text: String, to handle: String) async -> String? {
        await Task.detached {
            // Text and handle go in as arguments, so nothing needs escaping.
            let script = """
            on run argv
                set theHandle to item 1 of argv
                set theText to item 2 of argv
                tell application "Messages"
                    set theService to 1st account whose service type = iMessage
                    send theText to participant theHandle of theService
                end tell
            end run
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script, handle, text]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return error.localizedDescription }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return nil }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not allowed") {
                return "macOS blocked Automate from controlling Messages. Allow it in System Settings → Privacy & Security → Automation."
            }
            return msg.isEmpty ? "osascript exited with status \(p.terminationStatus)" : msg
        }.value
    }

    struct Incoming {
        var rowId: Int64
        var text: String
        var isFromMe: Bool
        var guid = ""
        /// For a swipe-reply: the guid of the message it answers.
        var replyTo: String?
    }

    enum ReadError: Error {
        case noAccess
        case failed(String)
    }

    /// The newest message's row id, so we only react to messages that arrive after Automate starts listening.
    static func latestRowId() throws -> Int64 {
        let db = try open()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message", -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Messages after `rowId` in your conversation with `handle`, and the highest row id looked at (so the caller
    /// moves past other conversations' messages too).
    static func messages(after rowId: Int64, handle: String) throws -> (messages: [Incoming], lastRow: Int64) {
        let db = try open()
        defer { sqlite3_close(db) }
        // thread_originator_guid (swipe-replies) exists since macOS 11; don't fail on a database without it.
        let replyColumn = hasColumn(db, table: "message", column: "thread_originator_guid") ? "m.thread_originator_guid" : "NULL"
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, IFNULL(h.id, ''), IFNULL(c.chat_identifier, ''),
               m.item_type, IFNULL(m.associated_message_type, 0), IFNULL(m.guid, ''), \(replyColumn)
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.ROWID > ?1
        ORDER BY m.ROWID LIMIT 500
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowId)
        var out: [Incoming] = []
        var seen = Set<Int64>()
        var lastRow = rowId
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            lastRow = max(lastRow, id)
            // Only plain messages: not tapbacks/reactions (associated_message_type), not group events (item_type).
            guard sqlite3_column_int(stmt, 6) == 0, sqlite3_column_int(stmt, 7) == 0 else { continue }
            let sender = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let chat = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            guard RemoteText.sameHandle(sender, handle) || RemoteText.sameHandle(chat, handle),
                  seen.insert(id).inserted else { continue }
            var text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if text.isEmpty, let blob = sqlite3_column_blob(stmt, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                text = IMessageText.decode(attributedBody: data) ?? ""
            }
            // Strip the object-replacement character attachments leave behind.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let replyTo = sqlite3_column_text(stmt, 9).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            out.append(Incoming(rowId: id, text: text, isFromMe: sqlite3_column_int(stmt, 3) != 0,
                                guid: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "", replyTo: replyTo))
        }
        return (out, lastRow)
    }

    /// The phone numbers and emails this Mac sends iMessages from, so a conversation with yourself can be told
    /// apart from one with someone else.
    static func ownHandles() throws -> [String] {
        let db = try open()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT account FROM message WHERE is_from_me = 1 AND account IS NOT NULL ORDER BY ROWID DESC LIMIT 2000"
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT account FROM (\(sql))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            // "E:me@icloud.com" / "P:+15555550100"
            out.append(raw.count > 2 && raw.dropFirst().hasPrefix(":") ? String(raw.dropFirst(2)) : raw)
        }
        return out
    }

    private static func hasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info('\(table)') WHERE name = ?1", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, column, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func open() throws -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            sqlite3_close(db)
            throw rc == SQLITE_CANTOPEN || rc == SQLITE_PERM || rc == SQLITE_AUTH ? ReadError.noAccess : ReadError.failed("sqlite error \(rc)")
        }
        // Opening succeeds lazily; the first real read is what fails without Full Disk Access.
        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT 1 FROM message LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        sqlite3_finalize(stmt)
        guard ok else {
            sqlite3_close(db)
            throw ReadError.noAccess
        }
        return db
    }
}
