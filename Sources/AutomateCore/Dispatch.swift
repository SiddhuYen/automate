import Foundation

/// A coordinator thread hands work to threads in your projects. It writes one JSON file per task to its outbox
/// (`dispatch/<thread id>/`); when its reply ends Automate starts those threads (or continues ones it started), and
/// each one's final answer comes back to the coordinator as a message, so it can send follow-ups or wrap up.
public enum Dispatch {
    /// Tasks a coordinator may hand out without you sending it a message. Each of your messages resets it.
    public static let budget = 25
    /// Report header; also how the coordinator (and Automate) tell a report from your own messages.
    public static let reportPrefix = "[Automate] Report from"

    public struct Task: Equatable, Sendable {
        /// Project name or folder; nil = a research thread.
        public var project: String?
        /// Continue this thread (one the coordinator started) instead of starting a new one.
        public var thread: UUID?
        public var title: String?
        public var message: String

        public init(project: String? = nil, thread: UUID? = nil, title: String? = nil, message: String) {
            self.project = project
            self.thread = thread
            self.title = title
            self.message = message
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// One task object, or an array of them.
    public static func parse(_ data: Data) throws -> [Task] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError(description: "isn't valid JSON")
        }
        let objects: [Any] = (json as? [Any]) ?? [json]
        return try objects.map { any in
            guard let o = any as? [String: Any] else { throw ParseError(description: "each task must be a JSON object") }
            func string(_ key: String) -> String? {
                (o[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
            guard let message = string("message") ?? string("text") ?? string("prompt") else {
                throw ParseError(description: "a task has no \"message\"")
            }
            var thread: UUID?
            if let t = string("thread") ?? string("thread_id") ?? string("threadId"), t.lowercased() != "new" {
                guard let id = UUID(uuidString: t) else { throw ParseError(description: "\"\(t)\" isn't a thread id") }
                thread = id
            }
            return Task(project: string("project"), thread: thread, title: string("title"), message: message)
        }
    }

    public struct ThreadSummary: Sendable {
        public var id: UUID
        public var title: String
        public var project: String?
        public var running: Bool
        public init(id: UUID, title: String, project: String?, running: Bool) {
            self.id = id
            self.title = title
            self.project = project
            self.running = running
        }
    }

    /// Added to a coordinator thread's system prompt.
    public static func coordinatorPrompt(outbox: URL, projects: [(name: String, path: String)],
                                         threads: [ThreadSummary], budgetLeft: Int) -> String {
        let projectList = projects.isEmpty ? "  (none added yet)"
            : projects.map { "  - \($0.name): \($0.path)" }.joined(separator: "\n")
        let threadList = threads.isEmpty ? "  (none yet)"
            : threads.map { "  - \($0.id.uuidString) · \($0.title) · \($0.project ?? "research") · \($0.running ? "working" : "idle")" }
                .joined(separator: "\n")
        return """
        You're a coordinator thread in Automate: you can hand work to Claude threads in the user's projects. For each
        task, write a JSON file to \(outbox.path)/<short-name>.json:
          {"project": "<project name>", "title": "<short title>", "message": "<full instructions>"}
        To give one of your threads more instructions, write {"thread": "<its id>", "message": "..."} instead.
        Automate starts them when your reply ends; they work in parallel. Each thread sees only your message, not this
        conversation, so make it self-contained (goal, relevant context, what "done" means, what to report back). They
        run with their project's own permission settings, and should not commit or push unless the user asked for it.
        When a thread finishes, its final answer arrives here as a message starting with "\(reportPrefix)".
        Then decide: send it follow-up instructions, hand out other tasks, or tell the user where things stand.
        Several reports can arrive one after another; it's fine to just note one and wait for the rest.
        Don't hand out busywork, and stop once the job is done. You can hand out \(budgetLeft) more task(s) before the
        user writes to you again; after that Automate ignores new task files.

        The user's projects:
        \(projectList)

        Threads you've started:
        \(threadList)
        """
    }

    /// The message a finished thread sends its coordinator.
    public static func report(title: String, threadId: UUID, project: String?, text: String,
                              stopped: Bool, failed: Bool, limit: Int = 8000) -> String {
        var head = "\(reportPrefix) \"\(title)\" (thread \(threadId.uuidString), \(project.map { "project \($0)" } ?? "research"))"
        if stopped { head += " — the user stopped it" } else if failed { head += " — it ended with an error" }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = "(no reply)" }
        if body.count > limit { body = String(body.prefix(limit)) + "\n… (cut; the full reply is in that thread)" }
        return head + ":\n\n" + body
    }

    public static func isReport(_ text: String) -> Bool { text.hasPrefix(reportPrefix) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
