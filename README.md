# Automate

A personal Mac app for working with Claude Code: chat threads that edit your code folders, research threads
that search the web, and **loops** — jobs that run on a schedule or when your Mac wakes up, do the safe part
on their own, and ask you before doing the rest. Loops can text you, and you can text back to approve them or
chat with Claude from your phone.

Everything runs through the `claude` command-line tool you're already logged into, so it uses your
**Claude Pro or Max subscription**. No API key needed. Automate checks at launch: if Claude Code is ever signed in
with an API key (billed per use) instead of your plan, it tells you, and Settings shows which account it's using.

Contents: [Setup](#setup) · [Projects and threads](#projects-and-threads) · [Getting around](#getting-around) ·
[Loops](#loops) · [Texting Automate](#texting-automate-free) · [Links & Shortcuts](#links--shortcuts) ·
[Where things live](#where-things-live) · [Good to know](#good-to-know). What changed: [CHANGELOG.md](CHANGELOG.md).

## Setup

There's no download: you build Automate from this repo, which takes about five minutes. Nothing here needs a paid
service besides your Claude plan.

### Easiest: let Claude Code install it

A claude.ai chat in the browser can't run anything on your Mac, so use Claude Code (you need it for Automate anyway).
In Terminal:

```bash
curl -fsSL https://claude.ai/install.sh | bash   # installs Claude Code
claude                                           # sign in with your Claude account the first time
```

Then tell it:

> Install Automate from https://github.com/SiddhuYen/automate by following the Setup section of its README.

It clones, builds and installs the app. You still click a few things yourself, because macOS only lets a person
approve them: installing Apple's developer tools if a popup asks, allowing notifications on first launch, and
right-click → Open if macOS says the app is from an unidentified developer.

> **For the agent:** follow the steps below in order. Steps marked **(you)** need the person at the Mac (signing in,
> clicking macOS permission dialogs); ask them and wait. Everything else can run in Terminal. Don't use `sudo`.

### Step by step

**You need:** a Mac on macOS 14 (Sonoma) or newer, and a Claude Pro or Max subscription.

1. **Apple's command-line tools** (Swift 5.9 or newer; full Xcode works too):

   ```bash
   xcode-select --install        # skip if it says they're already installed
   /usr/bin/swift --version      # should print Swift 5.9 or newer
   ```

2. **Claude Code**, signed in with your claude.ai account
   ([install docs](https://docs.claude.com/en/docs/claude-code/setup)):

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   claude                        # (you) sign in with your Claude account (/login), then quit with /exit
   claude auth status            # should say you're logged in through claude.ai, not an API key
   ```

3. **Build and install:**

   ```bash
   git clone https://github.com/SiddhuYen/automate.git
   cd automate
   ./scripts/build-app.sh --install   # builds Automate.app, copies it to /Applications, opens it
   /usr/bin/swift test                # optional: runs the tests (~1 min)
   ```

   It should end with `✓ Installed to /Applications/Automate.app`.

4. **First launch (you):**
   - Allow notifications when macOS asks. That's how loops reach you.
   - If macOS says the app is from an unidentified developer, right-click Automate.app in /Applications → Open.
   - In Automate → Settings, check that Claude was detected, and turn on **Open Automate at login**.
   - Automate starts with no loops. Make your first with **New Loop from Description** (⇧⌘L): say what should
     happen and when, and Claude writes it for you to review.

5. **Optional:** text Automate from your phone ([Texting Automate](#texting-automate-free); each person uses their
   own bot or account), and connect Gmail/Calendar in your claude.ai connector settings for email loops.

**Updating** later: `cd automate && git pull && ./scripts/build-app.sh --install`. Your threads, loops and settings
live in `~/Library/Application Support/Automate/`, so rebuilding never touches them.

**If something goes wrong:**

- *Build errors about the SDK or "module compiled with Swift …":* another `swift` on your PATH (swiftly, Homebrew) is
  being used. The script prefers `/usr/bin/swift`; force it with `SWIFT=/usr/bin/swift ./scripts/build-app.sh --install`.
- *"Claude not found" in Settings:* Automate asks your login shell (`zsh -l -i`) for `claude`, then tries
  `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin` and `/usr/local/bin`. Make sure `command -v claude` works in
  a new Terminal window, then reopen Automate.
- *macOS keeps asking for the same permissions after each rebuild:* the build is signed ad-hoc, and macOS remembers
  answers per signature. If you have an Apple Development certificate (free: Xcode → Settings → Accounts → add your
  Apple ID → Manage Certificates → +), the script uses it automatically and the answers stick.

## Using it

### Projects and threads

**Projects (coding).** Use *Add Project…* to pick a folder (**New Folder** there makes one) or drag one onto the sidebar. Each thread in it is a
Claude Code session working in that folder: it reads, edits, and runs commands. Pick the model, effort and
permission mode per thread:

| Mode | What Claude may do without asking |
|---|---|
| Plan | Read only |
| Accept edits | Edit files; commands that need approval are denied |
| Auto *(default)* | Claude Code's classifier allows safe actions and blocks risky ones |
| Bypass all | Anything. Only for throwaway folders |

Right-click a project → **Project Settings…** to give its new threads their own model, effort, permission mode or
"own branch" default.

Automate can't show permission prompts mid-run, so anything that would prompt is denied and Claude works around it
or tells you. Raise the mode for a thread if it keeps getting blocked, or use **Open → Continue in Terminal**: it
opens the same conversation in an interactive `claude`, where you can answer prompts. The **Open** button also opens
the folder in your editor (VS Code, Cursor, Zed, Xcode… whichever you have), and the bar under the title lists the
files Claude changed in the thread. The header shows the repo's branch and uncommitted changes; click it for the
list and one-click *Review Changes* / *Commit…*.

**Project memory.** Each project has a **Memory** item in the sidebar. It's one markdown file in
`~/Library/Application Support/Automate/memory/`. Every thread in the project gets its current contents with each
message and may edit it, and so does any loop whose `cwd` is the project folder. Edit it in Automate or any editor.
Changes Claude makes show up live. Removing a project keeps its memory, so adding the folder again brings it back.

**Threads.** Replies stream in as Claude writes them, with code blocks (and a Copy button), tables and lists. Keep
typing while Claude works: what you send is queued and goes out when the current reply finishes. The 🕒 button sends
a message later (in an hour, this evening, tomorrow morning, or a time you pick). Drop files or paste a screenshot
with the 📎 button (files from outside the thread's folder are copied to Automate's `attachments/` folder so Claude
may read them). The ⋯ menu can duplicate a thread (a copy that remembers the conversation but continues separately),
export it as Markdown, or send the last reply to your phone. Right-click any message to copy it. Archived threads
live at the bottom of the sidebar; search there finds text in any thread. The ⚡ menu inserts saved prompts ("Review
my changes", "Write tests…"; edit them or save your own), and threads that finish while you're elsewhere get a blue
dot. Settings can make Return send (Shift-Return for a new line). File edits show as a colored diff when you expand
them.

In a project thread, **Own branch** (before the first message) puts the thread in its own git worktree and branch
(`.claude/worktrees/…`), so several threads can change the same repo at once without colliding. Settings can make
that the default. **Continue a Claude Code Session** (⇧⌘I) picks up a session you started in Terminal or your
editor, with its history, so you can keep going here or from your phone.

Ask any thread for something recurring or later ("every weekday at 7 send me the top AI news", "remind me at 5pm
to call the bank") and Claude sets it up as a loop. Or, after doing something by hand, use **Turn into Loop…** in the
thread's ⋯ menu. Threads can only add new loops, never change yours.

Loop settings that act beyond Claude's normal permission checks (`check:`, `permission: bypassPermissions`,
`chrome: true`) need your OK in Automate: if a loop file appears or is edited outside Automate with ones you haven't
OK'd, the loop is switched off and you're told. Switching it on (or saving it in Automate's editor) is the OK.

**Research.** Use threads under *Research* for anything that isn't tied to a code folder. Claude searches and
fetches pages, and saves any files to Automate's research folder.

### Getting around

- **⌘K** jumps to any thread, loop or project, or runs a command. **⌘?** opens Help (shortcuts, text commands,
  the loop file format). **⌘1 / ⌘2** open the Inbox and Activity.
- **⌃⌥Space** opens **Quick Ask** from any app: ↩ asks and the answer streams right in the box (ask follow-ups
  there, or *Open in Automate*); ⌘↩ asks in the background and the answer arrives as a notification you can reply to.
- Select text in any app and choose **Services → Ask Automate**, or select files in Finder and choose
  **Services → Ask Automate about Files**.
- The sidebar shows how much of your Claude usage limits you've used (from Claude's own replies), and a **Running**
  page lists everything Claude is working on right now, each with Stop (the menu bar has *Stop All Loops*).
- **About you:** Settings → General has a box for standing instructions ("I'm a CS student; keep answers short") that every thread and loop gets.
- Deleted threads can be restored with **Undo** right after, and are kept in `trash/` for 30 days.

### Loops

The quickest start is **New Loop from Description** (⇧⌘L, or the Inbox checklist): say what should happen and when,
and Claude writes the loop file for you to review (or paste a loop file someone shared). It's saved switched off.
**Suggest from My Work** in the same window looks at your recent Claude Code sessions and drafts loops for things you
keep doing.

In a loop's ⋯ menu, **Run with Note…** adds a one-off instruction ("this time, focus on NVDA"), and **Dry Run**
researches and proposes only; approving the proposal carries it out with the loop's real settings. It's a safe way to
try a new loop.

Loops can't silently burn through your plan. Settings → Loops holds them when any usage limit passes 90%
(adjustable), the menu bar can pause them for an hour, until tomorrow or until you resume, and a loop that fails
three runs in a row switches itself off and tells you.

Each loop is a markdown file in `~/Library/Application Support/Automate/loops/`. Edit it in Automate or in
any editor; Automate picks up changes within 30 seconds. It comes with none: you make your own. A loop file looks
like this:

```markdown
---
name: News digest
enabled: true
schedule: daily 08:30        # every 30m · hourly · weekdays 18:30 · mon,wed 07:15
triggers: [wake, unlock]     # also: launch (= login when "Open at login" is on)
autonomy: split              # auto · ask · split
permission: auto             # mode used when the loop is allowed to act
model: opus
effort: high
notify: changes              # always · changes · never
catch_up: true               # Mac asleep at 08:30? run when it wakes
timeout: 30m
allowed_tools: [WebSearch, WebFetch, Read, Write, Edit]
# message: never             # texts to your phone: always · changes · never (default: same as notify)
# after: [other-loop]        # also run when that loop finishes (chains; won't re-run within 10 min)
# check: gh issue list --label bug   # cheap pre-check: Claude runs only when this output changes
# max_runs_per_day: 6        # cap automatic runs (Run Now doesn't count)
# chrome: true               # let it use your Chrome (Claude in Chrome)
# cwd: ~/code/my-app         # run inside a repo (default: the loop's notes folder)
---
Plain-English instructions. Say what's safe to do automatically and what needs approval.
```

The bar above the editor changes the common settings (schedule, triggers, autonomy, model, notify, texts) without
touching YAML. Schedules also accept cron (`30 8 * * 1-5`, `*/15 * * * *`) and one-offs (`once 2026-11-02 17:00`),
and `timeout` takes `45m` or `2h`.
The *Notes* tab next to *Runs* shows the files the loop keeps (tables for CSV, formatted JSON, rendered markdown);
*Ask Claude…* there opens a thread in that folder. Each run's transcript ends with what it changed in that folder
(expand it for the diff). The dots under the loop's name are its last 30 runs.
To watch a web page for free, give a loop a `check:` such as `curl -sL https://example.com/page`: Claude only runs
when the page actually changed.

How much a loop does on its own (the 10/90 split):

- **auto**: does the whole job and reports back.
- **ask**: researches read-only and ends with *Proposed actions*. Nothing happens until you approve.
- **split**: does the parts the instructions call safe, and lists the rest under *Needs approval*.

Runs that need you show up in the **Inbox**, in the menu bar, and as a notification with **Approve / Approve with
Note / Skip** buttons (other loop notifications have **Reply…** to ask about the result). Each gets a number (#12)
so you can approve it by text. When a run proposes several actions, each one gets a checkbox: untick what you don't
want (by text: `approve 12 1,3`). You can add a note when approving (e.g. "keep the emails short"), or **Snooze** it
until later (it comes back with a reminder). Approving resumes the same Claude session, so it remembers everything
from the run. *Continue in Thread* turns any run into a normal chat.

**Save usage with `check:`.** A loop that polls something (every 5 minutes, say) can name a shell command; Automate
runs it first and only starts Claude when its output changed since last time, handing Claude the new output. Run Now
always runs. Because that command runs without asking, a `check:` you didn't write or OK in Automate switches the
loop off until you review it.

Loops learn from you: each run sees what it reported last time (so it says only what's new), and every approve,
skip and note is written to `feedback.md` in its notes folder, which it reads first. Skip the same kind of proposal a
few times and it stops proposing it.

Each loop gets a **notes folder** (`loop-data/<loop>/`) that is kept between runs. Claude is told to read it
first and update it at the end, so it remembers what it has already seen (for example `seen.json` for
news stories, `history.csv` for prices). A loop replies `NOTHING_TO_DO` when nothing changed, so you aren't
notified.

**Project loops** live inside a project, so they travel with it: `<project>/.automate/loops/<name>.md`, with notes
in `<project>/.automate/loop-data/<name>/` (git-ignored). They show under the project in the sidebar and run in its
folder with its memory. Make one with *New Loop in Project…* (right-click the project), the wizard's "Keep it in
the project" option, or a loop's ⋯ → **Move to Project**. A thread in a project can add `project: <folder>` to a loop
it writes, and can edit the project's loops in place ("make the scout loop run at 9"); edits are picked up within 30
seconds. A loop file that shows up in a project on its own (a clone or `git pull`) is switched off until you
switch it on in Automate, and so is one edited outside Automate's editor to change `check:`, bypass, Chrome or what
lets it act on its own (permission, Bash/Write/Edit in `allowed_tools`, `cwd`).

## Texting Automate (free)

Settings → **Messaging** connects Telegram, iMessage, Photon and/or a webhook. Automate texts you when a loop needs approval or
finds something (following each loop's `notify`, or `message:` if set), and you can text back:

| Text | Does |
|---|---|
| `status` | what's waiting and running, and your usage |
| `approve 12`, `approve 12 1,3`, `approve 12 <note>` | approve all, some (by number), or with a note |
| `yes` / `no` | approve / skip, only right after Automate asked (otherwise they go to Claude) |
| `skip 12` | skip |
| `loops`, `run news digest` | list loops, run one now (its result is texted back) |
| `skills`, `skill morning`, `skill cover-letter-writer for Acme` | list Claude's skills, run one in a new thread |
| `result news` | the latest result of a loop |
| `threads`, `use 3`, `new` | pick which thread your texts go to, or start a new research thread (`/new <message>`) |
| `stop` | stop the current reply |
| `pause 2h` / `resume` | hold loops for a while |
| a photo or file (Telegram) | handed to Claude along with the caption |
| a swipe-reply to a loop's text | a question about that run, answered in the run's own session (`yes`/`no` on an approval request answers it) |
| a swipe-reply to Claude's reply | continues that thread, whichever thread your texts currently go to |
| anything else | a message to Claude in your current thread; the reply comes back as a text |

- **Telegram** (works anywhere; tap buttons to approve, skip, or run a loop from `status` and `loops`): message
  @BotFather → `/newbot`, paste the token into Settings, then send your bot the 8-digit code Settings shows (it
  changes every 10 minutes). Only that chat can control Automate.
- **iMessage**: enter your phone number or Apple ID. Sending goes through Messages.app (macOS asks once to let
  Automate control it). To read your replies Automate needs **Full Disk Access** (Settings has a button), because
  Messages keeps its history private; after granting it, quit and reopen Automate. Swipe-replies to Automate's
  texts don't need the keyword.
  Messages need a **keyword** (default `automate`): text `automate status` or `Automate what's on my calendar?`, so a
  conversation with yourself can still hold ordinary notes. Automate's own texts can never trigger it, and the double
  copy you get when texting yourself counts once. Change or clear the keyword in Settings → Messaging.
- **Photon** ([photon.codes](https://photon.codes)): iMessage from Photon's own number, so no Messages.app, Full
  Disk Access or keyword: every text in that chat goes to Automate. Paste a Spectrum project's ID and secret (dashboard
  → project Settings) and the number to text (defaults to the iMessage number). On Free/Pro plans the number must be
  a user of the project. Talks to Photon's gRPC-web API directly (`Sources/AutomateCore/Photon.swift`); swipe-replies
  work by message id.
- Optional: text thread replies to you when you've been away from the Mac for 5+ minutes. Leaving your desk mid-task?
  **Continue on Phone** in a thread's ⋯ menu points your texts at it and sends you its last reply.
- **Webhook** (send only): a Discord or Slack webhook, or [ntfy](https://ntfy.sh) for free phone push
  notifications without an account (Settings can make a hard-to-guess topic for you).
- The **Messages** page in the sidebar shows everything sent each way, with each channel's status, and lets you
  send yourself a note.
- A **daily summary** text (at a time you pick) lists what each loop found and what's waiting for you. It's built
  from the run results, so it costs no Claude usage.
- **Quiet hours** hold loop texts overnight and send them in one batch in the morning. Replies to what you text
  still come right away.

## Links & Shortcuts

`automate://ask?text=…&project=<name>`, `automate://run/<loop>`, `automate://open/inbox` (or `activity`,
`loop/<id>`, `thread/<id>`) and `automate://quick-ask` work from Shortcuts, Raycast, Alfred or `open` in Terminal.
Because any web page can open such a link, `ask` only fills in a new thread for you to send (and `run` only selects
the loop), unless you turn on *Links may send messages* in Settings → Loops.

**Siri:** in the Shortcuts app, make a shortcut with *Ask for Input* → *URL* `automate://ask?text=[Provided Input]&background=1`
→ *Open URLs*, name it "Ask Automate", and say "Hey Siri, Ask Automate". (Needs *Links may send messages* on; the
answer arrives as a notification.)

## Where things live

`~/Library/Application Support/Automate/`: `loops/` (your loop files; project loops are in `<project>/.automate/`), `loop-data/` (each loop's notes),
`threads/`, `runs/` (full transcripts; finished runs older than 90 days are deleted at launch), `memory/`, `attachments/`, `projects.json`, `loop-state.json`, and
`secrets.json` (your Telegram bot token, Photon secret and webhook URL, readable only by you). Settings → General → **Back Up
Data…** zips everything except `secrets.json`.

## Good to know

- Loops only run while your Mac is awake and Automate is open (it stays in the menu bar when you close the
window). While Claude is working, Automate keeps the Mac from idle-sleeping, so a long run isn't cut off. Daily
loops with `catch_up: true` run as soon as the Mac wakes after a missed time.
- Loops and threads count against your Claude plan's usage limits. Use `model: sonnet` for routine loops.
- **Chrome.** Turn on the *Chrome* button in a thread, or add `chrome: true` to a loop, and Claude can use your real
  Chrome (with your sign-ins) through the [Claude in Chrome](https://claude.com/chrome) extension. Chrome has to be open
  with the extension connected; if it isn't, a loop says so and stops. Claude works in its own tab group. Threads
  need the Auto or Bypass mode (the extension refuses Plan, and Accept edits denies it). `ask` loops with Chrome
  run in Claude Code's dontAsk mode with only page-reading tools allowed, so they can browse but not click or type. Sites
  the extension hasn't been allowed on can still block an unattended run, so allow them once from Chrome first.
  Pair it with `autonomy: ask` or `split` so form submissions and purchases wait for you.
- Gmail and Calendar loops need those tools available in Claude Code itself (claude.ai connectors or `claude mcp`). If they aren't,
  the loop says so and stops.
- Replies stream word by word (turn it off in Settings → General). Subagent chatter is hidden.
- Messages queued behind a busy thread are kept in memory only: quitting Automate drops them (scheduled ones are
  saved until they're due).
- Developing: build with `/usr/bin/swift build` (the build script prefers it; another `swift` earlier on your PATH may
  not match the macOS SDK). `AUTOMATE_DATA_DIR=/tmp/x` runs a copy against a scratch data folder. Debug builds also
  take `--snapshot <dir>` (renders the main screens with sample data to PNGs) and `--selftest` (drives the app model
  against the real `claude` with Haiku: streaming, queueing, text commands, an approve-by-text loop, memory refresh),
  and `--telegramtest` (run from the repo folder: drives the real Telegram code against `scripts/fake-telegram.py` on
  localhost: pairing, commands, buttons, chat, files, approvals, swipe-replies).
- Layout: `Sources/AutomateCore` is the engine (CLI runner, loop parser, scheduler, storage; Foundation only,
  covered by tests). `Sources/Automate` is the SwiftUI app.

## Ideas for next

- Codex as a second engine (`codex exec`), plus a cross-model review step for coding loops
- Git worktree per coding run so parallel agents never collide (the CLI has `--worktree`)
- A "scan my sessions" loop that suggests new loops from your Claude Code history
- Voice notes from Telegram (needs a free local speech-to-text model)
