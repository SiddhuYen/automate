import Foundation

/// A simplified view of the `claude -p --output-format stream-json --verbose` event stream.
public enum ClaudeEvent: Sendable, Equatable {
    /// `cwd` is where the session really runs (differs from the requested folder with `--worktree`).
    case sessionStarted(sessionId: String, model: String?, cwd: String? = nil)
    case text(String)
    /// A piece of text as Claude writes it (only with `--include-partial-messages`). The full block follows as `.text`.
    case textDelta(String)
    /// `detail`: what an edit changes, as diff lines ("- old" / "+ new"), for Edit, MultiEdit and Write.
    case toolUse(id: String, name: String, summary: String, detail: String? = nil)
    case toolResult(toolUseId: String, text: String, isError: Bool)
    case result(text: String, isError: Bool, costUSD: Double?, sessionId: String?, durationMs: Int?)
    case processError(String)
    /// How much of the subscription's usage limits are used.
    case usage([UsageWindow])
    /// The skills this session can run (from the init event), so "skills" by text can list them.
    case skills([String])
}

/// One of the subscription's usage limits (e.g. the 5-hour or 7-day window), from the CLI's rate_limit_event.
public struct UsageWindow: Codable, Sendable, Equatable, Identifiable {
    public var name: String          // "five_hour", "seven_day", ...
    public var utilization: Double   // 0...1
    public var resetsAt: Date?
    public var status: String        // "allowed", "allowed_warning", "rejected"

    public var id: String { name }

    public init(name: String, utilization: Double, resetsAt: Date?, status: String) {
        self.name = name
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.status = status
    }

    /// "5-hour", "7-day", or the raw name.
    public var label: String {
        switch name {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        case "seven_day_opus": return "7-day Opus"
        case "seven_day_sonnet": return "7-day Sonnet"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public enum ClaudeEventParser {
    /// Parse one line of stream-json into zero or more events.
    public static func parse(line: String) -> [ClaudeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init", let sid = obj["session_id"] as? String {
                var events: [ClaudeEvent] = [.sessionStarted(sessionId: sid, model: obj["model"] as? String, cwd: obj["cwd"] as? String)]
                if let skills = obj["skills"] as? [String], !skills.isEmpty { events.append(.skills(skills)) }
                return events
            }
            return []

        case "assistant":
            // Subagent traffic carries parent_tool_use_id; keep the main thread only.
            if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty { return [] }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty { events.append(.text(t)) }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.toolUse(id: id, name: name, summary: summarize(tool: name, input: input),
                                           detail: editDiff(tool: name, input: input)))
                default:
                    break // thinking blocks etc. are not shown
                }
            }
            return events

        case "user":
            if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty { return [] }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeEvent] = []
            for block in content where (block["type"] as? String) == "tool_result" {
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                events.append(.toolResult(toolUseId: id, text: flatten(block["content"]), isError: isError))
            }
            return events

        case "stream_event":
            if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty { return [] }
            guard let event = obj["event"] as? [String: Any], (event["type"] as? String) == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
                  let t = delta["text"] as? String, !t.isEmpty else { return [] }
            return [.textDelta(t)]

        case "rate_limit_event":
            guard let info = obj["rate_limit_info"] as? [String: Any] else { return [] }
            var windows: [UsageWindow] = []
            if let unified = info["unifiedWindows"] as? [String: Any] {
                for (name, value) in unified {
                    guard let w = value as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                    let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    windows.append(UsageWindow(name: name, utilization: u, resetsAt: resets,
                                               status: w["status"] as? String ?? "allowed"))
                }
            } else if let name = info["rateLimitType"] as? String, let u = (info["utilization"] as? NSNumber)?.doubleValue {
                let resets = (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(name: name, utilization: u, resetsAt: resets,
                                           status: info["status"] as? String ?? "allowed"))
            }
            return windows.isEmpty ? [] : [.usage(windows.sorted { $0.name < $1.name })]

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String) != "success")
            let text = obj["result"] as? String ?? (obj["subtype"] as? String ?? "")
            let cost = (obj["total_cost_usd"] as? NSNumber)?.doubleValue
            let duration = (obj["duration_ms"] as? NSNumber)?.intValue
            return [.result(text: text, isError: isError, costUSD: cost,
                            sessionId: obj["session_id"] as? String, durationMs: duration)]

        default:
            return []
        }
    }

    /// Tool results can be a string or an array of content blocks.
    static func flatten(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { b -> String? in
                if let t = b["text"] as? String { return t }
                if (b["type"] as? String) == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    /// A one-line description of a tool call for the transcript.
    public static func summarize(tool: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "path", "url", "query", "pattern", "description", "prompt", "skill"]
        for key in keys {
            if let v = input[key] as? String, !v.isEmpty {
                return truncate(v.replacingOccurrences(of: "\n", with: " ⏎ "), 240)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return truncate(s, 240)
        }
        return ""
    }

    /// A small diff for file edits: removed lines with "- ", added with "+ ". Capped so huge writes stay light.
    public static func editDiff(tool: String, input: [String: Any], maxLines: Int = 400) -> String? {
        var pairs: [(String, String)] = []
        switch tool {
        case "Edit":
            pairs = [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")]
        case "MultiEdit":
            pairs = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
        case "Write":
            pairs = [("", input["content"] as? String ?? "")]
        default:
            return nil
        }
        var lines: [String] = []
        for (i, (old, new)) in pairs.enumerated() {
            if i > 0 { lines.append("@@") }
            if !old.isEmpty { lines += old.components(separatedBy: "\n").map { "- " + $0 } }
            if !new.isEmpty { lines += new.components(separatedBy: "\n").map { "+ " + $0 } }
        }
        guard !lines.isEmpty else { return nil }
        if lines.count > maxLines {
            let extra = lines.count - maxLines
            lines = Array(lines.prefix(maxLines)) + ["… \(extra) more lines"]
        }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
