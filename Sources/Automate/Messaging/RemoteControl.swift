import Foundation
import AutomateCore

/// What Automate does with a text from your phone.
extension AppModel {
    /// Returns the reply to send right away, or nil when the answer comes later (Claude's reply to a chat).
    func handleRemote(_ text: String, from channel: MessageChannel) -> String? {
        switch RemoteCommand.parse(text, expectingApproval: messaging.isAwaitingApproval(on: channel)) {
        case .help:
            return RemoteCommand.helpText

        case .status:
            if !inbox.isEmpty { messaging.markAwaitingApproval(on: channel) }
            return remoteStatus()

        case let .approve(number, note):
            messaging.clearAwaitingApproval(on: channel)
            switch waitingRun(number: number) {
            case .success(let run): return remoteApprove(runId: run.id, note: note)
            case .failure(let message): return message.text
            }

        case let .skip(number):
            messaging.clearAwaitingApproval(on: channel)
            switch waitingRun(number: number) {
            case .success(let run): return remoteSkip(runId: run.id)
            case .failure(let message): return message.text
            }

        case .loops:
            guard !loops.isEmpty else { return "No loops yet. Make one in Automate on your Mac." }
            return "Loops:\n" + loops.map { loop in
                var line = "• \(loop.name): " + (loop.enabled ? loop.triggerSummary : "off")
                if isRunning(loopId: loop.id) { line += " (running)" }
                return line
            }.joined(separator: "\n") + "\n\nSend \"run <name>\" to run one now."

        case let .runLoop(query):
            let q = query.lowercased().trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return "Which loop? Send \"loops\" to see them." }
            let matches = loops.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
            let loop = matches.first { $0.name.lowercased() == q } ?? (matches.count == 1 ? matches[0] : nil)
            guard let loop else {
                if matches.isEmpty {
                    // "run morning" when there's no such loop but there is such a skill.
                    if let skill = RemoteCommand.matchSkill(q, in: knownSkills),
                       skill.lowercased() == q || skill.lowercased().hasSuffix(":" + q) {
                        return remoteSkill(skill, args: "", from: channel)
                    }
                    // "run the tests again" is probably for Claude, unless it was clearly a command.
                    if !text.hasPrefix("/") { return handleChat(text, from: channel) }
                    return "No loop matches \"\(query)\". Send \"loops\" to see them."
                }
                return "Which one? " + matches.map(\.name).joined(separator: ", ")
            }
            return remoteRun(loop, from: channel)

        case .skills:
            guard !knownSkills.isEmpty else {
                return "I learn your skills the first time Claude runs. Send any message (or run a loop), then try again."
            }
            // Plugin skills by their short name; that's what "skill <name>" matches on.
            let names = knownSkills.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            return "Skills:\n" + names.joined(separator: ", ") + "\n\nSend \"skill <name>\" (add details after it) to run one."

        case let .runSkill(name, args):
            guard let skill = RemoteCommand.matchSkill(name, in: knownSkills) else {
                let close = knownSkills.filter { $0.lowercased().contains(name.lowercased()) }
                if !close.isEmpty { return "Which one? " + close.joined(separator: ", ") }
                // "skill issue lol" is chat; "/skill foo" is clearly a command.
                if !text.hasPrefix("/") && !knownSkills.isEmpty { return handleChat(text, from: channel) }
                if knownSkills.isEmpty { return remoteSkill(name, args: args, from: channel) } // let Claude decide
                return "No skill matches \"\(name)\". Send \"skills\" to see them."
            }
            return remoteSkill(skill, args: args, from: channel)

        case .threads:
            let recent = remoteThreadChoices()
            guard !recent.isEmpty else { return "No threads yet. Just send a message to start one." }
            lastThreadList = recent.map(\.id) // "use N" picks from exactly this list, even if the order changes
            let current = remoteThreadId
            return "Recent threads:\n" + recent.enumerated().map { i, t in
                let place = project(for: t)?.name ?? "Research"
                return "\(i + 1). \(t.title) · \(place)" + (t.id == current ? "  ← current" : "")
            }.joined(separator: "\n") + "\n\nSend \"use <number>\" to switch."

        case let .use(n):
            let ids = lastThreadList.isEmpty ? remoteThreadChoices().map(\.id) : lastThreadList
            guard n >= 1, n <= ids.count, let t = threads.first(where: { $0.id == ids[n - 1] && !$0.archived }) else {
                return "There's no thread \(n). Send \"threads\" to see them."
            }
            remoteThreadId = t.id
            let place = project(for: t).map { " in \($0.name)" } ?? ""
            return "Now talking to \"\(t.title)\"\(place). Your next message goes there."

        case let .new(message):
            guard settings.messaging.allowRemoteChat else { return remoteChatOffText }
            let id = createThread(projectId: nil, select: false)
            remoteThreadId = id
            if message.isEmpty { return "🆕 New research thread. Send your first message." }
            return remoteChat(message, threadId: id, channel: channel)

        case .stop:
            guard let id = remoteThreadId else { return "Nothing is running." }
            return remoteStop(id, from: channel)

        case let .result(query):
            let q = query.lowercased()
            let matches = loops.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
            // "last time we talked about…" is for Claude.
            guard let loop = matches.first(where: { $0.name.lowercased() == q }) ?? (matches.count == 1 ? matches[0] : nil) else {
                if matches.isEmpty { return handleChat(text, from: channel) }
                return "Which one? " + matches.map(\.name).joined(separator: ", ")
            }
            guard var run = runs.first(where: { $0.loopId == loop.id && $0.status != .running && $0.parentRunId == nil }) else {
                return "\(loop.name) hasn't run yet."
            }
            // Approved: what the follow-up actually did is the result.
            if run.status == .approved, let child = runs.first(where: { $0.parentRunId == run.id && $0.status.isFinished }) {
                run = child
            }
            let when = run.startedAt.formatted(.relative(presentation: .named))
            let body = run.summary.isEmpty ? run.status.label : RemoteText.plain(ApprovalItems.numbered(run.summary))
            return "\(loop.name) · \(run.status.label) · \(when)\n\n" + RemoteText.clip(body, limit: 1500)

        case let .pause(hours):
            pauseLoops(until: hours.map { Date().addingTimeInterval($0 * 3600) } ?? .distantFuture)
            return "⏸ " + (loopsHeldReason ?? "Loops paused") + ". Send \"resume\" to start them again."

        case .resume:
            pauseLoops(until: nil)
            return "▶️ Loops resumed." + (loopsHeldReason.map { " (\($0))" } ?? "")

        case let .chat(message):
            return handleChat(message, from: channel)
        }
    }

    func handleChat(_ message: String, from channel: MessageChannel) -> String? {
        guard settings.messaging.allowRemoteChat else { return remoteChatOffText }
        let id: UUID
        if let current = remoteThreadId, threads.contains(where: { $0.id == current && !$0.archived }) {
            id = current
        } else {
            id = createThread(projectId: nil, select: false)
            remoteThreadId = id
        }
        return remoteChat(message, threadId: id, channel: channel)
    }

    /// Run a loop because you asked by text (or tapped its button); its result is texted back.
    func remoteRun(_ loop: LoopDefinition, from channel: MessageChannel) -> String {
        if isRunning(loopId: loop.id) { return "\(loop.name) is already running." }
        guard claude != nil else { return "Can't run loops: the claude command wasn't found on the Mac." }
        guard isRiskAccepted(loop) else {
            return "\(loop.name) has settings you haven't OK'd in Automate (\(loop.riskDescription.joined(separator: ", "))), so it won't run from here. Review it on the Mac."
        }
        remoteLoopRequests[loop.id, default: []].insert(channel)
        enqueue(loop, trigger: .manual)
        return "▶️ Started \(loop.name). I'll text you what it finds."
    }

    /// Run a skill in a new research thread; later texts (and swipe-replies to its answer) continue it.
    func remoteSkill(_ skill: String, args: String, from channel: MessageChannel) -> String {
        guard settings.messaging.allowRemoteChat else { return remoteChatOffText }
        let id = createThread(projectId: nil, select: false)
        remoteThreadId = id
        let started = remoteChat("/" + skill + (args.isEmpty ? "" : " " + args), threadId: id, channel: channel)
        let short = skill.split(separator: ":").last.map(String.init) ?? skill
        return "▶️ Running the \(short) skill. I'll text you the result." + (started.map { $0.hasPrefix("💭") ? "" : "\n" + $0 } ?? "")
    }

    /// Stop Claude in a thread (and drop what was queued there) because you texted "stop".
    func remoteStop(_ threadId: UUID, from channel: MessageChannel) -> String? {
        guard runningThreadIds.contains(threadId) else { return "Nothing is running there." }
        queuedMessages[threadId] = nil
        // If its answer was going to this channel, the finished run says "⏹ Stopped." itself.
        let notified = remoteReplies[threadId]?.contains(channel) == true
        stopThread(threadId)
        return notified ? nil : "⏹ Stopped."
    }

    /// A reply to one of Automate's texts about a thread: continue that thread ("stop" alone stops it).
    func replyInThread(_ threadId: UUID, message: String, from channel: MessageChannel) -> String? {
        if RemoteCommand.isBareStop(message) { return remoteStop(threadId, from: channel) }
        guard settings.messaging.allowRemoteChat else { return remoteChatOffText }
        guard threads.contains(where: { $0.id == threadId && !$0.archived }) else {
            return "That thread is gone. Your message wasn't sent; send it again to use your current thread."
        }
        remoteThreadId = threadId
        return remoteChat(message, threadId: threadId, channel: channel)
    }

    /// Buttons to go with a reply on Telegram: ▶️ per loop for "loops", Approve/Skip per waiting run for "status".
    func remoteButtons(for command: RemoteCommand) -> TelegramClient.Keyboard? {
        switch command {
        case .loops:
            let shown = loops.sorted { ($0.enabled ? 0 : 1, $0.name) < ($1.enabled ? 0 : 1, $1.name) }.prefix(12)
            guard !shown.isEmpty else { return nil }
            let buttons = shown.map { ("▶️ " + String($0.name.prefix(28)), "run:" + $0.id) }
                .filter { $0.1.utf8.count <= 64 } // Telegram's limit for button data
            return stride(from: 0, to: buttons.count, by: 2).map { Array(buttons[$0..<min($0 + 2, buttons.count)]) }
        case .status:
            let waiting = inbox.sorted { ($0.approvalNumber ?? 0) < ($1.approvalNumber ?? 0) }.prefix(6)
            guard !waiting.isEmpty else { return nil }
            return waiting.map { r in
                let n = r.approvalNumber.map { "#\($0)" } ?? r.loopName
                return [("✅ Approve \(n)", "approve:\(r.id.uuidString)"), ("⏭ Skip \(n)", "skip:\(r.id.uuidString)")]
            }
        default:
            return nil
        }
    }

    private var remoteChatOffText: String {
        "Chatting with Claude by text is off. Turn it on in Automate → Settings → Messaging."
    }

    private func remoteChat(_ message: String, threadId: UUID, channel: MessageChannel) -> String? {
        guard claude != nil else { return "The claude command wasn't found on the Mac, so I can't answer." }
        let wasBusy = runningThreadIds.contains(threadId)
        send(message, in: threadId, replyVia: channel)
        if wasBusy { return "⏳ Still working on your last message. I'll get to this one next." }
        // Telegram shows "typing…"; iMessage and Photon have no such signal here, so say we got it.
        return channel == .telegram ? nil : "💭 On it…"
    }

    /// The threads `threads` lists and `use N` picks from: most recent first.
    func remoteThreadChoices() -> [ChatThread] {
        Array(threads.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    }

    private func remoteStatus() -> String {
        var lines: [String] = []
        let waiting = inbox.sorted { ($0.approvalNumber ?? 0) < ($1.approvalNumber ?? 0) }
        if waiting.isEmpty {
            lines.append("Nothing is waiting for you.")
        } else {
            lines.append("Waiting for you:")
            for run in waiting {
                let first = RemoteText.plain(run.summary).components(separatedBy: "\n").first { !$0.isEmpty } ?? ""
                lines.append("#\(run.approvalNumber ?? 0) \(run.loopName): \(String(first.prefix(120)))")
            }
            lines.append("Reply \"approve <#>\" or \"skip <#>\".")
        }
        let running = runs.filter { $0.status == .running }.map(\.loopName)
            + threads.filter { runningThreadIds.contains($0.id) }.map { "thread \"\($0.title)\"" }
        if !running.isEmpty { lines.append("\nRunning: " + running.joined(separator: ", ")) }
        if let week = usage.first(where: { $0.name == "seven_day" }) ?? usage.first {
            lines.append("\nUsage: \(Int((week.utilization * 100).rounded()))% of your \(week.label) limit")
        }
        return lines.joined(separator: "\n")
    }

    struct RemoteFailure: Error { let text: String }

    private func waitingRun(number: Int?) -> Result<LoopRun, RemoteFailure> {
        let waiting = inbox
        if let number {
            // By number, snoozed ones count too.
            if let run = runs.first(where: { $0.approvalNumber == number && $0.status == .needsApproval }) { return .success(run) }
            if let run = runs.first(where: { $0.approvalNumber == number }) {
                return .failure(RemoteFailure(text: "#\(number) (\(run.loopName)) is already \(run.status.label.lowercased())."))
            }
            return .failure(RemoteFailure(text: "There's no #\(number). Send \"status\" to see what's waiting."))
        }
        switch waiting.count {
        case 0: return .failure(RemoteFailure(text: "Nothing is waiting for you."))
        case 1: return .success(waiting[0])
        default:
            let list = waiting.map { "#\($0.approvalNumber ?? 0) \($0.loopName)" }.joined(separator: ", ")
            return .failure(RemoteFailure(text: "Which one? \(list). Reply \"approve <#>\" or \"skip <#>\"."))
        }
    }

    func remoteApprove(runId: UUID, note: String) -> String {
        guard let run = runs.first(where: { $0.id == runId }) else { return "That run is gone." }
        guard run.status == .needsApproval else { return "\(run.loopName) is already \(run.status.label.lowercased())." }
        // "approve 12 1,3" picks proposed items by number.
        let items = ApprovalItems.parse(run.summary)
        let picked = ApprovalItems.pick(note, from: items)
        if picked == nil, ApprovalItems.looksLikePick(note) {
            return items.isEmpty ? "\(run.loopName) didn't list separate actions; reply \"approve \(run.approvalNumber ?? 0)\" to approve it all."
                                 : "#\(run.approvalNumber ?? 0) has \(items.count) actions; pick from 1–\(items.count)."
        }
        let finalNote = picked.map { ApprovalItems.note(chosen: $0, all: items, extra: "") } ?? note
        approve(runId: runId, note: finalNote)
        guard runs.first(where: { $0.id == runId })?.status == .approved else {
            return "Couldn't continue \(run.loopName): \(banner ?? "unknown problem")"
        }
        // The follow-up's result comes back by text too.
        remoteLoopRequests[run.loopId, default: []].formUnion(messaging.activeChannels)
        return "✅ Approved \(run.loopName). I'll text you when it's done."
    }

    func remoteSkip(runId: UUID) -> String {
        guard let run = runs.first(where: { $0.id == runId }) else { return "That run is gone." }
        guard run.status == .needsApproval else { return "\(run.loopName) is already \(run.status.label.lowercased())." }
        skip(runId: runId)
        return "⏭ Skipped \(run.loopName)."
    }
}
