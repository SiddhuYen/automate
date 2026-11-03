import Foundation

/// Something you texted Automate from your phone (Telegram or iMessage).
public enum RemoteCommand: Equatable, Sendable {
    case help
    /// What's waiting for you and what's running.
    case status
    /// Approve the waiting run with this number (nil = the only one waiting), with an optional note for Claude.
    case approve(number: Int?, note: String)
    case skip(number: Int?)
    case loops
    /// Run a loop now, found by (part of) its name.
    case runLoop(String)
    /// The skills Claude can run.
    case skills
    /// Run a skill in a new thread: "skill morning", "skill cover-letter-writer for Acme".
    case runSkill(name: String, args: String)
    /// Recent threads, numbered for `use`.
    case threads
    /// Send later messages to thread number N from the `threads` list.
    case use(Int)
    /// Start a new research thread; an empty message just switches to it on the next message.
    case new(String)
    /// Stop the thread that's working on your last message.
    case stop

    /// A swipe-reply that is only the word "stop" (any case, "Stop." / "/stop" too) stops that thread;
    /// anything more ("stop doing that") is a message for Claude.
    public static func isBareStop(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("/") { t.removeFirst() }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,")) == "stop"
    }
    /// The latest result of a loop, found by (part of) its name.
    case result(String)
    /// Pause automatic loop runs (nil hours = until resumed).
    case pause(hours: Double?)
    case resume
    /// Anything else: a message for Claude in your current thread.
    case chat(String)

    /// - expectingApproval: Automate's last text on this channel asked you to approve something. Only then do casual
    ///   answers ("yes", "ok", "no", "approve but only the first") count as approvals; otherwise they're chat, so a
    ///   "yes" meant for Claude can't approve an unrelated loop.
    public static func parse(_ raw: String, expectingApproval: Bool = false) -> RemoteCommand {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .help }

