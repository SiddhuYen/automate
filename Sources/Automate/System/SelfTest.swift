#if DEBUG
import AppKit
import AutomateCore

/// Development aid: `AUTOMATE_DATA_DIR=/tmp/x Automate --selftest` drives the real app model against the real
/// claude CLI (haiku, tiny prompts) and prints PASS/FAIL lines. Messaging channels stay off, so nothing is sent.
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func waitUntil(_ timeout: TimeInterval = 180, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    static func run(only: (@MainActor (AppModel) async -> Void)? = nil) {
        guard ProcessInfo.processInfo.environment["AUTOMATE_DATA_DIR"] != nil else {
            print("Set AUTOMATE_DATA_DIR to a scratch folder first.")
            exit(1)
        }
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.bootstrapped = true
        model.settings.defaultModel = "haiku"
        model.settings.defaultEffort = "low"
        model.settings.defaultPermission = .auto
        model.settings.streamReplies = true
        model.settings.messaging = MessagingSettings()
        Task { @MainActor in
            if let only {
                model.detectedClaude = ClaudeLocator.locate()
                await only(model)
            } else {
                await steps(model)
            }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `--suggest`: run "Suggest from my work" once against your real sessions and print what comes back.
    static func suggest() {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard let location = ClaudeLocator.locate() else { print("no claude"); exit(1) }
            let recent = SessionImport.recent(limit: 50, skipping: ["/private/tmp", "/tmp"])
            print("sessions: \(recent.count)")
            let req = LoopWriter.suggestionsRequest(sessions: recent.map { ($0.title, $0.cwd, $0.modified) }, existing: [],
                                                    cwd: FileManager.default.temporaryDirectory)
            let s = try! ClaudeSession.start(req, location: location, timeout: 300)
            var items: [TranscriptItem] = []
            var outcome = TranscriptReducer.Outcome()
            for await e in s.events { TranscriptReducer.apply(e, to: &items, outcome: &outcome) }
            for text in LoopWriter.splitSuggestions(outcome.finalText ?? "") {
                let l = LoopDefinition.parse(text: text, fileURL: URL(fileURLWithPath: "/tmp/x.md"))
                print("• \(l.name) | \(l.triggerSummary) | \(l.autonomy.rawValue) | enabled=\(l.enabled) | warnings=\(l.warnings)")
            }
            exit(0)
        }
    }

    /// Texting yourself: only "automate …" messages count, Automate's echoes never do, and the double copy counts once.
    static func imessageKeyword() {
        let hub = AppModel.shared.messaging
        AppModel.shared.settings.messaging.imessageKeyword = "automate"
        let before = hub.log.count
        hub.handleIMessage("remind me to buy milk", selfChat: true)
        check(hub.log.count == before, "a note to yourself without the keyword is ignored")
        hub.handleIMessage("🤖 Automate can help with that.", selfChat: true)
        check(hub.log.count == before, "Automate's own (guarded) text is ignored")
        hub.handleIMessage("Automate help", selfChat: true)
        hub.handleIMessage("Automate help", selfChat: true) // the second copy self-chats produce
        check(hub.log.count == before + 1 && hub.log.last?.text == "Automate help", "a keyword message counts, once")
    }

    /// Calls the deprecated-API test through a protocol so the warning stays contained.
    static func runIMessageReader() { (Self.self as DeprecatedRunner.Type).runReader() }

    /// Messages stores text with the old typedstream archiver, so the stand-in database needs it too.
    @available(macOS, deprecated: 10.13)
    static func legacyArchive(_ object: Any) -> Data { NSArchiver.archivedData(withRootObject: object) }

    @available(macOS, deprecated: 10.13)
    static func imessageReader() {
        let db = AppModel.shared.store.root.appendingPathComponent("fake-chat.db")
        let blob = legacyArchive(NSAttributedString(string: "approve 3"))
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER,
                              item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, account TEXT);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        INSERT INTO handle VALUES (1, '+15555550100'), (2, '+19995550000');
        INSERT INTO chat VALUES (1, '+15555550100'), (2, '+19995550000');
        INSERT INTO message VALUES (1, 'old message', NULL, 0, 1, 0, 0, NULL);
        INSERT INTO message VALUES (2, 'status', NULL, 0, 1, 0, 0, NULL);
        INSERT INTO message VALUES (3, 'from someone else', NULL, 0, 2, 0, 0, NULL);
        INSERT INTO message VALUES (4, 'Loved “status”', NULL, 0, 1, 0, 2000, NULL);
        INSERT INTO message VALUES (5, NULL, X'\(hex)', 0, 1, 0, 0, NULL);
        INSERT INTO message VALUES (6, 'what I sent them', NULL, 1, 1, 0, 0, 'P:+15555559999');
        INSERT INTO chat_message_join VALUES (1,1),(1,2),(2,3),(1,4),(1,5),(1,6);
        """
        try? FileManager.default.removeItem(at: db)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        try? p.run(); p.waitUntilExit()
        let saved = IMessage.databaseURL
        IMessage.databaseURL = db
        defer { IMessage.databaseURL = saved }
        do {
            let batch = try IMessage.messages(after: 1, handle: "(555) 555-0100")
            print("      imessage rows: \(batch.messages.map { "\($0.rowId):\($0.text):\($0.isFromMe)" }) last=\(batch.lastRow)")
            check(batch.messages.map(\.text) == ["status", "approve 3", "what I sent them"], "reads your chat (incl. attributedBody), skips reactions and other chats")
            check(batch.lastRow == 6, "moves past every message it looked at")
            check(try IMessage.latestRowId() == 6, "finds the newest message")
            check(try IMessage.ownHandles() == ["+15555559999"], "learns this Mac's own handles")
        } catch {
            check(false, "reading the stand-in chat.db: \(error)")
        }
    }

    /// `--coordtest` (also part of `--selftest`): a coordinator hands a task to a project thread, gets its report,
    /// and sends that thread a follow-up.
    static func coordinator(_ model: AppModel) async {
        let dir = model.store.root.appendingPathComponent("selftest-coord-project")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var project = Project(path: dir.path)
        project.name = "coordproj"
        model.projects.append(project)
        let c = model.createThread(projectId: nil, select: false)
        model.updateThread(c) { $0.isCoordinator = true }
        model.send("""
        Hand exactly one task to the project coordproj, titled "Echo", whose message is: \
        "Reply with exactly the word: kumquat". When its report arrives, hand that same thread (use its id) one more \
        task whose message is: "Reply with exactly the word: persimmon". When that second report arrives, reply with \
        exactly the word: finished. Don't do anything else.
        """, in: c)
        let all = await waitUntil(300) {
            let child = model.threads.first { $0.reportsTo == c }
            let childDone = child.map { !model.runningThreadIds.contains($0.id) && model.queuedMessages[$0.id] == nil } ?? false
            let reports = model.threads.first { $0.id == c }?.items.filter { $0.kind == .user && Dispatch.isReport($0.text) }.count ?? 0
            return childDone && reports >= 2 && !model.runningThreadIds.contains(c) && model.queuedMessages[c] == nil
        }
        let coord = model.threads.first { $0.id == c }!
        let children = model.threads.filter { $0.reportsTo == c }
        print("      coordinator items: \(coord.items.filter { $0.kind != .toolResult }.map { "\($0.kind.rawValue): \($0.text.prefix(90))" })")
        check(all, "coordinator got two reports and finished")
        check(children.count == 1, "exactly one thread started (\(children.count))")
        if let child = children.first {
            let replies = child.items.filter { $0.kind == .assistant }.map(\.text)
            print("      child: \(child.title) in \(model.project(for: child)?.name ?? "?"), replies \(replies)")
            check(child.projectId == project.id && child.title == "Echo", "it's in the named project with the given title")
            check(replies.first?.lowercased().contains("kumquat") == true && replies.last?.lowercased().contains("persimmon") == true,
                  "the follow-up went to the same thread")
        }
        let reports = coord.items.filter { $0.kind == .user && Dispatch.isReport($0.text) }.map(\.text)
        check(reports.first?.lowercased().contains("kumquat") == true, "the report carries the thread's answer")
        check(coord.items.last(where: { $0.kind == .assistant })?.text.lowercased().contains("finished") == true,
              "coordinator wrapped up")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: model.store.dispatchDir(for: c).path)) ?? []
        check(leftovers.isEmpty, "outbox emptied")
    }

    static func steps(_ model: AppModel) async {
        model.detectedClaude = ClaudeLocator.locate()
        check(model.claude != nil, "found claude")
        guard model.claude != nil else { return }
        model.checkAuth()
        _ = await waitUntil(30) { model.auth != nil }
        check(model.auth?.loggedIn == true && model.auth?.usesSubscription == true,
              "signed in on a subscription (\(model.auth?.method ?? "?"), \(model.auth?.plan ?? "?"))")
        await coordinator(model)

        // 1. Chat with streaming + a queued follow-up.
        let t = model.createThread(projectId: nil, select: false)
        model.send("Reply with exactly the word: pong", in: t)
        check(model.runningThreadIds.contains(t), "thread starts running")
        model.send("Reply with exactly the word: second", in: t)
        check(model.queuedMessages[t]?.count == 1, "second message is queued while busy")
        let done = await waitUntil {
            return !model.runningThreadIds.contains(t) && model.queuedMessages[t] == nil
                && (model.threads.first { $0.id == t }?.items.filter { $0.kind == .result }.count ?? 0) >= 2
        }
        check(done, "both messages answered")
        let thread = model.threads.first { $0.id == t }!
        let replies = thread.items.filter { $0.kind == .assistant }.map(\.text)
        print("      replies: \(replies)")
        check(replies.first?.lowercased().contains("pong") == true, "first reply says pong")
        check(replies.last?.lowercased().contains("second") == true, "queued reply answered in the same session")
        check(thread.title.hasPrefix("Reply with exactly"), "title from first message")
        // Streaming: a longer reply should be visible half-written.
        let st = model.createThread(projectId: nil, select: false)
        model.send("Count from 1 to 60, one number per line, nothing else.", in: st)
        var partials = Set<Int>()
        let end = Date().addingTimeInterval(120)
        while model.runningThreadIds.contains(st), Date() < end {
            if let last = model.threads.first(where: { $0.id == st })?.items.last, last.kind == .assistant {
                partials.insert(last.text.count)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        print("      distinct partial lengths seen: \(partials.count)")
        check(partials.count >= 3, "reply grew while Claude was writing it (streaming)")
        check(!model.usage.isEmpty, "usage captured: \(model.usage.map { "\($0.label) \(Int($0.utilization * 100))%" })")

        // 1b. Project memory edits reach a resumed session (system prompt isn't frozen at the first message).
        let dir = model.store.root.appendingPathComponent("selftest-project")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = Project(path: dir.path)
        model.projects.append(project)
        model.saveMemory("codeword: alpaca", for: project)
        let pt = model.createThread(projectId: project.id, select: false)
        model.send("What is the codeword in the project memory? Reply with only the codeword.", in: pt)
        _ = await waitUntil { !model.runningThreadIds.contains(pt) }
        model.saveMemory("codeword: zebra", for: project)
        model.send("Check the project memory in your system prompt again. What is the codeword now? Reply with only the codeword.", in: pt)
        _ = await waitUntil { !model.runningThreadIds.contains(pt) }
        let memReplies = model.threads.first { $0.id == pt }!.items.filter { $0.kind == .assistant }.map(\.text)
        print("      memory replies: \(memReplies)")
        check(memReplies.first?.lowercased().contains("alpaca") == true, "memory seen on first message")
        check(memReplies.last?.lowercased().contains("zebra") == true, "updated memory seen after resume")

        // 1c. A project thread on its own branch runs in a git worktree, and stays there.
        let repo = model.store.root.appendingPathComponent("selftest-repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/bin/sh")
        git.arguments = ["-c", "cd '\(repo.path)' && git init -q && echo hi > a.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init"]
        try? git.run(); git.waitUntilExit()
        var repoProject = Project(path: repo.path)
        repoProject.effort = "low"
        repoProject.permissionMode = .acceptEdits
        model.projects.append(repoProject)
        let defaultsThread = model.createThread(projectId: repoProject.id, select: false)
        let dt = model.threads.first { $0.id == defaultsThread }
        check(dt?.effort == "low" && dt?.permissionMode == .acceptEdits && dt?.model == "haiku", "new threads use the project's defaults")
        model.deleteThread(defaultsThread)
        repoProject.permissionMode = nil
        model.updateProject(repoProject)
        let wt = model.createThread(projectId: repoProject.id, select: false)
        model.updateThread(wt) { $0.useWorktree = true }
        model.send("Run `git branch --show-current` and reply with only its output.", in: wt)
        _ = await waitUntil { !model.runningThreadIds.contains(wt) }
        model.send("Run `pwd` and reply with only its output.", in: wt)
        _ = await waitUntil { !model.runningThreadIds.contains(wt) }
        let wtThread = model.threads.first { $0.id == wt }!
        let wtReplies = wtThread.items.filter { $0.kind == .assistant }.map(\.text)
        print("      worktree: \(wtThread.workingDirectory ?? "-") branch: \(wtThread.branch ?? "-") replies: \(wtReplies)")
        check(wtThread.workingDirectory?.contains(".claude/worktrees/automate-") == true, "thread moved into its worktree")
        check(wtReplies.first?.contains("worktree-automate-") == true && wtReplies.first?.contains(wtThread.branch ?? "?") == true,
              "first reply ran on the worktree branch")
        check(wtReplies.last?.contains(".claude/worktrees/automate-") == true, "second message ran in the worktree too")

        // 1d. Send Later: a scheduled message goes out on the tick after its time.
        let lt = model.createThread(projectId: nil, select: false)
        model.schedule("Reply with exactly the word: later", at: Date().addingTimeInterval(2), in: lt)
        model.tick()
        check(!model.runningThreadIds.contains(lt), "scheduled message waits for its time")
        try? await Task.sleep(for: .seconds(3))
        model.tick()
        check(model.runningThreadIds.contains(lt) && model.threads.first { $0.id == lt }?.scheduled == nil, "scheduled message sent when due")
        _ = await waitUntil { !model.runningThreadIds.contains(lt) }
        check(model.threads.first { $0.id == lt }?.items.last { $0.kind == .assistant }?.text.lowercased().contains("later") == true,
              "scheduled message answered")

        // 1e. iMessage: the chat.db reader against a stand-in database with Messages' schema.
        runIMessageReader()

        // 2. Remote commands (no channels on, so replies are only returned here).
        check(model.handleRemote("help", from: .telegram)?.contains("Automate commands") == true, "help")
        let status = model.handleRemote("status", from: .telegram) ?? ""
        check(status.contains("Nothing is waiting"), "status with empty inbox")
        check(model.handleRemote("threads", from: .telegram)?.contains("1. ") == true, "threads list")
        check(model.handleRemote("use 1", from: .telegram)?.contains("Now talking to") == true, "use 1")
        check(model.remoteThreadId != nil, "remote thread set")
        check(model.handleRemote("approve", from: .telegram) == "Nothing is waiting for you.", "approve with nothing waiting")
        model.settings.messaging.allowRemoteChat = true
        let before = model.threads.first { $0.id == model.remoteThreadId }?.items.count ?? 0
        let ack = model.handleRemote("Reply with exactly the word: remote", from: .imessage)
        check(ack == "💭 On it…", "remote chat acknowledged on iMessage")
        let remoteDone = await waitUntil { !model.runningThreadIds.contains(model.remoteThreadId!) }
        let after = model.threads.first { $0.id == model.remoteThreadId }!.items
        check(remoteDone && after.count > before && after.last { $0.kind == .assistant }?.text.lowercased().contains("remote") == true,
              "remote chat answered in the current thread")
        check(model.remoteReplies.isEmpty, "remote reply bookkeeping cleared")

        // 2b. Asking for a reminder by text makes a one-off loop.
        let beforeLoops = Set(model.store.loadLoops().map(\.id))
        _ = model.handleRemote("new Set up a reminder for 2099-01-01 09:00 to renew my passport. Turn it on.", from: .telegram)
        _ = await waitUntil { !model.runningThreadIds.contains(model.remoteThreadId!) }
        let made = model.store.loadLoops().filter { !beforeLoops.contains($0.id) }
        check(model.loops.contains { $0.id == made.first?.id }, "imported into the app right after the reply")
        print("      new loops: \(made.map { "\($0.id): \($0.scheduleText ?? "-") enabled=\($0.enabled) warnings=\($0.warnings)" })")
        check(made.count == 1 && made[0].schedule == Schedule.parse("once 2099-01-01 09:00"), "reminder loop written with a once schedule")
        check(made.first?.enabled == true && made.first?.warnings.isEmpty == true, "reminder is on and parses cleanly")
        for l in made { try? FileManager.default.removeItem(at: l.fileURL) }

        // 2c. Safety: a thread-written loop asking for bypass permissions arrives switched off.
        let risky = "---\nname: Risky\nenabled: true\nschedule: every 1m\npermission: bypassPermissions\n---\nrm things"
        try? risky.write(to: model.store.incomingLoopsDir.appendingPathComponent("risky.md"), atomically: true, encoding: .utf8)
        model.importIncomingLoops()
        let imported = model.loops.first { $0.name == "Risky" }
        check(imported != nil && imported?.enabled == false, "risky imported loop is switched off")
        check(model.store.loadLoops().first { $0.name == "Risky" }?.enabled == false, "…in its file too")
        if let imported { try? FileManager.default.removeItem(at: imported.fileURL) }
        model.reloadLoops()
        // A loop file that appears (or is edited) outside Automate with a check: is switched off until you OK it.
        let sneaky = model.store.loopsDir.appendingPathComponent("sneaky.md")
        try? "---\nname: Sneaky\nenabled: true\nschedule: every 5m\ncheck: echo pwned\n---\nx".write(to: sneaky, atomically: true, encoding: .utf8)
        model.reloadLoops()
        check(model.loops.first { $0.id == "sneaky" }?.enabled == false, "a loop that appears with a check: is switched off")
        model.setEnabled(true, for: model.loops.first { $0.id == "sneaky" }!)
        check(model.loops.first { $0.id == "sneaky" }?.enabled == true, "switching it on in Automate OKs it")
        try? "---\nname: Sneaky\nenabled: true\nschedule: every 5m\ncheck: echo changed\n---\nx".write(to: sneaky, atomically: true, encoding: .utf8)
        model.reloadLoops()
        check(model.loops.first { $0.id == "sneaky" }?.enabled == false, "editing its check: outside Automate switches it off again")
        try? FileManager.default.removeItem(at: sneaky)
        model.reloadLoops()

        // A reminder that comes due during a pause still runs after it (it isn't skipped).
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let soon = Calendar.current.date(bySetting: .second, value: 0, of: Date().addingTimeInterval(60))!
        model.createLoopFile(named: "remind-me", contents: "---\nname: remind-me\nenabled: true\nschedule: once \(f.string(from: soon))\nmodel: haiku\n---\nReply with: Reminder")
        model.reloadLoops()
        model.pauseLoops(until: .distantFuture)
        model.pauseLoops(until: nil)
        let later = soon.addingTimeInterval(30)
        check(LoopScheduler.dueLoops(model.loops, state: model.loopState, now: later).contains { $0.id == "remind-me" },
              "a one-off reminder isn't skipped by pausing")
        if let r = model.loops.first(where: { $0.id == "remind-me" }) { try? FileManager.default.removeItem(at: r.fileURL) }

        // A thread-written loop that pre-approves shell or file tools arrives switched off.
        try? "---\nname: Tooly\nenabled: true\nschedule: every 1h\nallowed_tools: [Bash]\n---\nx".write(
            to: model.store.incomingLoopsDir.appendingPathComponent("tooly.md"), atomically: true, encoding: .utf8)
        model.importIncomingLoops()
        check(model.loops.first { $0.name == "Tooly" }?.enabled == false, "a thread's loop with Bash pre-approved is switched off")
        if let t = model.loops.first(where: { $0.name == "Tooly" }) { try? FileManager.default.removeItem(at: t.fileURL) }
        model.reloadLoops()

        // Casual words don't approve anything unless Automate just asked; huge numbers don't crash.
        check(model.handleRemote("yes", from: .telegram) == nil || model.runningThreadIds.contains(model.remoteThreadId!),
              "a casual \"yes\" goes to the chat")
        _ = await waitUntil { !model.runningThreadIds.contains(model.remoteThreadId!) }
        check(model.handleRemote("use -9223372036854775808", from: .telegram) != "crash", "huge numbers don't crash")
        _ = await waitUntil { !model.runningThreadIds.contains(model.remoteThreadId!) }

        // 2d. Links can't run loops unless allowed; an A ↔ B chain runs each once.
        for (id, other) in [("chain-a", "chain-b"), ("chain-b", "chain-a")] {
            model.createLoopFile(named: id, contents: "---\nname: \(id)\nenabled: true\nafter: [\(other)]\nautonomy: auto\nmodel: haiku\neffort: low\n---\nReply with only: done")
        }
        model.reloadLoops()
        model.handle(.run(loop: "chain-a"))
        check(!model.isRunning(loopId: "chain-a"), "automate://run doesn't start a loop unless links may act")
        model.runNow(model.loops.first { $0.id == "chain-a" }!)
        _ = await waitUntil { model.runs(for: "chain-b").first?.status.isFinished == true }
        try? await Task.sleep(for: .seconds(5))
        _ = await waitUntil(60) { model.runningLoopCount == 0 }
        check(model.runs(for: "chain-a").count == 1 && model.runs(for: "chain-b").count == 1,
              "A after B after A runs each once (a: \(model.runs(for: "chain-a").count), b: \(model.runs(for: "chain-b").count))")
        check(model.runs(for: "chain-b").first?.trigger == .after, "B was started by the chain")
        for l in model.loops where l.id.hasPrefix("chain-") { try? FileManager.default.removeItem(at: l.fileURL) }
        model.reloadLoops()

        // 2e. check: Claude runs only when the check's output changes.
        model.createLoopFile(named: "checked", contents: "---\nname: checked\nenabled: true\ncheck: cat state.txt\nautonomy: auto\nmodel: haiku\neffort: low\n---\nReply with only: seen")
        model.reloadLoops()
        let checked = model.loops.first { $0.id == "checked" }!
        let stateFile = model.store.loopDataDir(for: "checked").appendingPathComponent("state.txt")
        try? "a".write(to: stateFile, atomically: true, encoding: .utf8)
        model.enqueueAutomatic(checked, trigger: .schedule)
        _ = await waitUntil(60) { model.runs(for: "checked").first?.status.isFinished == true }
        check(model.runs(for: "checked").count == 1, "first check runs Claude")
        model.enqueueAutomatic(checked, trigger: .schedule)
        try? await Task.sleep(for: .seconds(4))
        check(model.runs(for: "checked").count == 1 && !model.isRunning(loopId: "checked"), "unchanged check skips Claude")
        try? "b".write(to: stateFile, atomically: true, encoding: .utf8)
        model.enqueueAutomatic(checked, trigger: .schedule)
        _ = await waitUntil(60) { model.runs(for: "checked").count == 2 && model.runs(for: "checked").first?.status.isFinished == true }
        check(model.runs(for: "checked").count == 2 && model.runs(for: "checked").first?.items.contains { $0.text.contains("check's output changed") } == true,
              "changed check runs Claude and says why")
        try? FileManager.default.removeItem(at: checked.fileURL)
        model.reloadLoops()

        // 2f. Project loops: file and notes live in <project>/.automate; a file that shows up there (e.g. via git) is
        // switched off until you OK it; moving a loop carries its notes and history.
        let fm = FileManager.default
        let projDir = model.store.root.appendingPathComponent("proj-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        let proj = Project(path: projDir.path)
        model.projects.append(proj)
        let pulled = Store.projectLoopsDir(proj)
        try? fm.createDirectory(at: pulled, withIntermediateDirectories: true)
        try? "---\nname: Pulled\nenabled: true\nschedule: every 5m\n---\nx".write(to: pulled.appendingPathComponent("pulled.md"), atomically: true, encoding: .utf8)
        model.reloadLoops()
        let pulledId = Store.projectLoopId(project: proj, stem: "pulled")
        check(model.loops.first { $0.id == pulledId }?.enabled == false, "a loop file that appears in a project is switched off")
        let madeURL = model.createLoopFile(named: "Proj hi", contents: "---\nname: Proj hi\nenabled: true\nautonomy: auto\npermission: acceptEdits\nmodel: haiku\neffort: low\n---\nCreate a file hi.txt containing hi in your notes folder, then reply with only: done", in: proj)
        model.reloadLoops()
        let projLoop = model.loops.first { $0.id == Store.loopId(for: madeURL, in: proj) }
        check(projLoop?.enabled == true && projLoop.map(model.isRiskAccepted) == true, "a project loop made in Automate stays on")
        if let projLoop {
            model.runNow(projLoop)
            _ = await waitUntil(90) { model.runs(for: projLoop.id).first?.status.isFinished == true }
            let hi = projDir.appendingPathComponent(".automate/loop-data/proj-hi/hi.txt")
            check(model.runs(for: projLoop.id).first?.status == .succeeded && fm.fileExists(atPath: hi.path),
                  "a project loop runs and keeps its notes in the project")
            model.moveLoop(projLoop, to: nil)
            let movedOut = model.loops.first { $0.id == "proj-hi" }
            check(movedOut?.projectId == nil && movedOut?.enabled == true && model.runs(for: "proj-hi").count == 1
                  && fm.fileExists(atPath: model.store.loopDataDir(for: "proj-hi").appendingPathComponent("hi.txt").path)
                  && !fm.fileExists(atPath: madeURL.path),
                  "moving a loop out of a project keeps it on, with its notes and runs")
            if let movedOut {
                model.moveLoop(movedOut, to: proj)
                check(model.loops.first { $0.id == projLoop.id }?.enabled == true
                      && fm.fileExists(atPath: projDir.appendingPathComponent(".automate/loop-data/proj-hi/hi.txt").path),
                      "…and moving it back in")
            }
        }
        model.projects.removeAll { $0.id == proj.id }
        try? fm.removeItem(at: projDir)
        model.reloadLoops()

        // 3. An "ask" loop that needs approval, approved by text, then its follow-up.
        let loopText = """
        ---
        name: Selftest ask
        enabled: false
        autonomy: ask
        model: haiku
        effort: low
        timeout: 5m
        ---
        Propose one action: writing the word hello to hello.txt in your notes folder. Keep it to one short line.
        """
        model.createLoopFile(named: "selftest-ask", contents: loopText)
        model.reloadLoops()
        guard let loop = model.loops.first(where: { $0.id == "selftest-ask" }) else { return check(false, "loop loaded") }
        let started = model.handleRemote("run selftest", from: .telegram) ?? ""
        check(started.contains("Started Selftest ask"), "run loop by text: \(started)")
        let asked = await waitUntil { model.runs.first { $0.loopId == loop.id }?.status.isFinished == true }
        // (No channels are on in the self-test, so pretend the approval request was texted.)
        model.messaging.markAwaitingApproval(on: .telegram)
        let run = model.runs.first { $0.loopId == loop.id }!
        check(asked && run.status == .needsApproval, "ask loop needs approval (\(run.status))")
        check(run.approvalNumber != nil, "approval number assigned")
        check(model.handleRemote("status", from: .telegram)?.contains("#\(run.approvalNumber ?? 0)") == true, "status lists it")
        let statusButtons = model.remoteButtons(for: .status)?.flatMap { $0 }.map(\.1) ?? []
        check(statusButtons.contains("approve:\(run.id.uuidString)") && statusButtons.contains("skip:\(run.id.uuidString)"),
              "status on Telegram has Approve/Skip buttons for it")
        check(model.remoteButtons(for: .loops)?.flatMap { $0 }.contains { $0.1 == "run:selftest-ask" } == true, "loops on Telegram has run buttons")
        model.snooze(runId: run.id, until: Date().addingTimeInterval(2))
        check(!model.inbox.contains { $0.id == run.id } && model.snoozedCount == 1, "a snoozed run leaves the Inbox")
        try? await Task.sleep(for: .seconds(2.5))
        model.tick()
        check(model.inbox.contains { $0.id == run.id }, "it comes back when the snooze ends")
        // If the loop file gains a risky setting outside Automate while waiting, approving it is refused.
        let askText = (try? String(contentsOf: loop.fileURL, encoding: .utf8)) ?? ""
        try? askText.replacingOccurrences(of: "timeout: 5m", with: "timeout: 5m\npermission: bypassPermissions")
            .write(to: loop.fileURL, atomically: true, encoding: .utf8)
        model.approve(runId: run.id)
        check(model.runs.first { $0.id == run.id }?.status == .needsApproval, "approval refused after an un-OK'd risky edit")
        try? askText.write(to: loop.fileURL, atomically: true, encoding: .utf8)
        model.reloadLoops()
        check(model.followUp(onRun: run.id, message: "sounds good, do it", replyVia: .telegram)?.contains("waiting for your OK") == true,
              "a reply to a waiting run can't become a chat that acts on it")
        let approved = model.handleRemote("approve \(run.approvalNumber ?? 0) keep it short", from: .telegram) ?? ""
        check(approved.contains("Approved"), "approve by number: \(approved)")
        let followed = await waitUntil { model.runs.first { $0.parentRunId == run.id }?.status.isFinished == true }
        let child = model.runs.first { $0.parentRunId == run.id }
        check(followed && child?.status == .succeeded, "follow-up run succeeded (\(child?.status.rawValue ?? "none"))")
        check(child?.items.contains { $0.kind == .user && $0.text == "keep it short" } == true, "note passed along")
        let hello = model.store.loopDataDir(for: loop).appendingPathComponent("hello.txt")
        check(FileManager.default.fileExists(atPath: hello.path), "follow-up did the approved action")
        let notesRow = model.runs.first { $0.parentRunId == run.id }?.items.first { $0.toolName == "Notes changed" }
        check(notesRow?.text.contains("hello.txt") == true && notesRow?.detail?.contains("+ ") == true,
              "run shows what it changed in its notes (\(notesRow?.text ?? "none"))")
        let feedback = (try? String(contentsOf: model.store.loopDataDir(for: loop).appendingPathComponent("feedback.md"), encoding: .utf8)) ?? ""
        check(feedback.contains("Approved") && feedback.contains("keep it short"), "approval and note recorded in feedback.md")
        check(model.handleRemote("approve \(run.approvalNumber ?? 0)", from: .telegram)?.contains("already") == true, "double approve refused")
        check(!model.messaging.isAwaitingApproval(on: .telegram), "answering clears the approval context")

        // 4. Asking about a finished run (a Telegram swipe-reply or a notification reply) continues its session.
        if let child {
            model.settings.messaging.allowRemoteChat = false
            check(model.followUp(onRun: child.id, message: "hi", replyVia: .telegram)?.contains("is off") == true,
                  "follow-ups by text respect \"chat by text\" being off")
            model.settings.messaging.allowRemoteChat = true
            _ = model.followUp(onRun: child.id, message: "What word did you write into hello.txt? Reply with only that word.", replyVia: .telegram)
            let ft = model.threads.first { $0.followsRunId == child.id }
            check(ft != nil, "follow-up thread made for the run")
            _ = await waitUntil { ft.map { !model.runningThreadIds.contains($0.id) } ?? true }
            let answer = model.threads.first { $0.followsRunId == child.id }?.items.last { $0.kind == .assistant }?.text ?? ""
            print("      follow-up answer: \(answer)")
            check(answer.lowercased().contains("hello"), "follow-up remembers what the run did")
            check(model.threads.first { $0.followsRunId == child.id }?.sessionId == child.sessionId, "follow-up resumed the run's own session")
            check(model.remoteThreadId == ft?.id, "later texts go to the follow-up thread")
        }
    }
}
#endif

#if DEBUG
import SwiftUI

/// `--keytest`: does a TextEditor's onKeyPress see Return before the text view inserts a newline?
@MainActor
enum KeyTest {
    final class Box: ObservableObject { @Published var text = "hello"; var fired = 0 }

    struct Probe: View {
        @ObservedObject var box: Box
        @FocusState var focused: Bool
        var body: some View {
            TextEditor(text: $box.text)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    box.fired += 1
                    return .handled
                }
                .onAppear { focused = true }
        }
    }

    static func run() {
        NSApp.setActivationPolicy(.accessory)
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Probe(box: box))
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                func key(_ shift: Bool) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                        window.sendEvent(e)
                    }
                }
                func find(_ v: NSView) -> NSTextView? {
                    if let t = v as? NSTextView { return t }
                    for s in v.subviews { if let t = find(s) { return t } }
                    return nil
                }
                if let tv = find(window.contentView!) { window.makeFirstResponder(tv) }
                print("first responder: \(String(describing: window.firstResponder))")
                key(false)
                key(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("fired=\(box.fired) text=\(box.text.debugDescription)")
                    exit(0)
                }
            }
        }
    }
}
#endif

#if DEBUG
/// `--telegramtest` (run from the repo folder): drives the real MessagingHub + TelegramClient against
/// scripts/fake-telegram.py on 127.0.0.1 — pairing, commands, buttons, chat, files, approvals and swipe-replies.
@MainActor
enum TelegramTest {
    static let base = "http://127.0.0.1:18765"

    static func push(_ update: [String: Any]) async {
        var req = URLRequest(url: URL(string: base + "/control/push")!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["update": update])
        _ = try? await URLSession.shared.data(for: req)
    }

    static func sent() async -> [[String: Any]] {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: base + "/control/sent")!),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    static func message(_ text: String, chat: Int = 42, type: String = "private", extra: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["message_id": Int.random(in: 1000...9999), "chat": ["id": chat, "type": type], "text": text]
        for (k, v) in extra { m[k] = v }
        return ["message": m]
    }

    /// Waits until a sent message to `chat` matches.
    static func waitForSent(_ timeout: TimeInterval = 120, chat: Int = 42, after: Int = 0,
                            _ match: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let all = await sent()
            if let hit = all.dropFirst(after).first(where: { ($0["chat_id"] as? Int) == chat && match($0) }) { return hit }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    static func text(_ m: [String: Any]?) -> String { m?["text"] as? String ?? "" }

    static func run() {
        guard ProcessInfo.processInfo.environment["AUTOMATE_DATA_DIR"] != nil else { print("Set AUTOMATE_DATA_DIR"); exit(1) }
        NSApp.setActivationPolicy(.accessory)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", FileManager.default.currentDirectoryPath + "/scripts/fake-telegram.py", "18765"]
        try? server.run()
        Task { @MainActor in
            defer { server.terminate() }
            try? await Task.sleep(for: .seconds(1))
            await steps()
            print(SelfTest.failures == 0 ? "ALL PASSED" : "\(SelfTest.failures) FAILED")
            server.terminate()
            exit(SelfTest.failures == 0 ? 0 : 1)
        }
    }

    static func steps() async {
        let check = SelfTest.check
        let model = AppModel.shared
        model.bootstrapped = true
        model.settings.defaultModel = "haiku"
        model.settings.defaultEffort = "low"
        model.settings.messaging = MessagingSettings()
        model.settings.messaging.allowRemoteChat = true
        model.detectedClaude = ClaudeLocator.locate()
        TelegramClient.apiBase = base
        model.messaging.telegramToken = "TEST:TOKEN"
        model.settings.messaging.telegramEnabled = true
        model.messaging.restart()
        check(await SelfTest.waitUntil(15) { model.messaging.telegramConnected }, "connects to the bot")
        check(model.settings.messaging.telegramBotName == "automate_test_bot", "learns the bot's name")

        // Pairing: wrong code, group chats and other chats are refused; the right code pairs.
        await push(message("/start 00000000"))
        check(text(await waitForSent(10) { text($0).contains("pairing code") }).contains("8-digit"), "wrong code asks for the pairing code")
        await push(message("/start \(model.messaging.pairingCode)", chat: -77, type: "group"))
        try? await Task.sleep(for: .seconds(2))
        check(model.settings.messaging.telegramChatId == nil, "a group chat can't pair")
        await push(message("/start \(model.messaging.pairingCode)"))
        check(text(await waitForSent(10) { text($0).contains("Paired") }).contains("Paired"), "the right code pairs")
        check(model.settings.messaging.telegramChatId == 42, "paired chat remembered")
        let afterPair = (await sent()).count
        await push(message("status", chat: 99))
        try? await Task.sleep(for: .seconds(2))
        check(!(await sent()).dropFirst(afterPair).contains { ($0["chat_id"] as? Int) == 99 }, "other chats are ignored")

        // Commands and buttons.
        await push(message("status"))
        check(await waitForSent(10, after: afterPair) { text($0).contains("Nothing is waiting") } != nil, "status replies")
        model.createLoopFile(named: "selftest-tg", contents: "---\nname: Selftest tg\nenabled: false\nautonomy: ask\nmodel: haiku\neffort: low\ntimeout: 5m\n---\nPropose one action: writing the word hello to hello.txt in your notes folder. One short line.")
        model.reloadLoops()
        await push(message("loops"))
        let loopsMsg = await waitForSent(10, after: afterPair) { text($0).contains("Loops:") }
        let keyboard = ((loopsMsg?["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]])?.flatMap { $0 } ?? []
        check(keyboard.contains { ($0["callback_data"] as? String) == "run:selftest-tg" }, "loops has ▶️ buttons")

        // Chat, with typing… and formatting.
        let beforeChat = (await sent()).count
        await push(message("Reply with exactly the word: pong"))
        let pong = await waitForSent(120, after: beforeChat) { text($0).lowercased().contains("pong") }
        check(pong != nil, "chat reply comes back")
        check((await sent()).dropFirst(beforeChat).contains { ($0["method"] as? String) == "sendChatAction" }, "shows typing while working")

        // Skills are learned from the session's init event.
        let beforeSkills = (await sent()).count
        await push(message("skills"))
        check(await waitForSent(10, after: beforeSkills) { text($0).hasPrefix("Skills:") && text($0).contains("simplify") } != nil, "skills lists Claude's skills")

        // Swipe-reply to a chat answer goes back to that thread, even after switching to a new one.
        await push(message("/new"))
        _ = await waitForSent(10, after: beforeSkills) { text($0).contains("New research thread") }
        let beforeThreadReply = (await sent()).count
        await push(message("What exact word did you just reply with? Reply with only that word, reversed.",
                           extra: ["reply_to_message": ["message_id": pong?["id"] ?? 0]]))
        check(await waitForSent(120, after: beforeThreadReply) { text($0).lowercased().contains("gnop") } != nil, "swipe-reply to a chat answer continues its thread")

        // A document is downloaded and handed to Claude.
        let beforeDoc = (await sent()).count
        await push(["message": ["message_id": 501, "chat": ["id": 42, "type": "private"], "caption": "What's the secret word in this file? Reply with only the word.",
                                "document": ["file_id": "doc1", "file_name": "secret.txt", "file_size": 26]]])
        check(await waitForSent(120, after: beforeDoc) { text($0).lowercased().contains("mango") } != nil, "files reach Claude")

        // Run a loop by button; approve it by button; the result comes back; buttons are cleared.
        let beforeRun = (await sent()).count
        await push(["callback_query": ["id": "cb1", "from": ["id": 42], "message": ["message_id": loopsMsg?["id"] ?? 1, "chat": ["id": 42]],
                                       "data": "run:selftest-tg"]])
        let approval = await waitForSent(180, after: beforeRun) { text($0).contains("needs you") }
        check(approval != nil, "approval request texted")
        check(approval?["parse_mode"] as? String == "HTML", "approval is formatted")
        let approveData = ((approval?["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]])?.flatMap { $0 }
            .compactMap { $0["callback_data"] as? String }.first { $0.hasPrefix("approve:") }
        check(approveData != nil, "approval has an Approve button")
        let beforeApprove = (await sent()).count
        await push(["callback_query": ["id": "cb2", "from": ["id": 42], "message": ["message_id": approval?["id"] ?? 1, "chat": ["id": 42]],
                                       "data": approveData ?? ""]])
        let result = await waitForSent(180, after: beforeApprove) { text($0).hasPrefix("✅ Selftest tg") || text($0).contains("<b>✅ Selftest tg") }
        check(result != nil, "approved follow-up's result texted")
        check((await sent()).contains { ($0["method"] as? String) == "editMessageReplyMarkup" }, "approval buttons cleared")

        // Swipe-reply to the result: asks about that run in its own session.
        let beforeReply = (await sent()).count
        await push(message("What word did you write into hello.txt? Reply with only that word.",
                           extra: ["reply_to_message": ["message_id": result?["id"] ?? 0]]))
        check(await waitForSent(120, after: beforeReply) { text($0).lowercased().contains("hello") } != nil, "swipe-reply answered from the run's session")
        if ProcessInfo.processInfo.environment["SHOW_SENT"] != nil {
            for m in await sent() where m["text"] != nil {
                print("---- \(m["parse_mode"] as? String ?? "plain")\n\(text(m))")
            }
        }
    }
}
#endif

#if DEBUG
@MainActor protocol DeprecatedRunner { static func runReader() }
extension SelfTest: DeprecatedRunner {
    @available(macOS, deprecated: 10.13)
    static func runReader() { imessageReader() }
}
#endif
