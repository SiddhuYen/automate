# Changelog

## Unreleased

- **Coordinator threads**: switch on Coordinator in a thread and it can start threads in your projects and give
  them more instructions. Each one's answer comes back to the coordinator, which decides what's next. Up to 25 tasks
  per message you send it. Listed in Settings → Access.
- **No starter loops**: new installs start empty (make loops with New Loop from Description, or the blank
  loop in the + menu), and the template gallery is gone. Loops you already have are untouched.
- **Project loops**: a loop can live in a project's `.automate/loops/` folder, with its notes in
  `.automate/loop-data/` (git-ignored), so it travels with the project. Shown under the project in the sidebar; runs
  in the project folder with its memory. Create from the project's menu or the wizard, or move an existing loop
  (⋯ → Move to Project; notes and run history come along). Loop files that arrive in a project from outside
  Automate (e.g. `git pull`) are switched off until you OK them. Threads in the project can edit its loops in place;
  an edit that changes what lets the loop act on its own (permission, write/shell tools, `cwd`) switches it off
  until you OK it, like `check:`, bypass and Chrome.

- **Swipe-reply on iMessage too**, and to any of Automate's texts: replying to a loop's text asks about that run
  (or answers its approval request with "yes"/"no"); replying to Claude's reply continues that thread. On iMessage a
  swipe-reply needs no keyword.
- **Photon** as a messaging channel: iMessage from Photon's line (live event stream, swipe-replies by message id),
  with no Messages.app, Full Disk Access or keyword. Settings → Messaging → Photon.
- **Run skills by text**: `skills` lists them (learned from Claude's session start), `skill morning [details]` runs
  one in a new thread. `run <name>` falls back to a skill with that name when no loop matches.

## 0.2.0 (2026-11-01)

### Messaging: text Automate, and it texts you
- **Telegram** bot (free, works anywhere): loop results and approval requests with ✅ Approve / ⏭ Skip buttons
  (also ▶️ run buttons on `loops` and per-run buttons on `status`), with formatting (bold, code, links), chat with
  Claude, send photos and files, swipe-reply to a loop's text to ask about that run. Pairing uses an 8-digit code
  that rotates, private chats only.
- **iMessage** through Messages.app; replies are read from the Messages database (needs Full Disk Access). Only
  messages starting with a keyword (`automate status`) count, so texting yourself stays safe.
- **Webhooks** (send only): Discord, Slack, or ntfy for free phone push without an account.
- Text commands: `status`, `approve 12 [1,3] [note]`, `skip 12`, `loops`, `run <loop>`, `result <loop>`, `threads`,
  `use 3`, `/new`, `stop`, `pause 2h`, `resume`. Anything else is a message to Claude. Casual "yes"/"no" only
  count as approvals right after Automate asked.
- Quiet hours, a daily summary text, "text me thread replies when I'm away", a per-loop `message:` setting, and a
  **Messages** page with the full history each way.

### Threads
- Replies stream word by word; markdown renders properly (headings, lists, tables, code blocks with Copy).
- File edits show as colored diffs; a bar lists the files Claude changed; the header shows git branch and changes
  with one-click *Review Changes* / *Commit…*.
- Queue messages while Claude works; **Send Later**; drafts survive switching threads; Return-to-send option.
- Attach files and screenshots (📎 or drag and drop); ⚡ saved prompts.
- **Own branch**: a project thread can work in its own git worktree so parallel threads don't collide.
- **Continue in Terminal** (interactive `claude --resume`, for permission prompts) and **Open in your editor**.
- **Continue a Claude Code Session** from Terminal or your IDE (⇧⌘I).
- Duplicate (fork), export to Markdown, copy, archive and unarchive, Undo after delete (kept 30 days in `trash/`).
- Unread dots, sidebar search across all messages, collapsible sections; per-project defaults (Project Settings…);
  shorter thread titles ("can you please help me fix X" → "Fix X").
- Project memory now actually refreshes on every message (it used to stay as it was at a thread's first message).

### Loops
- **New Loop from Description** (Claude writes it), **Suggest from My Work** (from your recent sessions), and
  **Turn into Loop…** from any thread. Ask any thread for something recurring or a reminder and it sets one up.
- Quick-settings bar (schedule, triggers, autonomy, model, notify, texts) without editing YAML.
- Schedules: cron (`30 8 * * 1-5`), one-offs (`once 2026-11-02 17:00`); `timeout: 2h`; `after: [other-loop]` chains.
- `check: <command>`: a free pre-check, so polling loops only use Claude when something changed.
- Pick individual proposed actions to approve (checkboxes, or `approve 12 1,3` by text), or snooze an approval.
- **Dry Run** (propose only), **Run with Note…**, Run Again, the Notes tab (renders CSV/JSON/markdown, *Ask
  Claude…*), run-history dots, and each run shows what it changed in its notes folder.
- Loops learn: each run sees its recent results, and approvals and skips are recorded in `feedback.md`.
- Safety: pause loops (menu bar or `pause` by text), hold loops near your usage limit, `max_runs_per_day`,
  auto-pause after 3 failures, and settings that act beyond Claude's permission checks (`check:`, bypass, Chrome)
  need your OK in Automate: a loop file that appears or changes with ones you haven't OK'd is switched off.
- Four new templates (AI news digest, weekly git recap, page watcher, PR reviews waiting) and a template gallery.

### Everywhere
- ⌘K command palette, ⌃⌥Space **Quick Ask** (answers stream right in the floating box), Services → **Ask Automate**
  (text) and **Ask Automate about Files**.
- `automate://` links for Shortcuts, Raycast and scripts (they can't act unless you allow it).
- Usage meter (5-hour and 7-day limits) and a warning if Claude Code is ever signed in with a pay-per-use API key.
- Inbox home: Getting Started checklist, *Coming up* and *Today*; Activity filters and weekly summary; a Running page.
- Continue on Phone: hand a thread to your phone when you leave the Mac.
- The menu bar shows how many runs are waiting for you; drag a folder onto the sidebar to add a project.
- Notification actions: Approve with Note, and Reply (to a thread or about a loop result).
- Run transcripts older than 90 days are now cleaned up at launch (runs still waiting for you are kept).
- Standing instructions for every thread and loop; back up your data to a zip; an app icon; Help (⌘?);
  notification status and test in Settings; a Retry bar when a reply fails.

### Under the hood
- 69 unit tests (was 16). Debug builds add three end-to-end modes:
  - `--selftest`: 73 checks that drive the real app model against `claude` with Haiku (streaming, queueing, memory
    refresh, worktrees, text commands, approvals, chains, checks, reminders, follow-ups, safety rules).
  - `--telegramtest`: the whole Telegram flow against a local fake Bot API server (`scripts/fake-telegram.py`).
  - `--snapshot <dir>`: renders the main screens to PNGs.

  `AUTOMATE_DATA_DIR` runs a copy against a scratch folder with its own preferences.
