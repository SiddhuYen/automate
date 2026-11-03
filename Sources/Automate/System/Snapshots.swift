#if DEBUG
import AppKit
import SwiftUI
import AutomateCore

/// Development aid: `AUTOMATE_DATA_DIR=/tmp/x Automate --snapshot /tmp/shots` renders the main screens with sample
/// data into PNGs and quits. Nothing runs (no loops, no Claude, no messaging), and your real data isn't touched.
@MainActor
enum Snapshots {
    static func run(into dir: URL) {
        guard ProcessInfo.processInfo.environment["AUTOMATE_DATA_DIR"] != nil else {
            print("Set AUTOMATE_DATA_DIR to a scratch folder first.")
            exit(1)
        }
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.bootstrapped = true // don't start timers, loops or messaging
        seed(model)

        var shots: [(String, SidebarItem?, AnyView, CGSize)] = []
        let size = CGSize(width: 1180, height: 760)
        shots.append(("inbox-card", nil, AnyView(InboxView()), CGSize(width: 760, height: 420)))
        if let run = model.runs.first {
            shots.append(("card-only", nil, AnyView(ApprovalCard(run: run, showOpen: true).padding()), CGSize(width: 760, height: 420)))
            shots.append(("md-only", nil, AnyView(MarkdownText(run.summary).padding()), CGSize(width: 760, height: 300)))
        }
        shots.append(("unavailable", nil, AnyView(ContentUnavailableView("Nothing", systemImage: "tray")), CGSize(width: 500, height: 300)))
        if let t = model.threads.first(where: { $0.title.hasPrefix("Compare") }) {
            shots.append(("thread", .thread(t.id), AnyView(ContentView()), size))
        }
        if let l = model.loops.first { shots.append(("loop", .loop(l.id), AnyView(ContentView()), size)) }
        if let p = model.threads.first(where: { $0.title.hasPrefix("Fix flaky") }) {
            shots.append(("project-thread", .thread(p.id), AnyView(ContentView()), size))
        }
        shots.append(("settings-messaging", nil, AnyView(ScrollView { MessagingSettingsView().environment(\.plainForms, true).padding() }), CGSize(width: 640, height: 1300)))
        shots.append(("settings-access", nil, AnyView(ScrollView { AccessSettingsView(tab: .constant(.access)).environment(\.plainForms, true).padding() }), CGSize(width: 640, height: 1800)))
        shots.append(("privacy-rows", nil, AnyView(PrivacyRowsPreview()), CGSize(width: 640, height: 760)))
        shots.append(("settings-general", nil, AnyView(ScrollView { GeneralSettingsView().environment(\.plainForms, true).padding() }), CGSize(width: 640, height: 1300)))
        if let l = model.loops.first {
            let dir = model.store.loopDataDir(for: l.id)
            try? "date,ticker,close,change %\n2026-10-29,NVDA,212.40,+3.1\n2026-10-30,NVDA,209.95,-1.2\n2026-10-30,\"AAPL, Inc\",271.10,+0.4\n"
                .write(to: dir.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
            try? "{\"seen\":[{\"company\":\"Acme\",\"fit\":9}]}".write(to: dir.appendingPathComponent("seen.json"), atomically: true, encoding: .utf8)
            shots.append(("notes", nil, AnyView(NotesBrowser(folder: dir)), CGSize(width: 420, height: 360)))
        }
        shots.append(("diff", nil, AnyView(DiffView(diff: "- db = connect(\"pg://localhost\")\n+ db = lancedb.connect(\"./data\")\n+ table = db.open_table(\"docs\")\n@@\n- old_line()").padding()), CGSize(width: 560, height: 160)))
        shots.append(("today", nil, AnyView(TodayOverview().padding()), CGSize(width: 620, height: 320)))
        shots.append(("getting-started", nil, AnyView(GettingStarted().padding()), CGSize(width: 560, height: 380)))
        shots.append(("sessions", nil, AnyView(SessionImportSheet()), CGSize(width: 640, height: 480)))
        shots.append(("messages", nil, AnyView(MessagesView()), CGSize(width: 760, height: 520)))
        if let t = model.threads.first(where: { $0.title.hasPrefix("Compare") }) {
            shots.append(("quick-ask", nil, AnyView(QuickAskView(threadId: t.id)), CGSize(width: 620, height: 440)))
        }
        shots.append(("whats-new", nil, AnyView(WhatsNewView()), CGSize(width: 560, height: 560)))
        shots.append(("help", nil, AnyView(HelpView()), CGSize(width: 720, height: 520)))
        shots.append(("palette", nil, AnyView(CommandPalette()), CGSize(width: 560, height: 420)))
        shots.append(("wizard", nil, AnyView(LoopWizard()), CGSize(width: 640, height: 560)))

        var i = 0
        func next() {
            guard i < shots.count else { exit(0) }
            let (name, selection, view, size) = shots[i]
            i += 1
            if let selection { model.selection = selection }
            render(view.environment(model), size: size, to: dir.appendingPathComponent("\(name).png")) { next() }
        }
        next()
    }

    static func render(_ view: some View, size: CGSize, to url: URL, done: @escaping @MainActor () -> Void) {
        // SwiftUI opens the app's own main window at launch; keep it (and everything else) off the user's screen.
        for w in NSApp.windows { w.orderOut(nil) }
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        // AppKit moves titled windows back onto a screen anyway; invisible + click-through keeps them out of the way.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        if ProcessInfo.processInfo.environment["SNAPSHOT_DARK"] != nil {
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .windowBackgroundColor
        }
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out and lists load before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("wrote \(url.path)")
                }
                window.orderOut(nil)
                done()
            }
        }
    }

    static func seed(_ model: AppModel) {
        let store = model.store
        if store.loadLoops().isEmpty {
            // Sample loops for the screenshots only; Automate itself ships none.
            store.createLoop(named: "price-watch", contents: "---\nname: Price watch\nenabled: false\nschedule: daily 09:00\nautonomy: split\nmodel: sonnet\n---\nWatch the prices of the items in wishlist.md and draft a note when one drops.")
            store.createLoop(named: "news-digest", contents: "---\nname: News digest\nenabled: false\nschedule: weekdays 07:30\nautonomy: auto\nmodel: sonnet\n---\nFind the five most important tech stories since yesterday, one line each with a link.")
        }
        model.reloadLoops()
        let project = Project(path: "/Users/me/code/notes-app")
        model.projects = [project]

        var t = ChatThread(title: "Compare vector databases for the RAG prototype", projectId: nil,
                           model: "opus", effort: "high", permissionMode: .auto)
        t.items = [
            TranscriptItem(kind: .user, text: "Compare pgvector, Qdrant and LanceDB for a small RAG prototype."),
            TranscriptItem(kind: .toolUse, text: "pgvector vs qdrant vs lancedb benchmarks 2026", toolName: "WebSearch", toolUseId: "a"),
            TranscriptItem(kind: .toolResult, text: "12 results", toolUseId: "a"),
            { var e = TranscriptItem(kind: .toolUse, text: "/Users/me/code/rag/store.py", toolName: "Edit", toolUseId: "b")
              e.detail = "- db = connect(\"pg://localhost\")\n+ db = lancedb.connect(\"./data\")\n+ table = db.open_table(\"docs\")"
              return e }(),
            TranscriptItem(kind: .assistant, text: """
            ## Short answer
            Use **pgvector** if you already run Postgres; otherwise **LanceDB** is the least work.

            | Option | Setup | Best for |
            |---|---|---|
            | pgvector | Postgres extension | One database for everything |
            | Qdrant | Separate server | Filtering at scale |
            | LanceDB | Embedded, files on disk | Prototypes, notebooks |

            Steps to try it:
            1. `pip install lancedb`
            2. Load your chunks and embed them
               - keep chunks under 512 tokens
            3. Query with `table.search(vec).limit(5)`

            ```python
            import lancedb
            db = lancedb.connect("./data")
            tbl = db.create_table("docs", data)
            ```
            > Benchmarks vary a lot with dataset size; test with your own data.
            """),
            TranscriptItem(kind: .result, text: "Done in 48s"),
        ]
        // A real repo so the git badge has something to show.
        let repoDir = store.root.appendingPathComponent("notes-app")
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/bin/sh")
        git.arguments = ["-c", "cd '\(repoDir.path)' && git init -q -b main && echo a > a.swift && echo b > b.swift"]
        try? git.run(); git.waitUntilExit()
        let repoProject = Project(path: repoDir.path)
        model.projects = [project, repoProject]
        var pt = ChatThread(title: "Fix flaky login test", projectId: repoProject.id, model: "opus", effort: "high", permissionMode: .auto)
        pt.items = [TranscriptItem(kind: .user, text: "The login test fails about 1 in 5 runs. Find out why.")]
        model.threads = [t, pt]
        model.queuedMessages[t.id] = [AppModel.QueuedMessage(text: "Also check what Turso offers", replyVia: .telegram)]
        model.drafts[t.id] = "Which one handles 10M vectors best?"

        var run = LoopRun(loopId: model.loops.first?.id ?? "x", loopName: "Price watch", trigger: .schedule)
        run.status = .needsApproval
        run.approvalNumber = 14
        run.summary = """
        **2 prices dropped** (wishlist.md updated). Headphones are down 25% to $149, the lowest in 90 days.

        ## Needs approval
        - Draft a note asking the shop to match the lower price
        - Add the desk lamp to wishlist.md
        """
        var done = LoopRun(loopId: "news-digest", loopName: "News digest", trigger: .schedule)
        done.status = .succeeded
        done.summary = "1. **A new open-weights model** tops the coding benchmarks (link)\n2. A browser engine ships a big speed-up (link)"
        model.runs = [run, done]
        for id in ["news-digest"] {
            if let l = model.loops.first(where: { $0.id == id }) { try? LoopFileEditor.setEnabled(true, in: l.fileURL) }
        }
        model.reloadLoops()
        model.usage = [UsageWindow(name: "five_hour", utilization: 0.22, resetsAt: Date().addingTimeInterval(7200), status: "allowed"),
                       UsageWindow(name: "seven_day", utilization: 0.81, resetsAt: Date().addingTimeInterval(86400 * 3), status: "allowed")]
        model.messaging.debugRecord(.telegram, incoming: false, "🔔 Price watch needs you (#14)\n\n2 prices dropped.\n\nNeeds approval:\n1. Draft a note asking the shop to match the lower price\n2. Add the desk lamp to wishlist.md")
        model.messaging.debugRecord(.telegram, incoming: true, "approve 14 1")
        model.messaging.debugRecord(.telegram, incoming: false, "✅ Approved Price watch. I'll text you when it's done.")
        model.messaging.debugRecord(.imessage, incoming: true, "what's the weather this weekend?")
        model.messaging.debugRecord(.imessage, incoming: false, "💭 On it…")
        model.settings.messaging.telegramEnabled = true
        model.settings.messaging.imessageEnabled = true
        model.settings.messaging.imessageHandle = "+1 555 555 0100"
    }
}
#endif
