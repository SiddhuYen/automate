import Foundation

// MARK: - Transcript

/// One rendered row in a thread or loop-run transcript.
public struct TranscriptItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user          // what you typed
        case assistant     // Claude's text
        case toolUse       // Claude calling a tool (Bash, Edit, WebSearch, ...)
        case toolResult    // what the tool returned
        case info          // app-level notes ("Loop started by wake")
        case error
        case result        // final summary of a turn (cost, duration)
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var toolName: String?
    public var toolUseId: String?
    /// Extra content for tool calls (the diff of an edit).
    public var detail: String?
    public var isError: Bool
    public var date: Date

    public init(kind: Kind, text: String, toolName: String? = nil, toolUseId: String? = nil,
                isError: Bool = false, date: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.isError = isError
        self.date = date
    }
}

// MARK: - Projects & threads (the ADE side)

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    /// Defaults for new threads in this project (nil = the app-wide defaults).
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var worktreeByDefault: Bool?

    public init(path: String) {
        self.id = UUID()
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum PermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case plan, acceptEdits, auto, dontAsk, bypassPermissions, manual
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .plan: return "Plan (read-only)"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto (classifier)"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass all (dangerous)"
        case .manual: return "Manual"
        }
    }
}

public struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// nil = a research/general thread that isn't tied to a code folder.
    public var projectId: UUID?
    /// Overrides the folder Claude runs in (used when continuing a loop run, whose session lives there).
    public var workingDirectory: String?
    public var sessionId: String?
    public var model: String
    public var effort: String
    public var permissionMode: PermissionMode
    /// Claude in Chrome on for this thread. Optional so threads saved before it existed still load.
    public var useChrome: Bool?
    public var items: [TranscriptItem]
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var archived: Bool
    /// A duplicated thread shares its original's session until its first message, which forks it.
    public var forkOnNextSend: Bool?
    /// Work on a separate git branch in its own worktree (set before the first message).
    public var useWorktree: Bool?
    /// The worktree's branch once it exists.
    public var branch: String?
    /// The loop run this thread continues ("Continue in Thread", or a reply to a loop's text).
    public var followsRunId: UUID?
    /// Messages you've scheduled to send later in this thread.
    public var scheduled: [ScheduledMessage]?
    /// When you last texted this thread from your phone (or handed it to your phone).
    public var lastFromPhone: Date?
    /// Coordinator: may hand tasks to threads in your projects (see `Dispatch`).
    public var isCoordinator: Bool?
    /// The coordinator thread that started this one; its dispatched turns report back there.
    public var reportsTo: UUID?

    /// In use from your phone: texted within the last day.
    public var isOnPhone: Bool { lastFromPhone.map { Date().timeIntervalSince($0) < 86_400 } ?? false }

    /// Where texts from your phone go once you stop using `threadId` from it: the other thread you
    /// used from your phone most recently, or nil (the next text starts a new thread).
    public static func nextPhoneThread(after threadId: UUID, in threads: [ChatThread]) -> UUID? {
        threads.filter { $0.id != threadId && !$0.archived && $0.isOnPhone }
            .max { ($0.lastFromPhone ?? .distantPast) < ($1.lastFromPhone ?? .distantPast) }?.id
    }

    public init(title: String, projectId: UUID?, model: String, effort: String, permissionMode: PermissionMode) {
        self.id = UUID()
        self.title = title
        self.projectId = projectId
        self.workingDirectory = nil
        self.sessionId = nil
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.items = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = false
        self.archived = false
    }
}

public struct ScheduledMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var date: Date

    public init(text: String, date: Date) {
        self.id = UUID()
        self.text = text
        self.date = date
    }
}

// MARK: - Loop runs

public enum RunTrigger: String, Codable, Sendable {
    case schedule, launch, wake, unlock, manual, approval
    /// Another loop finished (`after:`).
    case after
    /// A dry run: research and propose only, whatever the loop's autonomy.
    case test
}

public enum RunStatus: String, Codable, Sendable {
    case running, succeeded, nothingToDo, failed, needsApproval, approved, skipped, cancelled

    public var label: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Done"
        case .nothingToDo: return "Nothing to do"
        case .failed: return "Failed"
        case .needsApproval: return "Needs you"
        case .approved: return "Approved"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }

    public var isFinished: Bool { self != .running }
}

public struct LoopRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var loopId: String
    public var loopName: String
    public var trigger: RunTrigger
    public var status: RunStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var sessionId: String?
    public var summary: String
    public var costUSD: Double?
    public var items: [TranscriptItem]
    /// The run this one continues (set on approval follow-ups).
    public var parentRunId: UUID?
    /// Folder the run's Claude session lives in (needed to resume it).
    public var workingDirectory: String?
    /// Short number for runs that need you ("approve 12" by text). Stays the same once given.
    public var approvalNumber: Int?
    /// "Not now": out of the Inbox until then, when you're reminded again.
    public var snoozedUntil: Date?

    public init(loopId: String, loopName: String, trigger: RunTrigger) {
        self.id = UUID()
        self.loopId = loopId
        self.loopName = loopName
        self.trigger = trigger
        self.status = .running
        self.startedAt = Date()
        self.endedAt = nil
        self.sessionId = nil
        self.summary = ""
        self.costUSD = nil
        self.items = []
        self.parentRunId = nil
        self.workingDirectory = nil
    }
}

// MARK: - Export

public enum TranscriptExport {
    /// A readable markdown copy of a conversation: your messages, Claude's replies, and one line per tool call.
    public static func markdown(title: String, items: [TranscriptItem], includeTools: Bool = true) -> String {
        var out = "# \(title)\n"
        for item in items {
            switch item.kind {
            case .user:
                out += "\n**You:**\n\n" + item.text + "\n"
            case .assistant:
                out += "\n" + item.text + "\n"
            case .toolUse where includeTools:
                out += "\n> 🔧 \(item.toolName ?? "Tool"): `\(item.text.replacingOccurrences(of: "`", with: "'"))`\n"
            case .error:
                out += "\n> ⚠️ \(item.text)\n"
            case .info:
                out += "\n*\(item.text)*\n"
            default:
                break
            }
        }
        return out
    }
}
