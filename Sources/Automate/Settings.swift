import Foundation
import AutomateCore

struct AppSettings: Codable, Equatable {
    var defaultModel = "opus"
    var defaultEffort = "high"
    var defaultPermission: PermissionMode = .auto
    var maxConcurrentLoops = 2
    /// Leave empty to auto-detect `claude` from your shell.
    var claudeExecutableOverride = ""
    var notifyWhenThreadFinishesInBackground = true
    /// Show Claude's replies word by word as they're written.
    var streamReplies = true
    /// ⌃⌥Space opens Quick Ask from any app.
    var quickAskHotKey = true
    /// Threads may write loop files when you ask for something recurring ("every morning…", "remind me at 5").
    var threadsCanMakeLoops = true
    /// automate://ask links send right away instead of filling in a draft. Off: any web page can open such a link.
    var urlsMaySend = false
    /// New project threads start on their own git branch (worktree).
    var worktreeByDefault = false
    /// Hold scheduled/triggered loops while any usage window is at or above this percent (0 = never).
    var usageGuardPercent = 90
    /// Reusable messages for the composer's ⚡ menu.
    var prompts: [SavedPrompt] = SavedPrompt.defaults
    /// Return sends a message (Shift-Return for a new line); otherwise ⌘Return sends.
    var returnSends = false
    /// Added to every thread and loop ("I'm a student; keep answers short").
    var customInstructions = ""
    var messaging = MessagingSettings()

    init() {}

    // Settings saved by older versions lack newer keys; keep the defaults for those instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? d.defaultModel
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort) ?? d.defaultEffort
        defaultPermission = (try? c.decodeIfPresent(PermissionMode.self, forKey: .defaultPermission)) ?? d.defaultPermission
        maxConcurrentLoops = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentLoops) ?? d.maxConcurrentLoops
        claudeExecutableOverride = try c.decodeIfPresent(String.self, forKey: .claudeExecutableOverride) ?? d.claudeExecutableOverride
        notifyWhenThreadFinishesInBackground = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenThreadFinishesInBackground)
            ?? d.notifyWhenThreadFinishesInBackground
        streamReplies = try c.decodeIfPresent(Bool.self, forKey: .streamReplies) ?? d.streamReplies
        quickAskHotKey = try c.decodeIfPresent(Bool.self, forKey: .quickAskHotKey) ?? d.quickAskHotKey
        threadsCanMakeLoops = try c.decodeIfPresent(Bool.self, forKey: .threadsCanMakeLoops) ?? d.threadsCanMakeLoops
        urlsMaySend = try c.decodeIfPresent(Bool.self, forKey: .urlsMaySend) ?? d.urlsMaySend
        worktreeByDefault = try c.decodeIfPresent(Bool.self, forKey: .worktreeByDefault) ?? d.worktreeByDefault
        usageGuardPercent = try c.decodeIfPresent(Int.self, forKey: .usageGuardPercent) ?? d.usageGuardPercent
        prompts = (try? c.decodeIfPresent([SavedPrompt].self, forKey: .prompts)) ?? d.prompts
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? d.customInstructions
        returnSends = try c.decodeIfPresent(Bool.self, forKey: .returnSends) ?? d.returnSends
        messaging = (try? c.decodeIfPresent(MessagingSettings.self, forKey: .messaging)) ?? d.messaging
    }
}

struct SavedPrompt: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    /// Only offered in project (coding) threads.
    var forProjects = false

    static let defaults: [SavedPrompt] = [
        SavedPrompt(title: "Review my changes",
                    text: "Review my uncommitted changes (git diff) for bugs and risky edits. List problems by severity with file:line. Don't change anything yet.",
                    forProjects: true),
        SavedPrompt(title: "Write tests for recent changes",
                    text: "Add tests for the code I changed recently. Follow the project's existing test style, run them, and fix failures you caused.",
                    forProjects: true),
        SavedPrompt(title: "Explain this repo",
                    text: "Give me a short tour of this repo: what it does, how it's organized, how to build and run it, and where the main logic lives.",
                    forProjects: true),
        SavedPrompt(title: "Commit my changes",
                    text: "Commit the current changes with a clear message (group related changes into separate commits if it helps). Don't push.",
                    forProjects: true),
        SavedPrompt(title: "Research and compare",
                    text: "Research and compare the main options for: \nGive me a short table and a recommendation, with sources."),
        SavedPrompt(title: "Summarize a link",
                    text: "Summarize this in 5 bullets, then tell me what's actually new or surprising: "),
    ]
}

