import Foundation

/// Turns Claude events into transcript rows. Shared by chat threads and loop runs.
public enum TranscriptReducer {
    public struct Outcome: Sendable {
        public var sessionId: String?
        public var finalText: String?
        public var isError: Bool = false
        public var costUSD: Double?
        public var usage: [UsageWindow]?
        /// The folder the session actually runs in.
        public var cwd: String?
        /// Row being written by `.textDelta`s; replaced by the finished block when it arrives.
        public var streamingIndex: Int?
        public init() {}
    }

    public static let maxToolResultChars = 6000

    public static func apply(_ event: ClaudeEvent, to items: inout [TranscriptItem], outcome: inout Outcome) {
        switch event {
        case let .sessionStarted(sessionId, _, cwd):
            outcome.sessionId = sessionId
            outcome.cwd = cwd

        case let .textDelta(t):
            if let i = outcome.streamingIndex, items.indices.contains(i) {
                items[i].text += t
            } else {
                items.append(TranscriptItem(kind: .assistant, text: t))
                outcome.streamingIndex = items.count - 1
            }

        case let .text(t):
            if let i = outcome.streamingIndex, items.indices.contains(i) {
                items[i].text = t
            } else {
                items.append(TranscriptItem(kind: .assistant, text: t))
            }
            outcome.streamingIndex = nil

        case let .usage(windows):
            outcome.usage = windows

        case .skills:
            break

        case let .toolUse(id, name, summary, detail):
            outcome.streamingIndex = nil
            var item = TranscriptItem(kind: .toolUse, text: summary, toolName: name, toolUseId: id)
            item.detail = detail
            items.append(item)

        case let .toolResult(toolUseId, text, isError):
            outcome.streamingIndex = nil
            let clipped = text.count > maxToolResultChars
                ? String(text.prefix(maxToolResultChars)) + "\n… (\(text.count - maxToolResultChars) more characters)"
                : text
            items.append(TranscriptItem(kind: .toolResult, text: clipped, toolUseId: toolUseId, isError: isError))

        case let .result(text, isError, cost, sessionId, durationMs):
            outcome.streamingIndex = nil
            if let sessionId { outcome.sessionId = sessionId }
            outcome.finalText = text
            outcome.isError = isError
            outcome.costUSD = cost
            var line = isError ? "Finished with an error" : "Done"
            if let ms = durationMs { line += " in \(formatDuration(ms))" }
            if isError && !text.isEmpty { line += ": \(text)" }
            items.append(TranscriptItem(kind: .result, text: line, isError: isError))

        case let .processError(message):
            outcome.streamingIndex = nil
            outcome.isError = true
            if outcome.finalText == nil { outcome.finalText = message }
            items.append(TranscriptItem(kind: .error, text: message, isError: true))
        }
    }

    static func formatDuration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

/// Small text edits to loop files, so toggles in the UI keep the file as the source of truth.
public enum LoopFileEditor {
    public static func setEnabled(_ enabled: Bool, in url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try updated(text, key: "enabled", value: enabled ? "true" : "false")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Remove `key:` (and a block list under it) from the frontmatter.
    public static func removing(_ text: String, key: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        guard let i = (1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("\(key):") }) else {
            return text
        }
        var j = i + 1
        while j < end, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { j += 1 }
        lines.removeSubrange(i..<j)
        return lines.joined(separator: "\n")
    }

    /// Replace `key:` inside the frontmatter, or add it (adding a frontmatter block if needed).
    public static func updated(_ text: String, key: String, value: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for i in 1..<end {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("\(key):") {
                    // Keep a trailing comment ("schedule: daily 09:00   # morning").
                    let oldValue = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    let quoted = oldValue.hasPrefix("\"") || oldValue.hasPrefix("'")
                    let comment = quoted ? "" : lines[i].range(of: "\\s{2,}#", options: .regularExpression)
                        .map { String(lines[i][$0.lowerBound...]) } ?? ""
                    lines[i] = "\(key): \(value)" + comment
                    var j = i + 1
                    while j < end, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("- ") { j += 1 }
                    lines.removeSubrange((i + 1)..<j)
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert("\(key): \(value)", at: end)
            return lines.joined(separator: "\n")
        }
        return "---\n\(key): \(value)\n---\n" + text
    }
}
