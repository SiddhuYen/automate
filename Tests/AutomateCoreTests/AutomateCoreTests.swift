import XCTest
@testable import AutomateCore

final class FrontmatterTests: XCTestCase {
    func testParsesScalarsListsAndBody() {
        let text = """
        ---
        name: "Internship scout"
        schedule: daily 09:00   # morning
        triggers: [wake, launch]
        allowed_tools:
          - WebSearch
          - WebFetch
        enabled: yes
        ---
        Find new roles.
        """
        let (meta, body) = Frontmatter.parse(text)
        XCTAssertEqual(meta["name"]?.string, "Internship scout")
        XCTAssertEqual(meta["schedule"]?.string, "daily 09:00")
        XCTAssertEqual(meta["triggers"]?.list, ["wake", "launch"])
        XCTAssertEqual(meta["allowed_tools"]?.list, ["WebSearch", "WebFetch"])
        XCTAssertEqual(meta["enabled"]?.bool, true)
        XCTAssertEqual(body, "Find new roles.")
    }

    func testCommentsAfterListsAndQuotes() {
        let (meta, _) = Frontmatter.parse("---\ntriggers: []   # launch, wake\non: [wake] # c\nname: \"A # B\"  # note\n---\nx")
        XCTAssertEqual(meta["triggers"]?.list, [])
        XCTAssertEqual(meta["on"]?.list, ["wake"])
        XCTAssertEqual(meta["name"]?.string, "A # B")
    }

    func testNoFrontmatter() {
        let (meta, body) = Frontmatter.parse("just text")
        XCTAssertTrue(meta.isEmpty)
        XCTAssertEqual(body, "just text")
    }
}

final class ScheduleTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = cal.timeZone
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    func testParse() {
        XCTAssertEqual(Schedule.parse("every 30m"), .interval(1800))
        XCTAssertEqual(Schedule.parse("hourly"), .interval(3600))
        XCTAssertEqual(Schedule.parse("weekdays 18:30"), .weekly(days: [2, 3, 4, 5, 6], hour: 18, minute: 30))
        XCTAssertEqual(Schedule.parse("mon,wed 07:05"), .weekly(days: [2, 4], hour: 7, minute: 5))
        XCTAssertNil(Schedule.parse("sometimes"))
        XCTAssertNil(Schedule.parse("daily 25:00"))
    }

    func testOnce() {
        Schedule.calendarTimeZone = cal.timeZone
        let s = Schedule.parse("once 2026-11-02 17:00")!
        XCTAssertEqual(s, .once(date("2026-11-02T17:00:00")))
        XCTAssertEqual(s.description, "once 2026-11-02 17:00")
        let created = date("2026-11-01T09:00:00")
        XCTAssertFalse(s.isDue(now: date("2026-11-02T16:59:00"), lastRun: created, catchUp: true, calendar: cal))
        XCTAssertTrue(s.isDue(now: date("2026-11-02T17:00:30"), lastRun: created, catchUp: true, calendar: cal))
        // Already ran: never again.
        XCTAssertFalse(s.isDue(now: date("2026-11-03T17:00:00"), lastRun: date("2026-11-02T17:00:30"), catchUp: true, calendar: cal))
        XCTAssertNil(s.nextOccurrence(after: date("2026-11-03T00:00:00"), lastRun: date("2026-11-02T17:00:30"), calendar: cal))
        XCTAssertNil(Schedule.parse("once tomorrow 5pm"))
    }

    func testCron() {
        XCTAssertEqual(Schedule.parse("0 7 * * 1-5"), .weekly(days: [2, 3, 4, 5, 6], hour: 7, minute: 0))
        XCTAssertEqual(Schedule.parse("30 18 * * *"), .weekly(days: Set(1...7), hour: 18, minute: 30))
        XCTAssertEqual(Schedule.parse("15 9 * * 0,6"), .weekly(days: [1, 7], hour: 9, minute: 15))
        XCTAssertEqual(Schedule.parse("0 9 * * sun"), .weekly(days: [1], hour: 9, minute: 0))
        XCTAssertEqual(Schedule.parse("*/15 * * * *"), .interval(900))
        XCTAssertEqual(Schedule.parse("0 */2 * * *"), .interval(7200))
        XCTAssertNil(Schedule.parse("0 9 1 * *"))
        XCTAssertNil(Schedule.parse("0 9 * * 1-9"))
    }

    func testDailyDueAndCatchUp() {
        let s = Schedule.parse("daily 09:00")!
        let lastRun = date("2026-10-29T09:01:00")
        // 09:05 the next day: due.
        XCTAssertTrue(s.isDue(now: date("2026-10-30T09:05:00"), lastRun: lastRun, catchUp: false, calendar: cal))
        // 08:59: not yet.
        XCTAssertFalse(s.isDue(now: date("2026-10-30T08:59:00"), lastRun: lastRun, catchUp: true, calendar: cal))
        // Asleep until 14:00: only with catch-up.
        XCTAssertTrue(s.isDue(now: date("2026-10-30T14:00:00"), lastRun: lastRun, catchUp: true, calendar: cal))
        XCTAssertFalse(s.isDue(now: date("2026-10-30T14:00:00"), lastRun: lastRun, catchUp: false, calendar: cal))
        // Already ran today.
        XCTAssertFalse(s.isDue(now: date("2026-10-30T14:00:00"), lastRun: date("2026-10-30T09:00:30"),
                               catchUp: true, calendar: cal))
    }

    func testWeekdaysSkipWeekend() {
        let s = Schedule.parse("weekdays 09:00")!
        // Sat Oct 31 2026 10:00, last ran Fri 09:00 -> most recent weekday slot is Fri, already done.
        XCTAssertFalse(s.isDue(now: date("2026-10-31T10:00:00"), lastRun: date("2026-10-30T09:00:10"),
                               catchUp: true, calendar: cal))
        let next = s.nextOccurrence(after: date("2026-10-31T10:00:00"), lastRun: nil, calendar: cal)
        XCTAssertEqual(next, date("2026-11-02T09:00:00"))
    }

    func testInterval() {
        let s = Schedule.parse("every 2h")!
        let last = date("2026-10-30T09:00:00")
        XCTAssertFalse(s.isDue(now: date("2026-10-30T10:59:00"), lastRun: last, catchUp: true, calendar: cal))
        XCTAssertTrue(s.isDue(now: date("2026-10-30T11:00:00"), lastRun: last, catchUp: true, calendar: cal))
    }
}

final class EventParserTests: XCTestCase {
    func testInit() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc","model":"opus","cwd":"/r/.claude/worktrees/x"}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line), [.sessionStarted(sessionId: "abc", model: "opus", cwd: "/r/.claude/worktrees/x")])
        var req = ClaudeRequest(prompt: "x", cwd: URL(fileURLWithPath: "/r"))
        req.worktree = "automate-1"
        XCTAssertTrue(req.arguments().contains("--worktree"))
        req.resumeSessionId = "s"
        XCTAssertFalse(req.arguments().contains("--worktree"))
    }

    func testAssistantTextAndTool() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line),
                       [.text("Looking"), .toolUse(id: "t1", name: "Bash", summary: "ls -la")])
    }

    func testEditDiff() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/a.swift","old_string":"let x = 1\nlet y = 2","new_string":"let x = 3"}}]}}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line),
                       [.toolUse(id: "t2", name: "Edit", summary: "/a.swift", detail: "- let x = 1\n- let y = 2\n+ let x = 3")])
        XCTAssertEqual(ClaudeEventParser.editDiff(tool: "MultiEdit", input: ["edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": ""]]]),
                       "- a\n+ b\n@@\n- c")
        XCTAssertNil(ClaudeEventParser.editDiff(tool: "Bash", input: ["command": "ls"]))
        let big = ClaudeEventParser.editDiff(tool: "Write", input: ["content": String(repeating: "x\n", count: 500)], maxLines: 10)!
        XCTAssertTrue(big.hasSuffix("… 491 more lines"))
        var items: [TranscriptItem] = []
        var o = TranscriptReducer.Outcome()
        TranscriptReducer.apply(.toolUse(id: "1", name: "Edit", summary: "f", detail: "+ y"), to: &items, outcome: &o)
        XCTAssertEqual(items.first?.detail, "+ y")
    }

    func testToolResultArrayContent() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"ok"}],"is_error":false}]}}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line), [.toolResult(toolUseId: "t1", text: "ok", isError: false)])
    }

    func testResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.12,"session_id":"abc","duration_ms":900}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line),
                       [.result(text: "done", isError: false, costUSD: 0.12, sessionId: "abc", durationMs: 900)])
    }

    func testIgnoresSubagentTraffic() {
        let line = #"{"type":"assistant","parent_tool_use_id":"x","message":{"content":[{"type":"text","text":"sub"}]}}"#
        XCTAssertTrue(ClaudeEventParser.parse(line: line).isEmpty)
    }
}

