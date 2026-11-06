import SwiftUI
import AutomateCore

// MARK: - Inbox

struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unread = model.unreadThreads
        Group {
            if model.inbox.isEmpty && unread.isEmpty {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 6) {
                            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("Nothing needs you").font(.title3.weight(.semibold))
                            Text("New replies in your threads, and loops that want your OK before acting, show up here.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                        TodayOverview()
                        GettingStarted()
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        InboxSectionHeader(title: "Threads", systemImage: "bubble.left", count: unread.count) {
                            if !unread.isEmpty {
                                Button("Mark All as Read") { model.unreadThreadIds.removeAll() }
                            }
                        }
                        if unread.isEmpty {
                            Text("No unread threads").foregroundStyle(.secondary)
                        } else {
                            UnreadThreadList(threads: unread)
                        }
                        InboxSectionHeader(title: "Loops", systemImage: "arrow.triangle.2.circlepath", count: model.inbox.count) {}
                            .padding(.top, 8)
                        if model.inbox.isEmpty {
                            Text("No loops waiting for your OK").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.inbox) { run in
                                ApprovalCard(run: run, showOpen: true)
                            }
                        }
                        TodayOverview().padding(.top, 10)
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Inbox")
    }
}

struct InboxSectionHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage).font(.title3.weight(.semibold))
            if count > 0 {
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            accessory.buttonStyle(.link)
        }
    }
}

// MARK: - Unread

/// Threads with replies you haven't opened (or that you marked unread).
struct UnreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unread = model.unreadThreads
        Group {
            if unread.isEmpty {
                ContentUnavailableView("No unread threads", systemImage: "circle.badge",
                                       description: Text("When Claude answers in a thread you're not looking at, it shows up here. Right-click a thread to mark it unread."))
            } else {
                ScrollView {
                    UnreadThreadList(threads: unread).padding(16)
                }
            }
        }
        .navigationTitle("Unread")
        .toolbar {
            if !unread.isEmpty {
                Button("Mark All as Read") { model.unreadThreadIds.removeAll() }
            }
        }
    }
}

struct UnreadThreadList: View {
    let threads: [ChatThread]

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(threads) { UnreadThreadCard(thread: $0) }
        }
    }
}

struct UnreadThreadCard: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread.title).font(.headline).lineLimit(1)
                    if let project = model.project(for: thread) {
                        Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(thread.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                if let snippet = Self.lastReply(in: thread) {
                    Text(snippet).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Button { model.setUnread(thread.id, false) } label: {
                Image(systemName: "checkmark.circle").accessibilityLabel("Mark as Read")
            }
            .buttonStyle(.borderless)
            .help("Mark as Read")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.selection = .thread(thread.id) }
        .contextMenu {
            Button("Open") { model.selection = .thread(thread.id) }
            Button("Mark as Read") { model.setUnread(thread.id, false) }
        }
    }

    /// Claude's last message as plain prose on one line (headings, tables and code blocks left out).
    static func lastReply(in thread: ChatThread) -> String? {
        guard let item = thread.items.last(where: { $0.kind == .assistant || $0.kind == .error }) else { return nil }
        var inCode = false
        var parts: [String] = []
        for raw in item.text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line.hasPrefix("|") || line.hasPrefix("#") { continue }
            for prefix in ["> ", "- ", "* ", "+ "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
            parts.append(line)
            if parts.joined().count > 300 { break }
        }
        let text = parts.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return text.isEmpty ? nil : String(text.prefix(300))
    }
}

struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let run: LoopRun
    var showOpen = false
    /// ⌘↩ approves (only where there's a single card).
    var keyboardApprove = false
    @State private var note = ""
    @State private var unchecked: Set<Int> = []

    var body: some View {
        let items = ApprovalItems.parse(run.summary)
        let pickable = items.count >= 2
        let chosen = items.enumerated().filter { !unchecked.contains($0.offset) }.map(\.element)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(run.loopName, systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                if let n = run.approvalNumber {
                    Text("#\(n)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Text \"approve \(n)\" or \"skip \(n)\" from your phone")
                }
                Text(run.startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let until = run.snoozedUntil, until > Date() {
                    Label("until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showOpen {
                    Button("View Run") { model.selection = .run(run.id) }
                        .buttonStyle(.link)
                }
            }
            if pickable {
                let rest = ApprovalItems.removingSection(run.summary)
                if !rest.isEmpty { MarkdownText(rest) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs your OK — untick anything you don't want")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Toggle(isOn: Binding(
                            get: { !unchecked.contains(i) },
                            set: { on in if on { unchecked.remove(i) } else { unchecked.insert(i) } }
                        )) {
                            Text(MarkdownText.inline(item)).fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } else {
                MarkdownText(run.summary.isEmpty ? "(no summary)" : run.summary)
            }
            TextField("Note for Claude (optional), e.g. \"keep the emails short\"", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack {
                Menu("Snooze") {
                    Button("1 Hour") { model.snooze(runId: run.id, until: Date().addingTimeInterval(3600)) }
                    Button("This Evening (6 PM)") { model.snooze(runId: run.id, until: ComposerView.at(hour: 18, daysAhead: 0)) }
                    Button("Tomorrow Morning (9 AM)") { model.snooze(runId: run.id, until: ComposerView.at(hour: 9, daysAhead: 1)) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Not now: hide it until then, then remind me")
                Spacer()
                Button("Skip") { model.skip(runId: run.id) }
                Button(pickable && chosen.count < items.count ? "Approve \(chosen.count) of \(items.count)" : "Approve") {
                    model.approve(runId: run.id, note: pickable ? ApprovalItems.note(chosen: chosen, all: items, extra: note) : note)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickable && chosen.isEmpty)
                .modifier(CommandReturn(enabled: keyboardApprove))
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.25)))
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "All", needsYou = "Needs you", failed = "Failed", done = "Done"
        func matches(_ s: RunStatus) -> Bool {
            switch self {
            case .all: return true
            case .needsYou: return s == .needsApproval
            case .failed: return s == .failed || s == .cancelled
            case .done: return s == .succeeded || s == .nothingToDo || s == .approved || s == .skipped
            }
        }
    }

    var body: some View {
        Group {
            if model.runs.isEmpty {
                ContentUnavailableView("No loop runs yet", systemImage: "clock",
                                       description: Text("Turn on a loop in the sidebar, or press Run Now."))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Text(weekSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                    List(model.runs.filter { filter.matches($0.status) }) { run in
                        Button { model.selection = .run(run.id) } label: { RunRow(run: run, showLoopName: true) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }

    private var weekSummary: String {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let recent = model.runs.filter { $0.startedAt > weekAgo && $0.parentRunId == nil }
        let found = recent.filter { $0.status == .succeeded || $0.status == .needsApproval || $0.status == .approved || $0.status == .skipped }.count
        let quiet = recent.filter { $0.status == .nothingToDo }.count
        let failed = recent.filter { $0.status == .failed }.count
        var parts = ["\(recent.count) runs this week", "\(found) with news", "\(quiet) quiet"]
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

/// First-run checklist, shown while the inbox is empty. Items tick themselves off.
struct GettingStarted: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let steps: [(Bool, String, String, () -> Void)] = [
            (model.claude != nil && model.auth?.loggedIn != false, "Claude Code is connected",
             "Automate uses the claude command you're logged into, so it runs on your subscription.", { openSettings() }),
            (!model.projects.isEmpty, "Add a code folder", "Threads in a project can read, edit and run code there.", { model.addProject() }),
            (model.loops.contains(where: \.enabled), "Turn on a loop", "Or describe a job and let Claude write one (⇧⌘L).", { model.showLoopWizard = true }),
            (model.messaging.isAnyChannelOn, "Get texts on your phone", "Approve loops and chat with Claude by Telegram or iMessage.", { openSettings() }),
            (model.threads.count > 1, "Ask something", "⌘K jumps anywhere. ⌃⌥Space asks Claude from any app.", { QuickAsk.shared.show() }),
        ]
        if steps.contains(where: { !$0.0 }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Getting started").font(.headline).padding(.bottom, 6)
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Button(action: step.3) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.0 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(step.0 ? Color.green : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.1).strikethrough(step.0).foregroundStyle(step.0 ? .secondary : .primary)
                                Text(step.2).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !step.0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(step.0)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct RunRow: View {
    let run: LoopRun
    var showLoopName = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(status: run.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if showLoopName { Text(run.loopName).fontWeight(.medium) }
                    Text(run.status.label).foregroundStyle(.secondary)
                    if run.status == .needsApproval, let n = run.approvalNumber {
                        Text("#\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !run.summary.isEmpty {
                    Text(RemoteText.plain(run.summary).replacingOccurrences(of: "\n", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct StatusIcon: View {
    let status: RunStatus

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .nothingToDo: Image(systemName: "minus.circle").foregroundStyle(Color.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
        case .needsApproval: Image(systemName: "hand.raised.fill").foregroundStyle(Color.blue)
        case .approved: Image(systemName: "hand.thumbsup.fill").foregroundStyle(Color.green)
        case .skipped: Image(systemName: "forward.fill").foregroundStyle(Color.secondary)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(Color.secondary)
        }
    }
}

// MARK: - Run detail

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let runId: UUID

    var body: some View {
        if let run = model.runs.first(where: { $0.id == runId }) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    StatusIcon(status: run.status).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.loopName).font(.title3.weight(.semibold))
                        Text("\(run.status.label) · started by \(run.trigger.rawValue) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if run.status == .running {
                        Button { model.cancel(runId: run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    }
                    if run.status.isFinished, run.parentRunId == nil, let loop = model.loops.first(where: { $0.id == run.loopId }) {
                        Button { model.runNow(loop) } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                            .disabled(model.isRunning(loopId: loop.id))
                    }
                    Button { model.continueInThread(run) } label: { Label("Continue in Thread", systemImage: "bubble.left.and.bubble.right") }
                        .disabled(run.sessionId == nil || run.status == .running)
                    if model.loops.contains(where: { $0.id == run.loopId }) {
                        Button { model.selection = .loop(run.loopId) } label: { Label("Loop", systemImage: "arrow.triangle.2.circlepath") }
                    }
                }
                .padding(16)

                if run.status == .needsApproval {
                    ApprovalCard(run: run, keyboardApprove: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                if let parentId = run.parentRunId {
                    Button("← Original run") { model.selection = .run(parentId) }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                Divider()
                TranscriptView(items: run.items, isRunning: run.status == .running)
            }
        } else {
            ContentUnavailableView("Run not found", systemImage: "questionmark.circle")
        }
    }
}

// MARK: - Loop detail

struct LoopDetailView: View {
    @Environment(AppModel.self) private var model
    let loopId: String
    @State private var draft = ""
    @State private var savedText = ""
    @State private var confirmDelete = false
    @State private var sidePane = 0
    @State private var askingRunNote = false
    @State private var runNote = ""

    var body: some View {
        if let loop = model.loops.first(where: { $0.id == loopId }) {
            VStack(spacing: 0) {
                header(loop)
                if !loop.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(loop.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                LoopQuickSettings(text: $draft) { change in
                    // Settings changed from the bar save right away (applied to the file as it is on disk now,
                    // so nothing written meanwhile is undone), unless you're mid-edit in the text.
                    if draft == savedText {
                        let fresh = (try? String(contentsOf: loop.fileURL, encoding: .utf8)) ?? draft
                        let edited = change(fresh)
                        model.saveLoopText(edited, for: loop)
                        draft = edited
                        savedText = edited
                    } else {
                        draft = change(draft)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                Divider()
                HSplitView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(loop.projectRoot.map { "\($0.lastPathComponent)/.automate/loops/" } ?? "")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                + Text(loop.fileURL.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Revert") { draft = savedText }.disabled(draft == savedText)
                            Button("Save") {
                                model.saveLoopText(draft, for: loop)
                                savedText = draft
                            }
                            .keyboardShortcut("s")
                            .disabled(draft == savedText)
                        }
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(12)
                    .frame(minWidth: 360)

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $sidePane) {
                            Text("Runs").tag(0)
                            Text("Notes").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding([.top, .horizontal], 12)
                        if sidePane == 1 {
                            NotesBrowser(folder: model.store.loopDataDir(for: loop)) { model.askAboutNotes(of: loop) }
                        } else {
                            let loopRuns = model.runs(for: loop.id)
                            if loopRuns.isEmpty {
                                Text("No runs yet.").foregroundStyle(.secondary).padding(12)
                                Spacer()
                            } else {
                                List(loopRuns) { run in
                                    Button { model.selection = .run(run.id) } label: { RunRow(run: run) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320)
                }
            }
            .onAppear { load(loop) }
            .onChange(of: model.loopsVersion) {
                // The file changed (another editor, or Automate switched it off): show it, unless you have edits.
                if draft == savedText, let fresh = model.loops.first(where: { $0.id == loopId }) { load(fresh) }
            }
            .alert("Run \(loop.name) with a note", isPresented: $askingRunNote) {
                TextField("e.g. this time, focus on NVDA", text: $runNote)
                Button("Run") { model.runNow(loop, note: runNote) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("An extra instruction for this run only.")
            }
            .confirmationDialog("Move \"\(loop.name)\" to the Trash?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { model.deleteLoop(loop) }
            } message: {
                Text("Its notes folder and run history are kept.")
            }
        } else {
            ContentUnavailableView("Loop not found", systemImage: "questionmark.circle",
                                   description: Text("Its file may have been renamed or deleted."))
        }
    }

    private func header(_ loop: LoopDefinition) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loop.name).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(loop.triggerSummary)
                    Text("·")
                    Text("\(loop.autonomy.rawValue) mode")
                    if let next = LoopScheduler.nextRun(for: loop, state: model.loopState, now: Date()) {
                        Text("·")
                        Text("next \(next.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                RunHistoryDots(runs: model.runs(for: loop.id).filter { $0.parentRunId == nil })
            }
            Spacer()
            Toggle("On", isOn: Binding(
                get: { loop.enabled },
                set: { value in
                    let unedited = draft == savedText
                    model.setEnabled(value, for: loop)
                    if unedited, let fresh = model.loops.first(where: { $0.id == loopId }) { load(fresh) }
                }
            ))
            .toggleStyle(.switch)
            Button { model.runNow(loop) } label: { Label("Run Now", systemImage: "play.fill") }
                .disabled(model.isRunning(loopId: loop.id))
            Menu {
                Button("Run with Note…") { runNote = ""; askingRunNote = true }
                    .disabled(model.isRunning(loopId: loop.id))
                Button("Dry Run (propose only)") { model.dryRun(loop) }
                    .disabled(model.isRunning(loopId: loop.id))
                Divider()
                Button("Open in Editor") { NSWorkspace.shared.open(loop.fileURL) }
                Button("Show Notes Folder") { NSWorkspace.shared.open(model.store.loopDataDir(for: loop)) }
                if !model.projects.isEmpty {
                    Menu("Move to Project") {
                        // Moves the file and its notes into the project's .automate folder (or back out).
                        if loop.projectId != nil {
                            Button("Automate's Loops Folder") { model.moveLoop(loop, to: nil) }
                            Divider()
                        }
                        ForEach(model.projects.filter { $0.id != loop.projectId }) { p in
                            Button(p.name) { model.moveLoop(loop, to: p) }
                        }
                    }
                    .disabled(model.isRunning(loopId: loop.id))
                }
                Button("Reload from Disk") {
                    model.reloadLoops()
                    if let fresh = model.loops.first(where: { $0.id == loopId }) { load(fresh) }
                }
                Divider()
                Button("Delete Loop…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(16)
    }

    private func load(_ loop: LoopDefinition) {
        let text = (try? String(contentsOf: loop.fileURL, encoding: .utf8)) ?? ""
        draft = text
        savedText = text
    }
}

/// The common loop settings as controls. Each change edits the frontmatter, so the file stays the source of truth.
struct LoopQuickSettings: View {
    @Binding var text: String
    /// Receives the edit to make to the file's text.
    let apply: ((String) -> String) -> Void
    @State private var scheduleDraft = ""
    @FocusState private var scheduleFocused: Bool

    var body: some View {
        let loop = LoopDefinition.parse(text: text, fileURL: URL(fileURLWithPath: "/tmp/x.md"))
        let scheduleOK = scheduleDraft.trimmingCharacters(in: .whitespaces).isEmpty || Schedule.parse(scheduleDraft) != nil

        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                TextField("No schedule", text: $scheduleDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .focused($scheduleFocused)
                    .foregroundStyle(scheduleOK ? Color.primary : Color.red)
                    .onSubmit(commitSchedule)
                    .onChange(of: scheduleFocused) { _, focused in if !focused { commitSchedule() } }
                    .help("every 30m · hourly · daily 09:00 · weekdays 18:30 · mon,wed 07:15 · or cron like 0 9 * * 1-5. Press Return to apply.")
            }
            HStack(spacing: 2) {
                ForEach(LoopTrigger.allCases, id: \.self) { trig in
                    Toggle(trig.rawValue.capitalized, isOn: Binding(
                        get: { loop.triggers.contains(trig) },
                        set: { on in
                            var set = loop.triggers
                            if on { set.insert(trig) } else { set.remove(trig) }
                            let list = LoopTrigger.allCases.filter(set.contains).map(\.rawValue)
                            apply { LoopFileEditor.updated($0, key: "triggers", value: "[\(list.joined(separator: ", "))]") }
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Also run when the Mac \(trig == .launch ? "logs in / Automate starts" : trig == .wake ? "wakes from sleep" : "screen is unlocked")")
                }
            }
            menu("Autonomy", value: loop.autonomy.rawValue, options: ["auto", "split", "ask"], key: "autonomy",
                 help: "auto: does everything · split: does the safe parts, asks for the rest · ask: researches, then proposes")
            menu("Model", value: loop.model ?? "default", options: ComposerView.models, key: "model", help: "Claude model")
            menu("Notify", value: loop.notify.rawValue, options: ["always", "changes", "never"], key: "notify",
                 help: "Mac notifications: always · only when something changed or needs you · never")
            menu("Text", value: loop.message?.rawValue ?? "same", options: ["same", "always", "changes", "never"], key: "message",
                 help: "Texts to your phone (Settings → Messaging). \"same\" follows Notify.")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .onAppear { scheduleDraft = loop.scheduleText ?? "" }
        .onChange(of: loop.scheduleText) { _, new in if !scheduleFocused { scheduleDraft = new ?? "" } }
    }

    private func menu(_ title: String, value: String, options: [String], key: String, help: String) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    apply { opt == "same" ? LoopFileEditor.removing($0, key: key) : LoopFileEditor.updated($0, key: key, value: opt) }
                } label: {
                    if opt == value { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                }
            }
        } label: {
            Text("\(title): \(value)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
    }

    private func commitSchedule() {
        let s = scheduleDraft.trimmingCharacters(in: .whitespaces)
        let current = LoopDefinition.parse(text: text, fileURL: URL(fileURLWithPath: "/tmp/x.md")).scheduleText ?? ""
        guard s != current else { return }
        if s.isEmpty {
            apply { LoopFileEditor.removing($0, key: "schedule") }
        } else if Schedule.parse(s) != nil {
            apply { LoopFileEditor.updated($0, key: "schedule", value: s) }
        }
    }
}

/// The last 30 runs as colored dots, oldest first: green done, gray quiet, blue needed you, red failed.
struct RunHistoryDots: View {
    @Environment(AppModel.self) private var model
    let runs: [LoopRun]

    var body: some View {
        if !runs.isEmpty {
            HStack(spacing: 3) {
                ForEach(runs.prefix(30).reversed()) { run in
                    Circle()
                        .fill(color(run.status))
                        .frame(width: 7, height: 7)
                        .help("\(run.status.label) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .onTapGesture { model.selection = .run(run.id) }
                }
            }
            .padding(.top, 2)
        }
    }

    private func color(_ s: RunStatus) -> Color {
        switch s {
        case .succeeded, .approved: return .green
        case .nothingToDo, .skipped, .cancelled: return .secondary.opacity(0.5)
        case .needsApproval: return .blue
        case .failed: return .red
        case .running: return .orange
        }
    }
}

/// What's next on the schedule and what loops found today.
struct TodayOverview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = Date()
        let upcoming = model.loops.compactMap { loop -> (LoopDefinition, Date)? in
            LoopScheduler.nextRun(for: loop, state: model.loopState, now: now).map { (loop, $0) }
        }
        .sorted { $0.1 < $1.1 }
        .prefix(5)
        let today = model.runs.filter {
            Calendar.current.isDateInToday($0.startedAt) && $0.parentRunId == nil
                && [.succeeded, .approved, .skipped, .failed].contains($0.status)
        }
        .prefix(6)

        if !upcoming.isEmpty || !today.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Coming up").font(.headline)
                        ForEach(Array(upcoming), id: \.0.id) { loop, date in
                            HStack {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                Button(loop.name) { model.selection = .loop(loop.id) }.buttonStyle(.link)
                                Spacer()
                                Text(date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                                                    : .dateTime.weekday().hour().minute()))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button { model.runNow(loop) } label: { Image(systemName: "play.fill").accessibilityLabel("Run \(loop.name) now") }
                                    .buttonStyle(.borderless)
                                    .help("Run now")
                                    .disabled(model.isRunning(loopId: loop.id))
                            }
                        }
                        if let held = model.loopsHeldReason {
                            Label(held, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !today.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Today").font(.headline)
                        ForEach(Array(today)) { run in
                            Button { model.selection = .run(run.id) } label: { RunRow(run: run, showLoopName: true) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// ⌘↩ on a button, when enabled.
struct CommandReturn: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.return, modifiers: .command) } else { content }
    }
}