/// Texting Automate: loop results and approvals go to your phone, and you can reply with commands or chat.
struct MessagingSettings: Codable, Equatable {
    var telegramEnabled = false
    /// The one chat Automate listens to, set when you pair from Telegram.
    var telegramChatId: Int64?
    var telegramBotName = ""
    var imessageEnabled = false
    /// Your phone number or Apple ID email; Automate texts this and listens to replies from it.
    var imessageHandle = ""
    /// Read replies from Messages (needs Full Disk Access).
    var imessageCommands = true
    /// Only iMessages that start with this word are for Automate (empty = every message). Makes texting yourself safe.
    var imessageKeyword = "automate"
    /// iMessage from Photon's line (photon.codes): no Messages.app, Full Disk Access or keyword needed.
    var photonEnabled = false
    /// Who Photon texts; empty = the iMessage number above.
    var photonHandle = ""
    var sendApprovals = true
    /// Loop results, following each loop's `notify` (or `message`) setting.
    var sendLoopResults = true
    /// When a thread you started in the app finishes while the Mac is idle or locked.
    var sendThreadsWhenAway = false
    var allowRemoteChat = true
    /// One text each evening with what loops found that day.
    var dailyDigest = false
    var dailyDigestHour = 21
    /// One-way notifications to Discord, Slack or ntfy (URL kept in secrets.json).
    var webhookEnabled = false
    /// Hold texts you didn't ask for (loop results, approvals) overnight and send them in the morning.
    var quietHours = false
    var quietStart = 22
    var quietEnd = 8

    init() {}

    var photonAddress: String {
        let h = photonHandle.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? imessageHandle.trimmingCharacters(in: .whitespaces) : h
    }

    func isQuiet(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHours, quietStart != quietEnd else { return false }
        return QuietHours.contains(hour: calendar.component(.hour, from: date), start: quietStart, end: quietEnd)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MessagingSettings()
        telegramEnabled = try c.decodeIfPresent(Bool.self, forKey: .telegramEnabled) ?? d.telegramEnabled
        telegramChatId = try c.decodeIfPresent(Int64.self, forKey: .telegramChatId)
        telegramBotName = try c.decodeIfPresent(String.self, forKey: .telegramBotName) ?? d.telegramBotName
        imessageEnabled = try c.decodeIfPresent(Bool.self, forKey: .imessageEnabled) ?? d.imessageEnabled
        imessageHandle = try c.decodeIfPresent(String.self, forKey: .imessageHandle) ?? d.imessageHandle
        imessageCommands = try c.decodeIfPresent(Bool.self, forKey: .imessageCommands) ?? d.imessageCommands
        imessageKeyword = try c.decodeIfPresent(String.self, forKey: .imessageKeyword) ?? d.imessageKeyword
        photonEnabled = try c.decodeIfPresent(Bool.self, forKey: .photonEnabled) ?? d.photonEnabled
        photonHandle = try c.decodeIfPresent(String.self, forKey: .photonHandle) ?? d.photonHandle
        sendApprovals = try c.decodeIfPresent(Bool.self, forKey: .sendApprovals) ?? d.sendApprovals
        sendLoopResults = try c.decodeIfPresent(Bool.self, forKey: .sendLoopResults) ?? d.sendLoopResults
        sendThreadsWhenAway = try c.decodeIfPresent(Bool.self, forKey: .sendThreadsWhenAway) ?? d.sendThreadsWhenAway
        allowRemoteChat = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteChat) ?? d.allowRemoteChat
        quietHours = try c.decodeIfPresent(Bool.self, forKey: .quietHours) ?? d.quietHours
        webhookEnabled = try c.decodeIfPresent(Bool.self, forKey: .webhookEnabled) ?? d.webhookEnabled
        dailyDigest = try c.decodeIfPresent(Bool.self, forKey: .dailyDigest) ?? d.dailyDigest
        dailyDigestHour = try c.decodeIfPresent(Int.self, forKey: .dailyDigestHour) ?? d.dailyDigestHour
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? d.quietEnd
    }
}