final class LoopTests: XCTestCase {
    func testStatusDecisions() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let split = LoopDefinition.parse(text: "---\nautonomy: split\n---\nDo it", fileURL: url)
        XCTAssertEqual(LoopPromptBuilder.status(for: split, resultText: "Did A.\n\n## Needs approval\n- B", isError: false), .needsApproval)
        XCTAssertEqual(LoopPromptBuilder.status(for: split, resultText: "Did A.", isError: false), .succeeded)
        XCTAssertEqual(LoopPromptBuilder.status(for: split, resultText: "NOTHING_TO_DO", isError: false), .nothingToDo)
        let ask = LoopDefinition.parse(text: "---\nautonomy: ask\n---\nDo it", fileURL: url)
        XCTAssertEqual(LoopPromptBuilder.status(for: ask, resultText: "## Proposed actions\n- x", isError: false), .needsApproval)
        XCTAssertEqual(LoopPromptBuilder.request(for: ask, trigger: .manual, dataDir: URL(fileURLWithPath: "/tmp/d")).permissionMode, .plan)
    }

    func testChromeFlag() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let dataDir = URL(fileURLWithPath: "/tmp/d")
        let plain = LoopDefinition.parse(text: "---\nautonomy: ask\n---\nDo it", fileURL: url)
        XCTAssertFalse(plain.chrome)
        let plainReq = LoopPromptBuilder.request(for: plain, trigger: .manual, dataDir: dataDir)
        XCTAssertFalse(plainReq.arguments().contains("--chrome"))
        XCTAssertFalse(plainReq.appendSystemPrompt!.contains("Claude in Chrome"))

        let browsing = LoopDefinition.parse(text: "---\nautonomy: ask\nchrome: true\n---\nDo it", fileURL: url)
        XCTAssertTrue(browsing.chrome)
        let req = LoopPromptBuilder.request(for: browsing, trigger: .manual, dataDir: dataDir)
        XCTAssertTrue(req.arguments().contains("--chrome"))
        XCTAssertTrue(req.appendSystemPrompt!.contains("Claude in Chrome"))
        // The extension refuses plan mode, so browsing "ask" loops run in dontAsk with look-only tools.
        XCTAssertEqual(req.permissionMode, .dontAsk)
        XCTAssertTrue(req.allowedTools.contains("mcp__claude-in-chrome__get_page_text"))
        XCTAssertFalse(req.allowedTools.contains("mcp__claude-in-chrome__form_input"))
        let withWrites = LoopDefinition.parse(text: "---\nautonomy: ask\nchrome: true\nallowed_tools: [WebFetch, Write, Bash(rm:*), mcp__gmail__search]\n---\nDo it", fileURL: url)
        let wReq = LoopPromptBuilder.request(for: withWrites, trigger: .manual, dataDir: dataDir)
        XCTAssertFalse(wReq.allowedTools.contains("Write"))
        XCTAssertFalse(wReq.allowedTools.contains("Bash(rm:*)"))
        XCTAssertTrue(wReq.allowedTools.contains("mcp__gmail__search"))
        XCTAssertEqual(wReq.allowedTools.filter { $0 == "WebFetch" }.count, 1)
        let split = LoopDefinition.parse(text: "---\nautonomy: split\nchrome: true\n---\nDo it", fileURL: url)
        XCTAssertEqual(LoopPromptBuilder.request(for: split, trigger: .manual, dataDir: dataDir).permissionMode, .auto)
        let approval = LoopPromptBuilder.approvalRequest(for: browsing, sessionId: "s", note: "", dataDir: dataDir)
        XCTAssertTrue(approval.arguments().contains("--chrome"))
    }
}

final class ProjectMemoryTests: XCTestCase {
    func testFileNameIsStableAndUniquePerPath() {
        let a = ProjectMemory.fileName(name: "My App", path: "/Users/me/code/my-app")
        XCTAssertEqual(a, ProjectMemory.fileName(name: "My App", path: "/Users/me/code/my-app"))
        XCTAssertTrue(a.hasPrefix("my-app-") && a.hasSuffix(".md"))
        XCTAssertNotEqual(a, ProjectMemory.fileName(name: "My App", path: "/Users/me/work/my-app"))
    }

    func testAttachAppendsPromptAndAddsFolderOnce() {
        let file = URL(fileURLWithPath: "/tmp/automate-memory/app-1234.md")
        var req = ClaudeRequest(prompt: "hi", cwd: URL(fileURLWithPath: "/tmp/app"))
        req.appendSystemPrompt = "Existing."
        ProjectMemory.attach(to: &req, file: file, contents: "- uses pnpm\n")
        ProjectMemory.attach(to: &req, file: file, contents: "")
        XCTAssertTrue(req.appendSystemPrompt!.hasPrefix("Existing.\n\n"))
        XCTAssertTrue(req.appendSystemPrompt!.contains("- uses pnpm"))
        XCTAssertTrue(req.appendSystemPrompt!.contains("(empty)"))
        XCTAssertEqual(req.addDirs.map(\.path), ["/tmp/automate-memory"])
    }
}

