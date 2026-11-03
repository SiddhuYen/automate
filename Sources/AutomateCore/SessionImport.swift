import Foundation

/// Claude Code sessions you ran elsewhere (Terminal, an IDE), so Automate can pick one up and continue it.
public enum SessionImport {
    public struct Summary: Identifiable, Sendable, Equatable {
        public var id: String          // session id
        public var file: URL
        public var cwd: String
        public var title: String
        public var modified: Date
        public var size: Int
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The most recently used sessions, newest first. Only reads the start and end of each file.
    public static func recent(root: URL = defaultRoot, limit: Int = 40, skipping: [String] = []) -> [Summary] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var files: [(URL, Date, Int)] = []
        for dir in dirs {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] where f.pathExtension == "jsonl" {
                let v = try? f.resourceValues(forKeys: Set(keys))
                files.append((f, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [Summary] = []
        for (file, date, size) in files {
            if out.count >= limit { break }
            guard size > 0, let s = summarize(file, modified: date, size: size),
                  !skipping.contains(where: { s.cwd.hasPrefix($0) }) else { continue }
            out.append(s)
        }
        return out
    }

    static func summarize(_ file: URL, modified: Date, size: Int) -> Summary? {
        let head = readLines(file, fromEnd: false, bytes: 256_000)
        let tail = size > 256_000 ? readLines(file, fromEnd: true, bytes: 256_000) : []
        var cwd: String?, title: String?, lastPrompt: String?, firstPrompt: String?
        for line in head + tail {
            guard line.contains("\"cwd\"") || line.contains("ai-title") || line.contains("last-prompt") || line.contains("\"type\":\"user\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            switch obj["type"] as? String {
            case "ai-title": title = obj["aiTitle"] as? String ?? title
            case "summary": title = title ?? obj["summary"] as? String
            case "last-prompt": lastPrompt = obj["lastPrompt"] as? String ?? lastPrompt
            case "user":
                if firstPrompt == nil, (obj["isSidechain"] as? Bool) != true { firstPrompt = humanText(obj) }
            default: break
            }
        }
        guard let cwd else { return nil }
        let name = title ?? (firstPrompt ?? lastPrompt).map { String($0.prefix(80)) } ?? "Untitled session"
        return Summary(id: file.deletingPathExtension().lastPathComponent, file: file, cwd: cwd,
                       title: name, modified: modified, size: size)
    }

    /// The conversation's recent messages as transcript rows (reads up to the last `maxBytes`).
    public static func transcript(_ file: URL, maxBytes: Int = 3_000_000) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var outcome = TranscriptReducer.Outcome()
        for line in readLines(file, fromEnd: true, bytes: maxBytes) {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (obj["isSidechain"] as? Bool) != true else { continue }
            let start = items.count
            if obj["type"] as? String == "user", let text = humanText(obj) {
                items.append(TranscriptItem(kind: .user, text: text))
            } else {
                for event in ClaudeEventParser.parse(line: line) {
                    TranscriptReducer.apply(event, to: &items, outcome: &outcome)
                }
            }
            // Keep when it was said, not when it was imported.
            if let date = (obj["timestamp"] as? String).flatMap(parseTimestamp) {
                for i in start..<items.count { items[i].date = date }
            }
        }
        return items
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// What a person typed, skipping tool results and the context blocks tools inject ("<system-reminder>…").
    static func humanText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let s = message["content"] as? String { parts = [s] }
        if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// Whole lines from the start or end of a file, without reading all of a huge file.
    static func readLines(_ file: URL, fromEnd: Bool, bytes: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = fromEnd ? (size > UInt64(bytes) ? size - UInt64(bytes) : 0) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.read(upToCount: bytes) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if fromEnd && start > 0 { lines.removeFirst() }   // probably cut mid-line
        if !fromEnd && UInt64(data.count) < size { lines.removeLast() }
        return lines.filter { !$0.isEmpty }
    }
}
