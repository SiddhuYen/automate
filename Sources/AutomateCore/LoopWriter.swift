import Foundation

/// "New loop from description": Claude turns a plain-English job into a loop file you review before saving.
public enum LoopWriter {
    public static func request(description: String, cwd: URL, projectPath: String?, now: Date = Date()) -> ClaudeRequest {
        var prompt = """
        Write an Automate loop file for this job:

        <job>
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))
        </job>

        """
        if let projectPath {
            prompt += "\nIt works in the code repository at \(projectPath); set `cwd:` to that path.\n"
        }
        prompt += "\nReply with only the file's contents: no code fences, nothing before or after."

        var req = ClaudeRequest(prompt: prompt, cwd: cwd)
        req.model = "sonnet"
        req.effort = "medium"
        req.tools = [] // just writing text
        req.permissionMode = .plan
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm"
        req.appendSystemPrompt = """
        You write loop files for Automate, a Mac app that runs Claude Code jobs on a schedule or when the Mac wakes,
        unlocks or logs in. It's \(f.string(from: now)) now.

        \(formatGuide)

        Always write `enabled: false`: the user turns the loop on after reviewing it.
        """
        return req
    }

    /// The loop file format and what makes a good loop, for prompts that write loops.
    public static let formatGuide = """
        A loop file is markdown with YAML frontmatter:

        ---
        name: Short human name
        enabled: false                # true = runs on its schedule/triggers
        schedule: daily 08:30         # every 30m | every 2h | hourly | daily HH:MM | weekdays HH:MM | weekends HH:MM | mon,wed,fri HH:MM (24-hour) | once YYYY-MM-DD HH:MM. Omit for trigger-only loops.
        triggers: [wake]              # optional: launch, wake, unlock. Use [] if none.
        # after: [other-loop]         # optional: run when another loop finishes (e.g. a brief after a data-gathering loop)
        # check: curl -s https://example.com/jobs | shasum   # optional: cheap shell command; Claude runs only when its output changes
        # max_runs_per_day: 6         # optional cap on automatic runs (useful with wake/unlock triggers)
        autonomy: split               # auto (do everything) | ask (research read-only, then propose) | split (do the safe parts, list the rest for approval)
        permission: auto              # mode when acting: auto | acceptEdits | bypassPermissions
        model: sonnet                 # haiku for trivial jobs; sonnet for routine checks; opus for hard research or coding
        effort: medium                # low | medium | high
        notify: changes               # always | changes | never
        catch_up: true                # run on wake if the Mac slept through the time
        timeout: 30m
        allowed_tools: [WebSearch, WebFetch, Read, Write, Edit]   # tools it may use without asking
        # cwd: ~/code/repo            # only for jobs inside a code repo
        # chrome: true                # only if it must use the user's logged-in Chrome
        ---
        Instructions, written to Claude in the second person, step by step.

        Rules for good loops:
        - Each loop has a private notes folder kept between runs. Tell it which files to keep there (e.g. seen.json,
          history.csv, notes.md) so it doesn't repeat itself and can report only what's new.
        - If nothing changed, it should reply with only NOTHING_TO_DO (so the user isn't pinged).
        - Spell out what's "Safe to do automatically" and what "Needs approval". Sending, submitting, buying, posting,
          deleting and pushing code always need approval unless the user explicitly said otherwise. Prefer split.
        - Gmail/Calendar need Claude Code MCP tools; if the job needs them, tell the loop to say so and stop if missing.
        - For frequent polling of something that rarely changes (a page, an issue list), add a `check:` command so Claude
          (and the user's usage) is only spent when it changed.
        - Keep it concrete and short. Pick a sensible schedule if the user didn't give one.
        """

    /// Added to every thread: Claude may set up loops (recurring jobs, reminders) when you ask for them.
    public static func threadPrompt(newLoopsDir loopsDir: URL, projectPath: String? = nil) -> String {
        let projectNote = projectPath.map { path in
            """

            This thread is in the project at \(path). If the loop is about this project, add `project: \(path)` to its
            frontmatter: Automate then keeps the loop file and its notes in \(path)/.automate/ and runs it in that folder
            (no `cwd:` needed). It arrives switched off for the user to review.

            This project's own loops are in \(path)/.automate/loops/ (their notes in .automate/loop-data/<name>/), and
            you can read and change them. To change one, edit its file there in place; never write a copy to the
            folder above (that would add a second loop). Automate picks up the edit within 30 seconds. Changes to the
            instructions, schedule, model and similar keep it as it was; if your edit changes `check:`, bypass,
            Chrome, or what lets it change things on its own (a permission other than auto/plan, Bash/Write/Edit in
            `allowed_tools`, or `cwd:`), Automate switches it off until they review it, so tell them. Write `enabled: true/false` only when the user asks to switch it on or off.
            """
        } ?? ""
        return """
        You're running inside Automate, a Mac app that also runs "loops": Claude jobs on a schedule or when the Mac
        wakes. When the user asks for something recurring or later ("every morning…", "remind me at 5pm…", "keep an
        eye on…"), you can set it up by writing a loop file to \(loopsDir.path)/<short-kebab-name>.md.
        Automate imports it as soon as your reply ends; results reach the user as notifications (and texts, if
        they've set that up). You can't see or change the user's other loops\(projectPath == nil ? "" : " (outside this project)").
        Use `schedule: once YYYY-MM-DD HH:MM` for one-offs like reminders (instructions such as "Reply with: Reminder: …",
        autonomy: auto, notify: always, model: haiku). Set `enabled: true` only when the user asked you to set it up;
        otherwise write it with `enabled: false` and say they can switch it on in Automate. Never use
        `permission: bypassPermissions`, `chrome: true` or `check:` here (Automate switches such loops off until the user
        reviews them); tell the user to add those themselves if the job truly needs them.\(projectNote)

        \(formatGuide)
        """
    }

    /// Separates loop files in a suggestions reply.
    public static let separator = "=====LOOP====="

    /// Look at what you've been doing in Claude Code and suggest loops that would save you repeating it.
    public static func suggestionsRequest(sessions: [(title: String, folder: String, date: Date)], existing: [String],
                                          cwd: URL, now: Date = Date()) -> ClaudeRequest {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let list = sessions.map { "- \(f.string(from: $0.date)) · \($0.folder) · \($0.title)" }.joined(separator: "\n")
        var prompt = """
        Here are my recent Claude Code sessions (date · folder · what it was about):

        \(list)

        """
        if !existing.isEmpty { prompt += "\nLoops I already have: \(existing.joined(separator: ", ")).\n" }
        prompt += """

        Suggest up to 3 loops (recurring background jobs) that would save me from doing something I keep doing by
        hand, or that would keep an eye on something I clearly care about. Skip anything one-off, anything I already
        have, and anything that would need to act without my approval on risky things.

        For each, write a complete loop file. Put a line containing only \(separator) before each file.
        Reply with nothing but the files.
        """
        var req = request(description: "", cwd: cwd, projectPath: nil, now: now)
        req.prompt = prompt
        return req
    }

    /// Split a suggestions reply into loop files.
    public static func splitSuggestions(_ reply: String) -> [String] {
        reply.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("---") }
            .map(extract)
    }

    /// Claude's reply, minus any code fence or chatter around the frontmatter.
    public static func extract(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !text.hasPrefix("---"), let r = text.range(of: "\n---\n") {
            text = "---\n" + text[r.upperBound...]
        }
        return text + "\n"
    }
}