final class StreamingTests: XCTestCase {
    func testTextDeltaParsing() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}},"parent_tool_use_id":null}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: delta), [.textDelta("Hel")])
        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}}"#
        XCTAssertTrue(ClaudeEventParser.parse(line: thinking).isEmpty)
        let sub = #"{"type":"stream_event","parent_tool_use_id":"t9","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}"#
        XCTAssertTrue(ClaudeEventParser.parse(line: sub).isEmpty)
    }

    func testReducerReplacesStreamedText() {
        var items: [TranscriptItem] = []
        var outcome = TranscriptReducer.Outcome()
        for e: ClaudeEvent in [.textDelta("Hel"), .textDelta("lo"), .text("Hello."),
                               .toolUse(id: "t", name: "Bash", summary: "ls"),
                               .textDelta("Do"), .textDelta("ne"), .text("Done!")] {
            TranscriptReducer.apply(e, to: &items, outcome: &outcome)
        }
        XCTAssertEqual(items.map(\.text), ["Hello.", "ls", "Done!"])
        // Without deltas, text blocks still append normally.
        TranscriptReducer.apply(.text("More"), to: &items, outcome: &outcome)
        XCTAssertEqual(items.last?.text, "More")
        XCTAssertEqual(items.count, 4)
    }

    func testUsageEvent() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793570400,"rateLimitType":"seven_day","unifiedWindows":{"seven_day":{"utilization":0.36,"resetsAt":1793570400,"status":"allowed"},"five_hour":{"utilization":0.1,"resetsAt":1793500000,"status":"allowed"}}}}"#
        guard case let .usage(w)? = ClaudeEventParser.parse(line: line).first else { return XCTFail() }
        XCTAssertEqual(w.map(\.name), ["five_hour", "seven_day"])
        XCTAssertEqual(w[1].utilization, 0.36)
        XCTAssertEqual(w[1].label, "7-day")
    }

    func testRequestFlags() {
        var req = ClaudeRequest(prompt: "x", cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(req.arguments().contains("--include-partial-messages"))
        req.streamText = true
        XCTAssertTrue(req.arguments().contains("--include-partial-messages"))
        ProjectMemory.attach(to: &req, file: URL(fileURLWithPath: "/tmp/m/a.md"), contents: "")
        let args = req.arguments()
        XCTAssertEqual(args[args.firstIndex(of: "--system-prompt-snapshot")! + 1], "off")
    }

    func testTimeoutUnits() {
        XCTAssertEqual(LoopDefinition.parseMinutes("45"), 45)
        XCTAssertEqual(LoopDefinition.parseMinutes("45m"), 45)
        XCTAssertEqual(LoopDefinition.parseMinutes("1h"), 60)
        XCTAssertEqual(LoopDefinition.parseMinutes("1.5 hours"), 90)
        XCTAssertEqual(LoopDefinition.parseMinutes("90 min"), 90)
        XCTAssertNil(LoopDefinition.parseMinutes("soon"))
        let loop = LoopDefinition.parse(text: "---\ntimeout: 2h\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertEqual(loop.timeoutMinutes, 120)
    }
}

final class RemoteCommandTests: XCTestCase {
    func testBareStop() {
        for t in ["stop", " Stop. ", "STOP!", "/stop"] { XCTAssertTrue(RemoteCommand.isBareStop(t), t) }
        for t in ["stop doing that", "don't stop", "cancel", "stopped", ""] { XCTAssertFalse(RemoteCommand.isBareStop(t), t) }
    }

    func testParse() {
        XCTAssertEqual(RemoteCommand.parse("status"), .status)
        XCTAssertEqual(RemoteCommand.parse("/status@AutomateBot"), .status)
        XCTAssertEqual(RemoteCommand.parse("approve"), .approve(number: nil, note: ""))
        XCTAssertEqual(RemoteCommand.parse("approve 12"), .approve(number: 12, note: ""))
        XCTAssertEqual(RemoteCommand.parse("approve #3 only the first two"), .approve(number: 3, note: "only the first two"))
        XCTAssertEqual(RemoteCommand.parse("yes 4"), .approve(number: 4, note: ""))
        XCTAssertEqual(RemoteCommand.parse("skip"), .skip(number: nil))
        XCTAssertEqual(RemoteCommand.parse("skip 7"), .skip(number: 7))
        XCTAssertEqual(RemoteCommand.parse("run stock watch"), .runLoop("stock watch"))
        XCTAssertEqual(RemoteCommand.parse("use 2"), .use(2))
        XCTAssertEqual(RemoteCommand.parse("new"), .new(""))
        XCTAssertEqual(RemoteCommand.parse("/new what's the weather in Paris"), .new("what's the weather in Paris"))
        XCTAssertEqual(RemoteCommand.parse("/help"), .help)
        // Casual answers are chat unless Automate just asked for an approval.
        XCTAssertEqual(RemoteCommand.parse("Yes!"), .chat("Yes!"))
        XCTAssertEqual(RemoteCommand.parse("Yes!", expectingApproval: true), .approve(number: nil, note: ""))
        XCTAssertEqual(RemoteCommand.parse("no"), .chat("no"))
        XCTAssertEqual(RemoteCommand.parse("no", expectingApproval: true), .skip(number: nil))
        XCTAssertEqual(RemoteCommand.parse("approve but skip the last one"), .chat("approve but skip the last one"))
        XCTAssertEqual(RemoteCommand.parse("approve but skip the last one", expectingApproval: true),
                       .approve(number: nil, note: "but skip the last one"))
        // Sentences that start with a command word stay chat.
        XCTAssertEqual(RemoteCommand.parse("yes and also check NVDA", expectingApproval: true), .chat("yes and also check NVDA"))
        XCTAssertEqual(RemoteCommand.parse("no I meant the other repo"), .chat("no I meant the other repo"))
        XCTAssertEqual(RemoteCommand.parse("Skip the details, just answer", expectingApproval: true), .chat("Skip the details, just answer"))
        XCTAssertEqual(RemoteCommand.parse("New York weather?"), .chat("New York weather?"))
        XCTAssertEqual(RemoteCommand.parse("use 2 spaces for indents"), .chat("use 2 spaces for indents"))
        XCTAssertEqual(RemoteCommand.parse("stop using tabs please"), .chat("stop using tabs please"))
        XCTAssertEqual(RemoteCommand.parse("What changed in the repo today?"), .chat("What changed in the repo today?"))
        // Nothing overflows.
        XCTAssertEqual(RemoteCommand.parse("use -9223372036854775808"), .chat("use -9223372036854775808"))
        XCTAssertEqual(RemoteCommand.parse("use 0"), .chat("use 0"))
        XCTAssertEqual(RemoteCommand.parse("approve 99999999999999999999"), .chat("approve 99999999999999999999"))
    }

    func testPlainAndClip() {
        let md = "## Found\n\n\n**Two** roles:\n- [Acme](https://acme.dev) intern\n```\ncode\n```"
        XCTAssertEqual(RemoteText.plain(md), "Found\n\nTwo roles:\n• Acme (https://acme.dev) intern\ncode")
        let long = String(repeating: "word ", count: 100)
        let clipped = RemoteText.clip(long, limit: 100)
        XCTAssertLessThanOrEqual(clipped.count, 100)
        XCTAssertTrue(clipped.hasSuffix("(full text in Automate)"))
        XCTAssertEqual(RemoteText.clip("short", limit: 100), "short")
    }

    func testSameHandle() {
        XCTAssertTrue(RemoteText.sameHandle("(555) 555-0100", "+15555550100"))
        XCTAssertTrue(RemoteText.sameHandle("Me@iCloud.com", "me@icloud.com"))
        XCTAssertFalse(RemoteText.sameHandle("+15555550100", "+15555550101"))
        XCTAssertFalse(RemoteText.sameHandle("me@icloud.com", "+15555550100"))
        XCTAssertFalse(RemoteText.sameHandle("+447700900123", "+917700900123"))
    }

    func testTelegramUpdates() throws {
        let json = #"[{"update_id":5,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"status"}},{"update_id":6,"callback_query":{"id":"cb1","from":{"id":42},"message":{"message_id":9,"chat":{"id":42}},"data":"approve:abc"}},{"update_id":7,"edited_message":{}}]"#
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let updates = TelegramClient.parseUpdates(obj)
        XCTAssertEqual(updates.count, 3)
        var first = TelegramClient.Update(updateId: 5, chatId: 42, kind: .message(text: "status"))
        first.messageId = 1
        XCTAssertEqual(updates[0], first)
        XCTAssertEqual(updates[1], .init(updateId: 6, chatId: 42, kind: .button(callbackId: "cb1", data: "approve:abc", messageId: 9)))
        XCTAssertEqual(updates[2].updateId, 7)
        let photo = #"[{"update_id":8,"message":{"chat":{"id":42,"type":"private"},"caption":"what is this?","photo":[{"file_id":"small","file_size":10},{"file_id":"big","file_size":900}]}},{"update_id":9,"message":{"chat":{"id":42,"type":"group"},"document":{"file_id":"d1","file_name":"cv.pdf","file_size":5}}}]"#
        let p = TelegramClient.parseUpdates(try JSONSerialization.jsonObject(with: Data(photo.utf8)))
        XCTAssertEqual(p[0].kind, .message(text: "what is this?", files: [.init(id: "big", name: "photo-8.jpg", size: 900)]))
        XCTAssertEqual(p[1].kind, .message(text: "", files: [.init(id: "d1", name: "cv.pdf", size: 5)]))
        XCTAssertEqual(p[1].chatType, "group")
        let reply = #"[{"update_id":10,"message":{"message_id":91,"chat":{"id":42,"type":"private"},"text":"why?","reply_to_message":{"message_id":77}}}]"#
        let r = TelegramClient.parseUpdates(try JSONSerialization.jsonObject(with: Data(reply.utf8)))[0]
        XCTAssertEqual(r.replyTo, 77)
        XCTAssertEqual(r.messageId, 91)
    }

    func testAttributedBodyDecode() throws {
        let attr = NSAttributedString(string: "approve 3 — only the first")
        let data = NSArchiver.archivedData(withRootObject: attr)
        XCTAssertEqual(IMessageText.decode(attributedBody: data), "approve 3 — only the first")
        let longText = String(repeating: "x", count: 300)
        XCTAssertEqual(IMessageText.decode(attributedBody: NSArchiver.archivedData(withRootObject: NSAttributedString(string: longText))), longText)
    }
}

final class MarkdownBlockTests: XCTestCase {
    func testBlocks() {
        let md = """
        ## Summary
        Two **new** roles
        found today.

        - Acme [link](https://a.dev)
          continues here
        - [x] done
        1. first
        2) second

        ```swift
        let x = 1
        ```
        > quoted
        > more
        ---
        | Company | Fit |
        |---|:-:|
        | Acme | 9 |
        | Beta |
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 2, text: "Summary"),
            .paragraph("Two **new** roles\nfound today."),
            .listItem(marker: "•", indent: 0, text: "Acme [link](https://a.dev)\ncontinues here"),
            .listItem(marker: "☑", indent: 0, text: "done"),
            .listItem(marker: "1.", indent: 0, text: "first"),
            .listItem(marker: "2.", indent: 0, text: "second"),
            .code(language: "swift", text: "let x = 1"),
            .quote("quoted\nmore"),
            .rule,
            .table(header: ["Company", "Fit"], rows: [["Acme", "9"], ["Beta", ""]]),
        ])
    }

    func testUnclosedFenceWhileStreaming() {
        XCTAssertEqual(MarkdownBlock.parse("Here:\n```\nls -la"), [.paragraph("Here:"), .code(language: "", text: "ls -la")])
    }

    func testHashtagIsNotHeading() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag text"), [.paragraph("#hashtag text")])
        XCTAssertEqual(MarkdownBlock.parse("  - nested"), [.listItem(marker: "•", indent: 1, text: "nested")])
    }
}

final class LoopWriterTests: XCTestCase {
    func testExtract() {
        XCTAssertEqual(LoopWriter.extract("```markdown\n---\nname: X\n---\nDo it\n```"), "---\nname: X\n---\nDo it\n")
        XCTAssertEqual(LoopWriter.extract("Here you go:\n---\nname: X\n---\nBody"), "---\nname: X\n---\nBody\n")
        XCTAssertEqual(LoopWriter.extract("---\nname: X\n---\nBody"), "---\nname: X\n---\nBody\n")
    }

    func testRequestHasNoTools() {
        let req = LoopWriter.request(description: "check HN daily", cwd: URL(fileURLWithPath: "/tmp"), projectPath: nil)
        let args = req.arguments()
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(req.prompt.contains("check HN daily"))
    }
}

final class LoopFileEditorTests: XCTestCase {
    func testUpdateKeepsCommentAndReplacesBlockList() {
        let text = "---\nname: X\nschedule: daily 09:00   # morning\nallowed_tools:\n  - Read\n  - Write\nmodel: opus\n---\nBody"
        let a = LoopFileEditor.updated(text, key: "schedule", value: "weekdays 07:00")
        XCTAssertTrue(a.contains("schedule: weekdays 07:00   # morning"))
        let b = LoopFileEditor.updated(text, key: "allowed_tools", value: "[Read]")
        XCTAssertEqual(b, "---\nname: X\nschedule: daily 09:00   # morning\nallowed_tools: [Read]\nmodel: opus\n---\nBody")
        let c = LoopFileEditor.updated(text, key: "notify", value: "always")
        XCTAssertTrue(c.contains("model: opus\nnotify: always\n---"))
    }

    func testRemoving() {
        let text = "---\nname: X\nschedule: daily 09:00\ntriggers:\n  - wake\nmodel: opus\n---\nBody"
        XCTAssertEqual(LoopFileEditor.removing(text, key: "triggers"), "---\nname: X\nschedule: daily 09:00\nmodel: opus\n---\nBody")
        XCTAssertEqual(LoopFileEditor.removing(text, key: "nothing"), text)
    }
}

final class ExportTests: XCTestCase {
    func testMarkdownExport() {
        let items = [
            TranscriptItem(kind: .user, text: "hi"),
            TranscriptItem(kind: .toolUse, text: "ls `x`", toolName: "Bash", toolUseId: "1"),
            TranscriptItem(kind: .toolResult, text: "secret output", toolUseId: "1"),
            TranscriptItem(kind: .assistant, text: "Hello!"),
        ]
        let md = TranscriptExport.markdown(title: "T", items: items)
        XCTAssertEqual(md, "# T\n\n**You:**\n\nhi\n\n> 🔧 Bash: `ls 'x'`\n\nHello!\n")
        XCTAssertFalse(TranscriptExport.markdown(title: "T", items: items, includeTools: false).contains("Bash"))
    }

    func testForkFlag() {
        var req = ClaudeRequest(prompt: "x", cwd: URL(fileURLWithPath: "/tmp"))
        req.forkSession = true
        XCTAssertFalse(req.arguments().contains("--fork-session")) // nothing to fork without a session
        req.resumeSessionId = "abc"
        XCTAssertEqual(Array(req.arguments().suffix(from: req.arguments().firstIndex(of: "--resume")!).prefix(3)), ["--resume", "abc", "--fork-session"])
    }
}

final class TemplateTests: XCTestCase {
    func testBlankLoopParsesCleanly() {
        let t = LoopTemplates.blank
        let loop = LoopDefinition.parse(text: t.contents, fileURL: URL(fileURLWithPath: "/tmp/\(t.fileName).md"))
        XCTAssertTrue(loop.warnings.isEmpty, "\(loop.warnings)")
        XCTAssertFalse(loop.enabled)
        XCTAssertFalse(loop.instructions.isEmpty)
    }

    /// Commented settings and quoted shell commands, as people write them in loop files.
    func testCommentedFrontmatterAndChecks() {
        let recap = LoopDefinition.parse(text: """
            ---
            schedule: sun 18:00
            cwd: ~/code                  # the folder that holds your repos
            allowed_tools: [Read, Glob, Grep]   # read-only
            ---
            Recap my week.
            """, fileURL: URL(fileURLWithPath: "/tmp/r.md"))
        XCTAssertEqual(recap.schedule, .weekly(days: [1], hour: 18, minute: 0))
        XCTAssertEqual(recap.allowedTools, ["Read", "Glob", "Grep"])
        XCTAssertEqual(recap.cwd, "~/code")
        let triage = LoopDefinition.parse(text: """
            ---
            check: gh issue list --label bug --state open --json number --jq '.[].number'   # Claude runs only when this changes
            ---
            Triage.
            """, fileURL: URL(fileURLWithPath: "/tmp/t.md"))
        XCTAssertEqual(triage.check, "gh issue list --label bug --state open --json number --jq '.[].number'")
        let watcher = LoopDefinition.parse(text: """
            ---
            check: curl -sL --max-time 20 "https://example.com/careers" | sed -e 's/<[^>]*>//g' | tr -s ' \\n'   # edit the address
            ---
            Watch.
            """, fileURL: URL(fileURLWithPath: "/tmp/p.md"))
        XCTAssertEqual(watcher.check, #"curl -sL --max-time 20 "https://example.com/careers" | sed -e 's/<[^>]*>//g' | tr -s ' \n'"#)
    }
}

final class StoreTests: XCTestCase {
    func testProjectLoopsLiveInTheProject() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("automate-projloops-\(UUID())")
        defer { try? fm.removeItem(at: tmp) }
        let store = Store(root: tmp.appendingPathComponent("data"))
        let folder = tmp.appendingPathComponent("My Novel")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(path: folder.path)
        let text = "---\nname: Daily words\nschedule: daily 09:00\n---\nCount words."

        store.createLoop(named: "daily", contents: text) // a global loop with the same file name
        let url = store.createLoop(named: "Daily", contents: text, in: project)
        XCTAssertEqual(url.path, folder.appendingPathComponent(".automate/loops/daily.md").path)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".automate/.gitignore"), encoding: .utf8), "loop-data/\n")
        XCTAssertEqual(Store.loopId(for: url, in: project), "my-novel/daily")

        let loops = store.loadLoops(projects: [project])
        XCTAssertEqual(Set(loops.map(\.id)), ["daily", "my-novel/daily"])
        let loop = try XCTUnwrap(loops.first { $0.projectId == project.id })
        XCTAssertEqual(loop.workingDirectory(dataDir: store.loopDataDir(for: loop)).path, folder.path)
        XCTAssertEqual(store.loopDataDir(for: loop).path, folder.appendingPathComponent(".automate/loop-data/daily").path)
        XCTAssertTrue(loop.riskSignature.hasPrefix("project"), "a project loop file needs your OK (it may come with git)")
        XCTAssertEqual(loop.reparsed(text).riskSignature, loop.riskSignature)
        XCTAssertEqual(store.loadLoops().map(\.id), ["daily"], "without the project, only Automate's own loops")

        let before = store.loopsFingerprint(projects: [project])
        try "x".write(to: Store.projectLoopsDir(project).appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(store.loopsFingerprint(projects: [project]), before)
    }

    func testAfterMatchesProjectLoopFileName() {
        var a = LoopDefinition.parse(text: "---\nname: A\n---\nx", fileURL: URL(fileURLWithPath: "/p/.automate/loops/a.md"))
        a.id = "p/a"
        let b = LoopDefinition.parse(text: "---\nname: B\nafter: [a]\n---\ny", fileURL: URL(fileURLWithPath: "/tmp/b.md"))
        XCTAssertEqual(LoopScheduler.loops(after: a, in: [a, b], state: Store.LoopState(), now: Date()).map(\.id), ["b"])
    }

    func testThreadPromptMentionsProject() {
        let p = LoopWriter.threadPrompt(newLoopsDir: URL(fileURLWithPath: "/tmp/new"), projectPath: "/Users/x/novel")
        XCTAssertTrue(p.contains("project: /Users/x/novel"))
        XCTAssertFalse(LoopWriter.threadPrompt(newLoopsDir: URL(fileURLWithPath: "/tmp/new")).contains("project:"))
        XCTAssertTrue(p.contains("/Users/x/novel/.automate/loops/"), "threads in a project may edit its loops in place")
    }

    func testProjectLoopEditsThatLetItActChangeTheSignature() {
        let base = "---\nname: Scout\nschedule: daily 08:30\nallowed_tools: [WebSearch, Write, Edit]\n---\nFind things."
        var loop = LoopDefinition.parse(text: base, fileURL: URL(fileURLWithPath: "/p/.automate/loops/scout.md"))
        loop.projectRoot = URL(fileURLWithPath: "/p")
        XCTAssertEqual(loop.riskSignature, "project|tools:Edit,Write")
        XCTAssertEqual(loop.legacyRiskSignature, "project", "what was OK'd before acting settings counted")
        // Plain edits (instructions, schedule, model) keep it as OK'd.
        let tweaked = base.replacingOccurrences(of: "08:30", with: "09:00").replacingOccurrences(of: "Find things.", with: "Find more.")
        XCTAssertEqual(loop.reparsed(tweaked).riskSignature, loop.riskSignature)
        // Ones that let it do more on its own don't.
        let bash = base.replacingOccurrences(of: "Edit]", with: "Edit, Bash(git *)]")
        XCTAssertEqual(loop.reparsed(bash).riskSignature, "project|tools:Bash,Edit,Write")
        XCTAssertNotEqual(loop.reparsed(base.replacingOccurrences(of: "---\nFind", with: "permission: acceptEdits\n---\nFind")).riskSignature, loop.riskSignature)
        XCTAssertNotEqual(loop.reparsed(base.replacingOccurrences(of: "---\nFind", with: "cwd: ~/elsewhere\n---\nFind")).riskSignature, loop.riskSignature)
        // Automate's own loops aren't in a folder threads work in, so their signature is unchanged.
        let own = LoopDefinition.parse(text: base, fileURL: URL(fileURLWithPath: "/tmp/scout.md"))
        XCTAssertEqual(own.riskSignature, "")
        XCTAssertEqual(own.actingSettings, ["tools:Edit,Write"])
    }

    func testPruneKeepsRecentAndWaiting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automate-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        var old = LoopRun(loopId: "a", loopName: "A", trigger: .schedule)
        old.status = .succeeded
        old.startedAt = Date().addingTimeInterval(-200 * 86400)
        var waiting = old
        waiting.id = UUID()
        waiting.status = .needsApproval
        var recent = LoopRun(loopId: "a", loopName: "A", trigger: .schedule)
        recent.status = .failed
        for r in [old, waiting, recent] { store.save(r) }
        let past = Date().addingTimeInterval(-200 * 86400)
        for r in [old, waiting] {
            try FileManager.default.setAttributes([.modificationDate: past],
                                                  ofItemAtPath: store.runsDir.appendingPathComponent("\(r.id.uuidString).json").path)
        }
        XCTAssertEqual(store.pruneRuns(olderThan: 90), 1)
        XCTAssertEqual(Set(store.loadRuns().map(\.id)), [waiting.id, recent.id])
    }
}

final class ApprovalItemsTests: XCTestCase {
    func testParse() {
        let s = """
        Found 3 roles.
        - not this one

        ## Needs approval
        - Draft outreach to Acme
          - with the short intro
        - Apply to Beta
        1. Email the recruiter

        ## Notes
        - ignore me
        """
        XCTAssertEqual(ApprovalItems.parse(s), ["Draft outreach to Acme\nwith the short intro", "Apply to Beta", "Email the recruiter"])
        XCTAssertEqual(ApprovalItems.parse("### Proposed actions\n- One"), ["One"])
        XCTAssertEqual(ApprovalItems.parse("Nothing here"), [])
    }

    func testNote() {
        XCTAssertEqual(ApprovalItems.note(chosen: ["a", "b"], all: ["a", "b"], extra: " go "), "go")
        XCTAssertEqual(ApprovalItems.note(chosen: ["b"], all: ["a", "b"], extra: ""), "Only do these (skip the rest):\n- b")
        XCTAssertEqual(ApprovalItems.note(chosen: ["b"], all: ["a", "b"], extra: "fast"), "Only do these (skip the rest):\n- b\n\nfast")
    }
}

final class ApprovalSectionTests: XCTestCase {
    func testRemovingSection() {
        let s = "Found two.\n\n## Needs approval\n- a\n- b\n\n## Notes\nkept"
        XCTAssertEqual(ApprovalItems.removingSection(s), "Found two.\n\n## Notes\nkept")
    }
}

final class AutomateURLTests: XCTestCase {
    func testParse() {
        func p(_ s: String) -> AutomateURL? { AutomateURL.parse(URL(string: s)!) }
        XCTAssertEqual(p("automate://ask?text=What%27s%20new&project=my-app"), .ask(text: "What's new", project: "my-app", background: false))
        XCTAssertEqual(p("automate://ask?q=hi&background=1"), .ask(text: "hi", project: nil, background: true))
        XCTAssertEqual(p("automate://ask"), .quickAsk)
        XCTAssertEqual(p("automate://run/stock-watch"), .run(loop: "stock-watch"))
        XCTAssertEqual(p("automate://run?loop=Stock%20watch"), .run(loop: "Stock watch"))
        XCTAssertEqual(p("automate://open/loop/stock-watch"), .open(page: "loop", id: "stock-watch"))
        XCTAssertEqual(p("automate://open"), .open(page: "inbox", id: nil))
        XCTAssertNil(p("https://example.com"))
        XCTAssertNil(p("automate://delete/everything"))
    }
}

final class TelegramSplitTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(TelegramClient.split("short"), ["short"])
        let para = String(repeating: "word ", count: 500) // 2500 chars
        let parts = TelegramClient.split(para + "\n\n" + para, limit: 3000)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 3000 })
        // Emoji count double in UTF-16.
        let emoji = String(repeating: "😀", count: 3000)
        let e = TelegramClient.split(emoji, limit: 3900)
        XCTAssertTrue(e.allSatisfy { $0.utf16.count <= 3900 })
        XCTAssertEqual(e.joined().count, 3000)
        // Never more than maxParts.
        let huge = String(repeating: "a b\n", count: 20000)
        let h = TelegramClient.split(huge, limit: 1000, maxParts: 3)
        XCTAssertEqual(h.count, 3)
        XCTAssertTrue(h.allSatisfy { $0.utf16.count <= 1000 })
    }
}

final class LoopFileEditorQuoteTests: XCTestCase {
    func testQuotedValueWithHashIsNotAComment() {
        let text = "---\nname: \"Team  #1 sync\"\n---\nx"
        XCTAssertEqual(LoopFileEditor.updated(text, key: "name", value: "\"New\""), "---\nname: \"New\"\n---\nx")
    }
}

final class ApprovalPickTests: XCTestCase {
    func testPickAndNumbered() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(ApprovalItems.pick("1,3", from: items), ["a", "c"])
        XCTAssertEqual(ApprovalItems.pick("only 3 and 1", from: items), ["a", "c"])
        XCTAssertEqual(ApprovalItems.pick("2", from: items), ["b"])
        XCTAssertNil(ApprovalItems.pick("4", from: items))
        XCTAssertNil(ApprovalItems.pick("keep it short", from: items))
        XCTAssertNil(ApprovalItems.pick("", from: items))
        XCTAssertEqual(ApprovalItems.numbered("Found.\n\n## Needs approval\n- x\n- y"), "Found.\n\nNeeds approval:\n1. x\n2. y")
        XCTAssertEqual(ApprovalItems.numbered("## Needs approval\n- only one"), "## Needs approval\n- only one")
    }
}

final class PauseCommandTests: XCTestCase {
    func testPause() {
        XCTAssertEqual(RemoteCommand.parse("pause"), .pause(hours: nil))
        XCTAssertEqual(RemoteCommand.parse("pause 2h"), .pause(hours: 2))
        XCTAssertEqual(RemoteCommand.parse("pause 30m"), .pause(hours: 0.5))
        XCTAssertEqual(RemoteCommand.parse("pause 3"), .pause(hours: 3))
        XCTAssertEqual(RemoteCommand.parse("resume"), .resume)
        XCTAssertEqual(RemoteCommand.parse("result stock"), .result("stock"))
        XCTAssertEqual(RemoteCommand.parse("last one looks wrong"), .chat("last one looks wrong"))
        XCTAssertEqual(RemoteCommand.parse("pause the music"), .chat("pause the music"))
    }
}

final class ChainTests: XCTestCase {
    func testAfter() {
        let a = LoopDefinition.parse(text: "---\nname: Stock watch\n---\nx", fileURL: URL(fileURLWithPath: "/l/stock-watch.md"))
        let b = LoopDefinition.parse(text: "---\nname: Brief\nafter: [stock-watch]\n---\nx", fileURL: URL(fileURLWithPath: "/l/brief.md"))
        let c = LoopDefinition.parse(text: "---\nname: C\nafter: Stock Watch\nenabled: false\n---\nx", fileURL: URL(fileURLWithPath: "/l/c.md"))
        let d = LoopDefinition.parse(text: "---\nname: D\nafter: [Stock watch]\n---\nx", fileURL: URL(fileURLWithPath: "/l/d.md"))
        XCTAssertEqual(b.triggerSummary, "after stock-watch")
        var state = Store.LoopState()
        let now = Date()
        state.lastRun["d"] = now.addingTimeInterval(-60) // ran a minute ago: skipped (cycle guard)
        XCTAssertEqual(LoopScheduler.loops(after: a, in: [a, b, c, d], state: state, now: now).map(\.id), ["brief"])
    }
}

final class SessionImportTests: XCTestCase {
    func testSummaryAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID())")
        let dir = root.appendingPathComponent("-Users-me-code-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            #"{"type":"queue-operation"}"#,
            #"{"type":"user","cwd":"/Users/me/code/app","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"<ide_context>x</ide_context>"},{"type":"text","text":"Fix the login bug"}]}}"#,
            #"{"type":"assistant","cwd":"/Users/me/code/app","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}"#,
            #"{"type":"user","cwd":"/Users/me/code/app","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent noise"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-02T02:11:53.622Z","message":{"content":[{"type":"text","text":"Fixed."}]}}"#,
            #"{"type":"ai-title","aiTitle":"Login bug fix","sessionId":"s1"}"#,
        ]
        let file = dir.appendingPathComponent("s1.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let recent = SessionImport.recent(root: root)
        XCTAssertEqual(recent.map(\.id), ["s1"])
        XCTAssertEqual(recent.first?.cwd, "/Users/me/code/app")
        XCTAssertEqual(recent.first?.title, "Login bug fix")
        XCTAssertTrue(SessionImport.recent(root: root, skipping: ["/Users/me"]).isEmpty)
        let items = SessionImport.transcript(file)
        XCTAssertEqual(items.map(\.kind), [.user, .assistant, .toolUse, .toolResult, .assistant])
        XCTAssertEqual(items.first?.text, "Fix the login bug")
        XCTAssertEqual(items.last?.text, "Fixed.")
        XCTAssertEqual(items.last?.date.timeIntervalSince1970 ?? 0, 1_793_585_513.622, accuracy: 0.01)
    }
}

final class QuietHoursTests: XCTestCase {
    func testWindow() {
        XCTAssertTrue(QuietHours.contains(hour: 23, start: 22, end: 8))
        XCTAssertTrue(QuietHours.contains(hour: 3, start: 22, end: 8))
        XCTAssertFalse(QuietHours.contains(hour: 8, start: 22, end: 8))
        XCTAssertFalse(QuietHours.contains(hour: 12, start: 22, end: 8))
        XCTAssertTrue(QuietHours.contains(hour: 13, start: 12, end: 14))
        XCTAssertFalse(QuietHours.contains(hour: 14, start: 12, end: 14))
        XCTAssertFalse(QuietHours.contains(hour: 5, start: 5, end: 5))
    }
}

final class TrashTests: XCTestCase {
    func testDeleteRestoreAndEmpty() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automate-trash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let t = ChatThread(title: "T", projectId: nil, model: "opus", effort: "high", permissionMode: .auto)
        store.save(t)
        store.delete(t)
        XCTAssertTrue(store.loadThreads().isEmpty)
        XCTAssertEqual(store.restoreThread(id: t.id)?.title, "T")
        XCTAssertEqual(store.loadThreads().map(\.id), [t.id])
        store.delete(t)
        store.emptyTrash(olderThan: 30, now: Date().addingTimeInterval(31 * 86400))
        XCTAssertNil(store.restoreThread(id: t.id))
    }
}

final class SuggestionTests: XCTestCase {
    func testSplit() {
        let reply = "=====LOOP=====\n---\nname: A\n---\nDo A\n=====LOOP=====\n```\n---\nname: B\n---\nDo B\n```\n"
        XCTAssertEqual(LoopWriter.splitSuggestions(reply), ["---\nname: A\n---\nDo A\n", "---\nname: B\n---\nDo B\n"])
        let req = LoopWriter.suggestionsRequest(sessions: [("Fix CI", "~/code/app", Date())], existing: ["Stock watch"],
                                                cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(req.prompt.contains("Fix CI") && req.prompt.contains("Stock watch"))
        XCTAssertEqual(req.tools, [])
    }
}

final class WebhookTests: XCTestCase {
    func testFormats() throws {
        XCTAssertNil(Webhook("not a url"))
        XCTAssertNil(Webhook("ftp://x.com/a"))
        let d = Webhook("https://discord.com/api/webhooks/1/abc")!
        XCTAssertEqual(d.kind, .discord)
        let dj = try JSONSerialization.jsonObject(with: d.request(title: "T", body: "B").httpBody!) as! [String: Any]
        XCTAssertEqual(dj["content"] as? String, "T\n\nB")
        XCTAssertEqual((dj["allowed_mentions"] as? [String: [String]])?["parse"], [])
        let sj = try JSONSerialization.jsonObject(with: Webhook("https://hooks.slack.com/services/x")!.request(title: "<!channel>", body: "").httpBody!) as! [String: String]
        XCTAssertEqual(sj["text"], "&lt;!channel&gt;")
        XCTAssertEqual(Webhook("https://hooks.slack.com/services/x")!.kind, .slack)
        let n = Webhook("https://ntfy.sh/my-automate-8f2k")!
        XCTAssertEqual(n.kind, .ntfy)
        let nr = n.request(title: "🔔 Scout needs you", body: "3 roles")
        XCTAssertEqual(nr.value(forHTTPHeaderField: "Title"), "Scout needs you")
        XCTAssertEqual(String(data: nr.httpBody!, encoding: .utf8), "3 roles")
        XCTAssertEqual(Webhook("https://example.com/hook")!.kind, .generic)
    }
}

final class PickRangeTests: XCTestCase {
    func testLooksLikePick() {
        XCTAssertTrue(ApprovalItems.looksLikePick("4"))
        XCTAssertTrue(ApprovalItems.looksLikePick("only 1 and 9"))
        XCTAssertFalse(ApprovalItems.looksLikePick("keep it short"))
        XCTAssertFalse(ApprovalItems.looksLikePick(""))
    }
}

final class GitStatusTests: XCTestCase {
    func testParse() {
        let s = GitStatus.parse("## main...origin/main [ahead 2, behind 1]\n M Sources/a.swift\n?? notes.md\n")
        XCTAssertEqual(s, GitStatus(branch: "main", ahead: 2, behind: 1, changes: ["M Sources/a.swift", "?? notes.md"]))
        XCTAssertEqual(GitStatus.parse("## feature-x\n")?.changes, [])
        XCTAssertEqual(GitStatus.parse("## No commits yet on main\n")?.branch, "main")
        XCTAssertNil(GitStatus.parse("fatal: not a git repository"))
    }

    func testReadsRealRepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd '\(dir.path)' && git init -q -b trunk && echo x > a.txt"]
        try p.run(); p.waitUntilExit()
        let s = GitStatus.read(dir)
        XCTAssertEqual(s?.branch, "trunk")
        XCTAssertEqual(s?.changes, ["?? a.txt"])
        XCTAssertNil(GitStatus.read(FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")))
    }
}

final class LoopLearningTests: XCTestCase {
    func testRecentResultsInPrompt() {
        let loop = LoopDefinition.parse(text: "---\nautonomy: auto\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/l.md"))
        let req = LoopPromptBuilder.request(for: loop, trigger: .schedule, dataDir: URL(fileURLWithPath: "/tmp/d"),
                                            recent: [(Date(), "NVDA up 3%\nmore"), (Date(), "")])
        XCTAssertTrue(req.prompt.contains("NVDA up 3% more") && req.prompt.contains("<earlier-results>"))
        XCTAssertFalse(req.appendSystemPrompt!.contains("NVDA"))
        XCTAssertTrue(req.appendSystemPrompt!.contains("feedback.md"))
        let plain = LoopPromptBuilder.request(for: loop, trigger: .schedule, dataDir: URL(fileURLWithPath: "/tmp/d"))
        XCTAssertFalse(plain.prompt.contains("earlier-results"))
    }

    func testFeedbackFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = LoopFeedback.line(date: Date(timeIntervalSince1970: 0), decision: "Skipped", summary: "\nFound 3 roles\nmore", note: "too junior\nfor me")
        XCTAssertTrue(line.hasSuffix("Skipped: Found 3 roles — note: too junior / for me"))
        for i in 0..<105 { LoopFeedback.record("- \(i)", in: dir) }
        let text = try String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# What I approved"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 100)
        XCTAssertTrue(text.contains("- 104\n") && !text.contains("- 4\n"))
    }
}

final class AuthTests: XCTestCase {
    func testParse() {
        let a = ClaudeAuth.parse(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#)
        XCTAssertEqual(a, ClaudeAuth(loggedIn: true, method: "claude.ai", plan: "max"))
        XCTAssertTrue(a!.usesSubscription)
        XCTAssertFalse(ClaudeAuth.parse(#"noise {"loggedIn":true,"authMethod":"api-key"}"#)!.usesSubscription)
        XCTAssertNil(ClaudeAuth.parse("not json"))
    }
}

final class LineDiffTests: XCTestCase {
    func testDiff() {
        XCTAssertEqual(LineDiff.diff("a\nb\nc", "a\nB\nc"), ["  a", "- b", "+ B", "  c"])
        XCTAssertEqual(LineDiff.diff("1\n2\n3\n4\n5\n6\n7", "1\n2\n3\n4\n5\n6\n7\n8"), ["  7", "+ 8"])
        let gap = LineDiff.diff("x\n1\n2\n3\n4\ny", "X\n1\n2\n3\n4\nY")
        XCTAssertEqual(gap, ["- x", "+ X", "  1", "@@", "  4", "- y", "+ Y"])
        XCTAssertEqual(LineDiff.diff("same", "same"), [])
    }

    func testFolderChangesAndSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\nb".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let before = LineDiff.snapshot(dir)
        try "a\nb\nc".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("sub/seen.json"), atomically: true, encoding: .utf8)
        let changes = LineDiff.folderChanges(before: before, after: LineDiff.snapshot(dir))
        XCTAssertEqual(changes.map(\.path), ["notes.md", "sub/seen.json"])
        XCTAssertEqual(changes[0].added, 1)
        XCTAssertEqual(changes[1].added, 1)
    }
}

final class LoopCheckTests: XCTestCase {
    func testParseAndRun() {
        let loop = LoopDefinition.parse(text: "---\ncheck: echo hi\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/c.md"))
        XCTAssertEqual(loop.check, "echo hi")
        XCTAssertNil(LoopDefinition.parse(text: "---\nname: x\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/c.md")).check)
        let tmp = FileManager.default.temporaryDirectory
        let a = LoopCheck.run("echo hi", cwd: tmp, path: "/usr/bin:/bin")
        XCTAssertEqual(a.output, "hi\n")
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual(a.fingerprint, LoopCheck.run("echo hi", cwd: tmp, path: "/usr/bin:/bin").fingerprint)
        XCTAssertNotEqual(a.fingerprint, LoopCheck.run("echo bye", cwd: tmp, path: "/usr/bin:/bin").fingerprint)
        XCTAssertNotEqual(LoopCheck.run("exit 3", cwd: tmp, path: "/usr/bin:/bin").status, 0)
    }

    func testOldStateFileStillLoads() throws {
        let json = #"{"lastRun":{},"firstSeen":{"a":"2026-11-01T00:00:00Z"}}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let state = try d.decode(Store.LoopState.self, from: Data(json.utf8))
        XCTAssertNil(state.checkFingerprints)
        XCTAssertEqual(state.firstSeen.count, 1)
    }
}

final class DailyDigestTests: XCTestCase {
    func testDigest() {
        var a = LoopRun(loopId: "s", loopName: "Stock watch", trigger: .schedule)
        a.status = .succeeded
        a.summary = "**NVDA** +3%\nmore"
        var b = LoopRun(loopId: "n", loopName: "News", trigger: .schedule)
        b.status = .nothingToDo
        var c = LoopRun(loopId: "i", loopName: "Scout", trigger: .schedule)
        c.status = .needsApproval
        c.approvalNumber = 4
        c.summary = "2 roles"
        var old = a
        old.id = UUID()
        old.startedAt = Date().addingTimeInterval(-3 * 86400)
        let text = DailyDigest.text(runs: [a, b, c, old], waiting: [c], day: Date())!
        XCTAssertTrue(text.contains("• Stock watch: NVDA +3%"))
        XCTAssertTrue(text.contains("🔔 Scout: 2 roles"))
        XCTAssertTrue(text.contains("(1 quiet run with nothing new)"))
        XCTAssertTrue(text.contains("Waiting for you: #4 Scout"))
        XCTAssertEqual(text.components(separatedBy: "Stock watch").count, 2) // the old run isn't included
        XCTAssertNil(DailyDigest.text(runs: [b], waiting: [], day: Date()))
    }
}

final class TelegramHTMLTests: XCTestCase {
    func testConvert() {
        XCTAssertEqual(TelegramHTML.from(markdown: "## Found\n**NVDA** up <3% & `x<y`"),
                       "<b>Found</b>\n\n<b>NVDA</b> up &lt;3% &amp; <code>x&lt;y</code>")
        XCTAssertEqual(TelegramHTML.from(markdown: "- one\n- [two](https://a.dev/?q=1&b=\"2\")\n\nafter"),
                       "• one\n• <a href=\"https://a.dev/?q=1&amp;b=&quot;2&quot;\">two</a> (a.dev)\n\nafter")
        XCTAssertEqual(TelegramHTML.inline("[a.dev docs](https://a.dev/x)"), "<a href=\"https://a.dev/x\">a.dev docs</a>")
        XCTAssertEqual(TelegramHTML.from(markdown: "```\nlet a = b < c\n```"), "<pre>let a = b &lt; c</pre>")
        // Unmatched markers and snake_case stay as text.
        XCTAssertEqual(TelegramHTML.inline("2 * 3 and snake_case_name and **open"), "2 * 3 and snake_case_name and **open")
        XCTAssertEqual(TelegramHTML.inline("_italic_ word"), "<i>italic</i> word")
    }
}

final class DailyLimitTests: XCTestCase {
    func testLimit() {
        let loop = LoopDefinition.parse(text: "---\nmax_runs_per_day: 2\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/w.md"))
        XCTAssertEqual(loop.maxRunsPerDay, 2)
        var r1 = LoopRun(loopId: "w", loopName: "W", trigger: .wake)
        let manual = LoopRun(loopId: "w", loopName: "W", trigger: .manual)
        XCTAssertFalse(LoopScheduler.hitDailyLimit(loop, runs: [r1, manual], now: Date()))
        let r2 = LoopRun(loopId: "w", loopName: "W", trigger: .schedule)
        XCTAssertTrue(LoopScheduler.hitDailyLimit(loop, runs: [r1, r2], now: Date()))
        r1.startedAt = Date().addingTimeInterval(-2 * 86400)
        XCTAssertFalse(LoopScheduler.hitDailyLimit(loop, runs: [r1, r2], now: Date()))
        XCTAssertNil(LoopDefinition.parse(text: "---\nmax_runs_per_day: 0\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/w.md")).maxRunsPerDay)
    }
}

final class CheckParsingTests: XCTestCase {
    func testCheckKeptAsWritten() {
        func check(_ v: String) -> String? {
            LoopDefinition.parse(text: "---\ncheck: \(v)\n---\nx", fileURL: URL(fileURLWithPath: "/tmp/c.md")).check
        }
        XCTAssertEqual(check(#""$HOME/bin/poll" --json"#), #""$HOME/bin/poll" --json"#)
        XCTAssertEqual(check("[ -f ~/ready ] && echo yes"), "[ -f ~/ready ] && echo yes")
        XCTAssertEqual(check(#"jq '" #\(.n)"' x.json"#), #"jq '" #\(.n)"' x.json"#)
        XCTAssertEqual(check("gh pr list   # my PRs"), "gh pr list")
        XCTAssertEqual(check(#""echo hi""#), "echo hi")
        XCTAssertNil(check(""))
    }
}

final class ThreadTitleTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(ThreadTitle.make(from: "can you please help me fix the flaky login test?"), "Fix the flaky login test")
        XCTAssertEqual(ThreadTitle.make(from: "Hey Claude, compare pgvector and LanceDB. I need it for a RAG demo."), "Compare pgvector and LanceDB")
        XCTAssertEqual(ThreadTitle.make(from: "What's new in Swift 6.2?"), "What's new in Swift 6.2")
        XCTAssertEqual(ThreadTitle.make(from: "/Users/me/a.png what is this"), "/Users/me/a.png what is this")
        XCTAssertTrue(ThreadTitle.make(from: String(repeating: "word ", count: 40)).hasSuffix("…"))
        XCTAssertLessThanOrEqual(ThreadTitle.make(from: String(repeating: "word ", count: 40)).count, 61)
    }
}

final class MessageKeywordTests: XCTestCase {
    func testStrip() {
        XCTAssertEqual(MessageKeyword.strip("automate status", keyword: "automate"), "status")
        XCTAssertEqual(MessageKeyword.strip("Automate: what's the weather?", keyword: "automate"), "what's the weather?")
        XCTAssertEqual(MessageKeyword.strip("AUTOMATE, approve 3 only the first", keyword: "automate"), "approve 3 only the first")
        XCTAssertEqual(MessageKeyword.strip("@automate loops", keyword: "automate"), "loops")
        XCTAssertEqual(MessageKeyword.strip("automate", keyword: "automate"), "")
        XCTAssertNil(MessageKeyword.strip("remind me to buy milk", keyword: "automate"))
        XCTAssertNil(MessageKeyword.strip("automated tests failed again", keyword: "automate"))
        XCTAssertNil(MessageKeyword.strip("I should automate this", keyword: "automate"))
        XCTAssertEqual(MessageKeyword.strip("!status", keyword: "!"), "status")
        XCTAssertEqual(MessageKeyword.strip("anything", keyword: ""), "anything")
    }

    func testOutgoingNeverLooksAddressed() {
        let out = MessageKeyword.guardOutgoing("Automate can do that for you.", keyword: "automate")
        XCTAssertEqual(out, "🤖 Automate can do that for you.")
        XCTAssertNil(MessageKeyword.strip(out, keyword: "automate"))
        XCTAssertEqual(MessageKeyword.guardOutgoing("✅ Approved.", keyword: "automate"), "✅ Approved.")
    }

    func testSkillCommands() {
        XCTAssertEqual(RemoteCommand.parse("skills"), .skills)
        XCTAssertEqual(RemoteCommand.parse("/skills"), .skills)
        XCTAssertEqual(RemoteCommand.parse("skill"), .skills)
        XCTAssertEqual(RemoteCommand.parse("skill morning"), .runSkill(name: "morning", args: ""))
        XCTAssertEqual(RemoteCommand.parse("/skill /cover-letter-writer for Acme, angle: robotics"),
                       .runSkill(name: "cover-letter-writer", args: "for Acme, angle: robotics"))
    }

    func testMatchSkill() {
        let skills = ["simplify", "anthropic-skills:morning", "anthropic-skills:deep-research", "deep-research", "text-to-cad:cad"]
        XCTAssertEqual(RemoteCommand.matchSkill("morning", in: skills), "anthropic-skills:morning")
        XCTAssertEqual(RemoteCommand.matchSkill("/Simplify", in: skills), "simplify")
        // Exact name wins over the plugin one with the same short name.
        XCTAssertEqual(RemoteCommand.matchSkill("deep-research", in: skills), "deep-research")
        XCTAssertEqual(RemoteCommand.matchSkill("morn", in: skills), "anthropic-skills:morning")
        XCTAssertNil(RemoteCommand.matchSkill("research", in: skills)) // two match
        XCTAssertNil(RemoteCommand.matchSkill("issue", in: skills))
    }

    func testReplyTargetRoundTrip() {
        let id = UUID()
        XCTAssertEqual(ReplyTarget(stored: ReplyTarget.run(id).stored), .run(id))
        XCTAssertEqual(ReplyTarget(stored: ReplyTarget.thread(id).stored), .thread(id))
        XCTAssertEqual(ReplyTarget(stored: id.uuidString), .run(id)) // stored by earlier versions
        XCTAssertNil(ReplyTarget(stored: "loop:\(id.uuidString)"))
    }

    func testInitEventListsSkills() {
        let line = #"{"type":"system","subtype":"init","session_id":"s","skills":["simplify","anthropic-skills:morning"]}"#
        XCTAssertEqual(ClaudeEventParser.parse(line: line),
                       [.sessionStarted(sessionId: "s", model: nil, cwd: nil), .skills(["simplify", "anthropic-skills:morning"])])
    }
}

final class PhotonTests: XCTestCase {
    func testAddress() {
        XCTAssertEqual(PhotonClient.address(from: "(555) 555-0100"), "+15555550100")
        XCTAssertEqual(PhotonClient.address(from: "+44 20 7946 0000"), "+442079460000")
        XCTAssertEqual(PhotonClient.address(from: " Me@iCloud.com "), "me@icloud.com")
    }

    func testProtobufRoundTrip() {
        var p = Protobuf()
        p.string(1, "iMessage;-;+15555550100")
        p.int(2, 300)
        p.string(71, "héllo")
        let f = Protobuf.fields(p.data)
        XCTAssertEqual(f.string(1), "iMessage;-;+15555550100")
        XCTAssertEqual(f.int(2), 300)
        XCTAssertEqual(f.string(71), "héllo")
        // Garbage never crashes.
        _ = Protobuf.fields(Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x01]))
    }

    func testFramesAcrossChunks() throws {
        var r = GRPCWebFrames()
        let one = GRPCWebFrames.frame(Data("abc".utf8))
        var trailer = Data([0x80, 0, 0, 0, 14]); trailer.append(Data("grpc-status: 0".utf8))
        let all = one + trailer
        r.append(contentsOf: all.prefix(4))
        XCTAssertNil(try r.next())
        r.append(contentsOf: all.dropFirst(4))
        let first = try XCTUnwrap(r.next())
        XCTAssertFalse(first.isTrailer)
        XCTAssertEqual(first.payload, Data("abc".utf8))
        let t = try XCTUnwrap(r.next())
        XCTAssertTrue(t.isTrailer)
        XCTAssertNil(PhotonClient.trailerError(t.payload))
        XCTAssertNil(try r.next())
        XCTAssertEqual(PhotonClient.trailerError(Data("grpc-status: 7\r\ngrpc-message: Target%20not%20allowed".utf8))?.description,
                       "Photon: Target not allowed")
    }

    func testEventDecoding() {
        func event(text: String, fromMe: Bool, replyTo: String? = nil) -> Data {
            var content = Protobuf(); content.string(1, text)
            var msg = Protobuf(); msg.string(1, "guid-1"); msg.message(2, content)
            if let replyTo { msg.string(71, replyTo) }
            var received = Protobuf(); received.message(1, msg)
            var changed = Protobuf(); changed.string(1, "any;-;+15555550100")
            if fromMe { changed.int(4, 1) }
            changed.message(10, received)
            var top = Protobuf(); top.int(1, 42); top.message(10, changed)
            return top.data
        }
        XCTAssertEqual(PhotonClient.event(from: event(text: " status ", fromMe: false, replyTo: "orig")),
                       .message(.init(guid: "guid-1", text: "status", isFromMe: false, replyTo: "orig")))
        XCTAssertEqual(PhotonClient.event(from: event(text: "hi", fromMe: true)),
                       .message(.init(guid: "guid-1", text: "hi", isFromMe: true, replyTo: nil)))
        XCTAssertNil(PhotonClient.event(from: event(text: "\u{FFFC}", fromMe: false)))
        var hb = Protobuf(); hb.message(99, Protobuf())
        XCTAssertEqual(PhotonClient.event(from: hb.data), .heartbeat)
    }

    func testSendTextReplyTo() {
        let plain = Protobuf.fields(PhotonClient.sendTextRequest("hi", chatGuid: "chat", replyTo: nil))
        XCTAssertEqual(plain.string(1), "chat")
        XCTAssertEqual(plain.string(2), "hi")
        XCTAssertNil(plain.message(3))
        let reply = Protobuf.fields(PhotonClient.sendTextRequest("hi", chatGuid: "chat", replyTo: "guid-9"))
        XCTAssertEqual(reply.message(3).map(Protobuf.fields)?.string(1), "guid-9")
    }
}

/// Live check against Photon, skipped unless PHOTON_PROJECT_ID / PHOTON_SECRET / PHOTON_TO are set.
/// PHOTON_SEND=1 also texts PHOTON_TO.
final class PhotonLiveTests: XCTestCase {
    func testLive() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["PHOTON_PROJECT_ID"], let secret = env["PHOTON_SECRET"], let to = env["PHOTON_TO"] else {
            throw XCTSkip("no Photon credentials")
        }
        let client = PhotonClient(projectId: id, secret: secret)
        let chat = try await client.chatGuid(for: PhotonClient.address(from: to))
        XCTAssertFalse(chat.isEmpty)
        let events = try await client.events(chatGuid: chat)
        for try await e in events {
            XCTAssertEqual(e, .heartbeat)
            break
        }
        if env["PHOTON_SEND"] == "1" {
            let guid = try await client.sendText("👋 Automate now texts you through Photon.", chatGuid: chat)
            XCTAssertNotNil(guid)
        }
    }
}