        // "/status@MyBot extra" -> word "status", rest "extra"
        let firstSpace = text.firstIndex(where: { $0 == " " || $0 == "\n" })
        var word = String(firstSpace.map { text[..<$0] } ?? Substring(text)).lowercased()
        let rest = firstSpace.map { String(text[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let slashed = word.hasPrefix("/")
        if slashed { word.removeFirst() }
        if let at = word.firstIndex(of: "@") { word = String(word[..<at]) }
        // Trailing punctuation from phone keyboards: "yes!" "ok."
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        // Explicit commands: a slash, or a word that only makes sense as a command.
        let casualYes: Set = ["yes", "y", "ok", "okay", "go", "👍", "yep", "sure"]
        let casualNo: Set = ["no", "n", "nope", "👎"]

        if rest.isEmpty {
            switch bare {
            case "help", "commands", "start": return .help
            case "status", "inbox", "waiting": return .status
            case "approve", "approved": return .approve(number: nil, note: "")
            case "skip": return .skip(number: nil)
            case "loops": return .loops
            case "skills", "skill": return .skills
            case "threads", "chats": return .threads
            case "new", "reset": return .new("")
            case "stop", "cancel": return .stop
            case "pause": return .pause(hours: nil)
            case "resume", "unpause": return .resume
            default:
                if expectingApproval && casualYes.contains(bare) { return .approve(number: nil, note: "") }
                if expectingApproval && casualNo.contains(bare) { return .skip(number: nil) }
                return .chat(text)
            }
        }

        let (number, afterNumber) = splitNumber(rest)
        switch bare {
        case "approve", "yes":
            // "approve 12 …" always; "approve but only the first" when an approval is pending (or with a slash).
            if let number, number > 0 { return .approve(number: number, note: afterNumber) }
            if bare == "approve" && (slashed || expectingApproval) { return .approve(number: nil, note: rest) }
        case "skip", "no":
            if let number, number > 0, afterNumber.isEmpty { return .skip(number: number) }
        case "run":
            return .runLoop(rest)
        case "skill":
            let parts = rest.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            var name = parts[0]
            if name.hasPrefix("/") { name.removeFirst() }
            return .runSkill(name: name, args: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        case "result", "results":
            return .result(rest)
        case "use", "switch":
            if let number, number > 0, afterNumber.isEmpty { return .use(number) }
        case "new":
            if slashed { return .new(rest) } // "New York weather?" is a question, not a command
        case "pause":
            // "pause 2h", "pause 30m", "pause 3"
            let r = rest.lowercased()
            if let minutes = LoopDefinition.parseMinutes(r.hasSuffix("h") || r.hasSuffix("m") || r.contains("hour") || r.contains("min") ? r : r + "h") {
                return .pause(hours: minutes / 60)
            }
        case "help", "status", "loops", "skills", "threads", "stop":
            if slashed { return parse(bare) }
        default:
            break
        }
        return .chat(text)
    }

    /// "12 only the first two" -> (12, "only the first two"); "#3" -> (3, "")
    static func splitNumber(_ s: String) -> (Int?, String) {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, first.count <= 9,
              let n = Int(first.trimmingCharacters(in: CharacterSet(charactersIn: "#:,."))) else { return (nil, s) }
        return (n, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    public static let helpText = """
    Automate commands:
    • status: what's waiting and running
    • approve [#] [note]: approve a waiting run ("yes" works right after I ask)
    • skip [#]: skip it ("no" works right after I ask)
    • loops: list loops · run <name>: run one now · result <name>: its latest result
    • skills: list skills · skill <name> [details]: run one in a new thread
    • threads: recent threads · use <#>: talk to one
    • new: start a new research thread (/new <message> to start with a message)
    • stop: stop the current reply
    • pause [2h] / resume: hold loops for a while
    Swipe-reply to any of my texts to answer that loop run or thread.
    Anything else goes to Claude in your current thread.
    """

    /// The skill `query` means: an exact name, or the part after "plugin:" ("morning" → "anthropic-skills:morning"),
    /// or the only name containing it. nil if none or several match.
    public static func matchSkill(_ query: String, in skills: [String]) -> String? {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !q.isEmpty else { return nil }
        if let exact = skills.first(where: { $0.lowercased() == q }) { return exact }
        let short = skills.filter { ($0.split(separator: ":").last.map(String.init) ?? $0).lowercased() == q }
        if short.count == 1 { return short[0] }
        let partial = skills.filter { $0.lowercased().contains(q) }
        return partial.count == 1 ? partial[0] : nil
    }
}

/// What a text from Automate was about, so swiping to reply to it goes to the right place.
public enum ReplyTarget: Equatable, Sendable {
    case run(UUID)
    case thread(UUID)

    public var stored: String {
        switch self {
        case .run(let id): return "run:" + id.uuidString
        case .thread(let id): return "thread:" + id.uuidString
        }
    }

    /// Also reads a bare UUID, which is how earlier versions stored loop-run replies.
    public init?(stored: String) {
        if let id = UUID(uuidString: stored) { self = .run(id); return }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "run": self = .run(id)
        case "thread": self = .thread(id)
        default: return nil
        }
    }
}

/// Turning transcripts and markdown into something that reads well in a text message.
public enum RemoteText {
    /// Light markdown cleanup: drop heading marks, bold/italic markers and code fences; keep the words.
    public static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            if let r = line.range(of: "^#{1,6}\\s+", options: .regularExpression) { line.removeSubrange(r) }
            if let r = line.range(of: "^(\\s*)[-*]\\s+", options: .regularExpression) {
                let indent = line[r].prefix { $0 == " " }
                line.replaceSubrange(r, with: indent + "• ")
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
            // [label](url) -> label (url)
            line = line.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "$1 ($2)", options: .regularExpression)
            lines.append(line)
        }
        // Collapse runs of blank lines.
        var out: [String] = []
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            out.append(l)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cut to `limit` characters at a line or word boundary, with a pointer to the full text.
    public static func clip(_ s: String, limit: Int, more: String = "… (full text in Automate)") -> String {
        guard s.count > limit else { return s }
        let budget = max(0, limit - more.count - 1)
        var cut = String(s.prefix(budget))
        if let nl = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: nl) > budget / 2 {
            cut = String(cut[..<nl])
        } else if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > budget / 2 {
            cut = String(cut[..<sp])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + more
    }

    /// Phone numbers in different formats ("(555) 555-0100", "+15555550100") refer to the same handle.
    public static func sameHandle(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespaces).lowercased()
        let y = b.trimmingCharacters(in: .whitespaces).lowercased()
        if x.contains("@") || y.contains("@") { return x == y }
        let dx = x.filter(\.isNumber), dy = y.filter(\.isNumber)
        guard dx.count >= 7, dy.count >= 7 else { return x == y }
        // Both with a country code: they must match exactly. Otherwise compare the national part.
        if x.hasPrefix("+") && y.hasPrefix("+") { return dx == dy }
        return dx.suffix(10) == dy.suffix(10)
    }
}

/// The evening "here's what your loops did today" text. Built from run summaries, so it costs no Claude usage.
public enum DailyDigest {
    public static func text(runs: [LoopRun], waiting: [LoopRun], day: Date, calendar: Calendar = .current) -> String? {
        let today = runs.filter { calendar.isDate($0.startedAt, inSameDayAs: day) && $0.parentRunId == nil && $0.trigger != .test }
        let found = today.filter { [.succeeded, .approved, .skipped, .needsApproval, .failed].contains($0.status) }
        let quiet = today.filter { $0.status == .nothingToDo }.count
        guard !found.isEmpty || !waiting.isEmpty else { return nil }
        var lines = ["🗓 Today from your loops"]
        for run in found.sorted(by: { $0.startedAt < $1.startedAt }).suffix(12) {
            let first = RemoteText.plain(run.summary).components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? run.status.label
            let mark = run.status == .failed ? "❌" : run.status == .needsApproval ? "🔔" : "•"
            lines.append("\(mark) \(run.loopName): \(String(first.prefix(140)))")
        }
        if quiet > 0 { lines.append("(\(quiet) quiet run\(quiet == 1 ? "" : "s") with nothing new)") }
        if !waiting.isEmpty {
            lines.append("\nWaiting for you: " + waiting.map { "#\($0.approvalNumber ?? 0) \($0.loopName)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Whether an hour falls in a daily window that may wrap past midnight (22 → 8).
public enum QuietHours {
    public static func contains(hour: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

/// A short thread title from your first message: "can you please help me fix the login test?" → "Fix the login test".
public enum ThreadTitle {
    static let fillers = ["hey claude", "hi claude", "hey", "hi", "hello", "ok so", "so", "okay", "please", "pls",
                          "can you", "could you", "would you", "will you", "i want you to", "i'd like you to", "i need you to",
                          "help me", "i need to", "i want to", "let's", "lets", "please"]

    public static func make(from message: String, limit: Int = 60) -> String {
        var line = (message.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? message)
            .trimmingCharacters(in: .whitespaces)
        // First sentence only.
        if let r = line.range(of: "[.?!](\\s|$)", options: .regularExpression), line.distance(from: line.startIndex, to: r.lowerBound) >= 12 {
            line = String(line[..<r.lowerBound])
        }
        var changed = true
        while changed {
            changed = false
            let lower = line.lowercased()
            for f in fillers where lower.hasPrefix(f + " ") || lower.hasPrefix(f + ",") {
                line = String(line.dropFirst(f.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
                break
            }
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,:"))
        if line.count > limit {
            let cut = line.prefix(limit)
            line = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
        }
        guard let first = line.first else { return String(message.prefix(limit)) }
        return first.uppercased() + line.dropFirst()
    }
}

/// iMessage keyword: when you text yourself, only messages that start with it ("automate status",
/// "Automate: what's the weather?") are for Automate. Everything else in that chat is left alone.
public enum MessageKeyword {
    /// What follows the keyword (may be empty), or nil if the message isn't addressed to Automate.
    public static func strip(_ text: String, keyword: String) -> String? {
        let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return text }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@") && !k.hasPrefix("@") { t.removeFirst() } // "@automate status"
        guard t.lowercased().hasPrefix(k) else { return nil }
        let rest = t.dropFirst(k.count)
        // "automated tests…" isn't addressed to Automate; a symbol keyword like "!" can be followed by anything.
        if let next = rest.first, k.last?.isLetter == true || k.last?.isNumber == true,
           next.isLetter || next.isNumber { return nil }
        return String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " :,-—\n\t"))
    }

    /// Makes sure Automate's own text can't be mistaken for a message to it when it shows up in your chat.
    public static func guardOutgoing(_ text: String, keyword: String) -> String {
        strip(text, keyword: keyword) == nil ? text : "🤖 " + text
    }
}
