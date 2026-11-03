import SwiftUI
import AutomateCore

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let threadId: UUID

    var body: some View {
        if let thread = model.threads.first(where: { $0.id == threadId }) {
            VStack(spacing: 0) {
                ThreadHeader(thread: thread)
                Divider()
                ChangedFilesBar(items: thread.items)
                if thread.items.isEmpty {
                    EmptyThreadHint(isProject: thread.projectId != nil)
                } else {
                    TranscriptView(items: thread.items, isRunning: model.runningThreadIds.contains(threadId))
                }
                if !model.runningThreadIds.contains(threadId), let failed = Self.lastFailure(thread.items) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
                        if let reset = model.usage.first(where: { $0.status == "rejected" || $0.utilization >= 1 })?.resetsAt, reset > Date() {
                            Text("You've hit a usage limit. It resets \(reset.formatted(date: .omitted, time: .shortened)).")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("That didn't finish.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") { model.send(failed, in: threadId) }
                            .help("Send your last message again")
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.08))
                }
                Divider()
                ComposerView(threadId: threadId)
            }
        } else {
            ContentUnavailableView("Thread not found", systemImage: "questionmark.bubble")
        }
    }
}

extension ThreadView {
    /// Your last message, if Claude's answer to it ended in an error (not when you pressed Stop).
    static func lastFailure(_ items: [TranscriptItem]) -> String? {
        guard let last = items.last, last.isError, last.kind == .error || last.kind == .result,
              last.text != "Stopped." else { return nil }
        return items.last(where: { $0.kind == .user })?.text
    }
}

struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        let folder = model.workingDirectory(for: thread)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: Binding(
                    get: { thread.title },
                    set: { value in model.updateThread(thread.id) { $0.title = value } }
                ))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                Text(model.project(for: thread)?.path ?? (thread.workingDirectory ?? "Research workspace"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if thread.projectId != nil {
                GitBadge(thread: thread, folder: folder)
            }
            if thread.projectId != nil {
                if thread.sessionId == nil && thread.workingDirectory == nil {
                    Toggle(isOn: Binding(
                        get: { thread.useWorktree ?? false },
                        set: { v in model.updateThread(thread.id) { $0.useWorktree = v } }
                    )) {
                        Label("Own branch", systemImage: "arrow.triangle.branch")
                    }
                    .toggleStyle(.button)
                    .help("Work in a separate git worktree and branch, so several threads can change this repo at once without colliding.")
                }
            }
            if let projectId = thread.projectId {
                Button { model.selection = .memory(projectId) } label: { Label("Memory", systemImage: "brain") }
            }
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                ForEach(Handoff.editors) { editor in
                    Button("Open in \(editor.name)") { Handoff.open([folder], in: editor) }
                }
                Divider()
                Button("Continue in Terminal") {
                    guard let sid = thread.sessionId, let claude = model.claude else { return }
                    if let err = Handoff.continueInTerminal(sessionId: sid, folder: folder, claude: claude.executable) {
                        model.banner = "Couldn't open Terminal: \(err)"
                    }
                }
                .disabled(thread.sessionId == nil || model.runningThreadIds.contains(thread.id))
                .help("An interactive claude session with this conversation, where you can answer permission prompts")
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            } primaryAction: {
                if let editor = Handoff.editors.first, thread.projectId != nil { Handoff.open([folder], in: editor) }
                else { NSWorkspace.shared.open(folder) }
            }
            .fixedSize()
            .help(thread.projectId != nil && Handoff.editors.first != nil
                  ? "Open the folder in \(Handoff.editors.first!.name) (click the arrow for more)" : "Show the folder (click the arrow for more)")
            Menu {
                Button(thread.pinned ? "Unpin" : "Pin") { model.updateThread(thread.id) { $0.pinned.toggle() } }
                Button("Start Fresh Session") {
                    model.updateThread(thread.id) {
                        $0.sessionId = nil
                        $0.items.append(TranscriptItem(kind: .info, text: "New session — earlier messages won't be remembered."))
                    }
                }
                .disabled(model.runningThreadIds.contains(thread.id))
                Button("Turn into Loop…") { model.turnIntoLoop(thread.id) }
                    .help("Make what you did here run on a schedule")
                    .disabled(!thread.items.contains { $0.kind == .user })
                Button("Duplicate Thread") { model.duplicateThread(thread.id) }
                    .help("A copy that remembers this conversation but continues separately")
                Divider()
                Button("Copy Conversation") {
                    copyToPasteboard(TranscriptExport.markdown(title: thread.title, items: thread.items))
                }
                Button("Export as Markdown…") { model.exportThread(thread.id) }
                if model.messaging.isAnyChannelOn, let last = thread.items.last(where: { $0.kind == .assistant }) {
                    Button("Send Last Reply to Phone") { model.messaging.send(RemoteText.plain(last.text)) }
                }
                if model.messaging.canReceive {
                    Button("Continue on Phone") { model.continueOnPhone(thread.id) }
                        .help("Your texts go to this thread, starting with its last reply")
                    Button(model.remoteThreadId == thread.id ? "Texts from Phone Come Here ✓" : "Use for Texts from Phone") {
                        model.remoteThreadId = thread.id
                    }
                }
                Divider()
                Button(thread.archived ? "Unarchive" : "Archive") { model.updateThread(thread.id) { $0.archived.toggle() } }
                Divider()
                Button("Delete Thread", role: .destructive) { model.deleteThread(thread.id) }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct EmptyThreadHint: View {
    @Environment(AppModel.self) private var model
    let isProject: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isProject ? "chevron.left.forwardslash.chevron.right" : "globe")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(isProject ? "Ask Claude to build, fix or explain something in this folder."
                           : "Research anything. Claude can search the web and save files here.")
                .foregroundStyle(.secondary)
            Text(model.settings.returnSends ? "↩ to send · ⇧↩ new line" : "⌘↩ to send")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let threadId: UUID
    @State private var dropTargeted = false
    @State private var pickingTime = false
    @State private var pickedDate = Date().addingTimeInterval(3600)

    static let models = ["opus", "sonnet", "haiku", "fable"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        let thread = model.threads.first { $0.id == threadId }
        let running = model.runningThreadIds.contains(threadId)
        let currentModel = thread?.model ?? model.settings.defaultModel
        let modelChoices = Self.models.contains(currentModel) ? Self.models : Self.models + [currentModel]
        let text = Binding(get: { model.drafts[threadId] ?? "" }, set: { model.drafts[threadId] = $0 })
        let queued = model.queuedMessages[threadId] ?? []
        let scheduled = (thread?.scheduled ?? []).sorted { $0.date < $1.date }

        VStack(spacing: 8) {
            if !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scheduled) { m in
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                            Text(m.date.formatted(Calendar.current.isDateInToday(m.date) ? .dateTime.hour().minute()
                                                  : .dateTime.weekday().month().day().hour().minute()))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(m.text).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Button { model.unschedule(m.id, in: threadId) } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Cancel scheduled message") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Don't send this")
                        }
                        .font(.callout)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !queued.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(queued) { q in
                        HStack(spacing: 6) {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            Text(q.text).lineLimit(1).truncationMode(.tail)
                            if q.replyVia != nil { Image(systemName: "iphone").foregroundStyle(.secondary) }
                            Spacer()
                            Button { model.removeQueued(q.id, from: threadId) } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Remove queued message") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Don't send this")
                        }
                        .font(.callout)
                    }
                    Text("Queued: sent when Claude finishes the current reply.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: Self.editorHeight(for: text.wrappedValue))
                    .onKeyPress(.return, phases: .down) { press in
                        guard model.settings.returnSends, press.modifiers.isDisjoint(with: [.shift, .option, .command]) else {
                            return .ignored
                        }
                        // Return also confirms input-method text (Japanese, Chinese…); let that through.
                        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return .ignored }
                        submit()
                        return .handled
                    }
                if text.wrappedValue.isEmpty {
                    Text(running ? "Claude is working… type your next message and it'll be sent after." : "Message Claude (drop files or screenshots here)")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: dropTargeted ? 2 : 1))
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.filter(\.isFileURL).compactMap { model.attachmentPath(for: $0, in: threadId) }
                guard !paths.isEmpty else { return false }
                insert(paths)
                return true
            } isTargeted: { dropTargeted = $0 }

            HStack(spacing: 10) {
                Picker("Model", selection: Binding(
                    get: { currentModel },
                    set: { v in model.updateThread(threadId) { $0.model = v } }
                )) {
                    ForEach(modelChoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)

                Picker("Effort", selection: Binding(
                    get: { thread?.effort ?? model.settings.defaultEffort },
                    set: { v in model.updateThread(threadId) { $0.effort = v } }
                )) {
                    ForEach(Self.efforts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)

                Picker("Permissions", selection: Binding(
                    get: { thread?.permissionMode ?? model.settings.defaultPermission },
                    set: { v in model.updateThread(threadId) { $0.permissionMode = v } }
                )) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)

                Toggle(isOn: Binding(
                    get: { thread?.useChrome ?? false },
                    set: { v in model.updateThread(threadId) { $0.useChrome = v } }
                )) {
                    Label("Chrome", systemImage: "globe")
                }
                .toggleStyle(.button)
                .help("Let Claude use your Chrome through the Claude in Chrome extension. Chrome must be open. Works in Auto and Bypass; Plan and Accept edits block it.")

                Menu {
                    let isProject = thread?.projectId != nil
                    ForEach(model.settings.prompts.filter { isProject || !$0.forProjects }) { p in
                        Button(p.title) {
                            let current = model.drafts[threadId] ?? ""
                            model.drafts[threadId] = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? p.text : current + "\n\n" + p.text
                        }
                    }
                    Divider()
                    Button("Save Message as Prompt") {
                        let text = (model.drafts[threadId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = String(text.components(separatedBy: "\n").first?.prefix(40) ?? "Prompt")
                        model.settings.prompts.append(SavedPrompt(title: title, text: text, forProjects: isProject))
                    }
                    .disabled((model.drafts[threadId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Edit Prompts…") { model.showPromptEditor = true }
                } label: {
                    Image(systemName: "bolt").accessibilityLabel("Saved prompts")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Saved prompts")

                Menu {
                    Button("Choose Files…") { chooseFiles() }
                    Button("Paste Image from Clipboard") {
                        if let p = model.pasteImageAttachment() { insert([p]) }
                    }
                    .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
                } label: {
                    Image(systemName: "paperclip").accessibilityLabel("Attach")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files or a screenshot. Claude can read images, PDFs and text files.")

                Spacer()

                if running {
                    Button { model.stopThread(threadId) } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: .command)
                }
                Menu {
                    Button("In 1 Hour") { scheduleDraft(Date().addingTimeInterval(3600)) }
                    Button("This Evening (6 PM)") { scheduleDraft(Self.at(hour: 18, daysAhead: 0)) }
                    Button("Tomorrow Morning (9 AM)") { scheduleDraft(Self.at(hour: 9, daysAhead: 1)) }
                    Button("Pick a Time…") {
                        pickedDate = Date().addingTimeInterval(3600)
                        pickingTime = true
                    }
                } label: {
                    Image(systemName: "clock").accessibilityLabel("Send later")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Send later")
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .popover(isPresented: $pickingTime) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("Send at", selection: $pickedDate, in: Date()...)
                            .datePickerStyle(.field)
                        HStack {
                            Spacer()
                            Button("Schedule") {
                                scheduleDraft(pickedDate)
                                pickingTime = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                    .frame(width: 300)
                }

                Button { submit() } label: { Label(running ? "Queue" : "Send", systemImage: running ? "text.badge.plus" : "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    /// Grows with what you type: 2 lines empty, up to about 8 before it scrolls.
    static func editorHeight(for text: String) -> CGFloat {
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 95))) }
        return min(160, max(40, CGFloat(lines) * 17 + 8))
    }

    private func insert(_ paths: [String]) {
        let quoted = paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        let current = model.drafts[threadId] ?? ""
        let sep = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " "
        model.drafts[threadId] = current + sep + quoted.joined(separator: " ") + " "
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        insert(panel.urls.compactMap { model.attachmentPath(for: $0, in: threadId) })
    }

    static func at(hour: Int, daysAhead: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: daysAhead, to: Date())!
        let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return d > Date() ? d : cal.date(byAdding: .day, value: 1, to: d)!
    }

    private func scheduleDraft(_ date: Date) {
        let message = model.drafts[threadId] ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.schedule(message, at: date, in: threadId)
        model.drafts[threadId] = nil
    }

    private func submit() {
        let message = model.drafts[threadId] ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.drafts[threadId] = nil
        model.send(message, in: threadId)
    }
}

/// Files Claude edited in this thread, newest first; click to open.
struct ChangedFilesBar: View {
    let items: [TranscriptItem]

    var body: some View {
        let files = Self.changedFiles(items)
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Label("\(files.count) changed", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { path in
                        Button {
                            // Reveal rather than open: a file Claude wrote could be something that runs when opened.
                            if let editor = Handoff.editors.first { Handoff.open([URL(fileURLWithPath: path)], in: editor) }
                            else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        } label: {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(path)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            ForEach(Handoff.editors) { e in
                                Button("Open in \(e.name)") { Handoff.open([URL(fileURLWithPath: path)], in: e) }
                            }
                            Button("Copy Path") { copyToPasteboard(path) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    static func changedFiles(_ items: [TranscriptItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let failed = Set(items.compactMap { $0.kind == .toolResult && $0.isError ? $0.toolUseId : nil })
        for item in items.reversed() where item.kind == .toolUse {
            guard ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(item.toolName ?? ""), item.text.hasPrefix("/"),
                  !(item.toolUseId.map(failed.contains) ?? false) else { continue }
            if seen.insert(item.text).inserted { out.append(item.text) }
        }
        return out
    }
}

/// Branch and uncommitted changes for a project thread's folder; click for the list and quick actions.
struct GitBadge: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let folder: URL
    @State private var status: GitStatus?
    @State private var showing = false

    var body: some View {
        let running = model.runningThreadIds.contains(thread.id)
        Group {
            if let status {
                Button { showing.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(status.branch).lineLimit(1)
                        if !status.changes.isEmpty {
                            Text("· \(status.changes.count) changed").foregroundStyle(Color.orange)
                        }
                        if status.ahead > 0 { Text("↑\(status.ahead)") }
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Git status of this folder")
                .popover(isPresented: $showing, arrowEdge: .bottom) { popover(status, running: running) }
            } else {
                Color.clear.frame(width: 1, height: 1) // gives .task a view to run on
            }
        }
        .task(id: "\(thread.updatedAt.timeIntervalSince1970)-\(running)") {
            let dir = folder
            status = await Task.detached { GitStatus.read(dir) }.value
        }
    }

    private func popover(_ status: GitStatus, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(status.branch)" + (status.ahead > 0 ? " · \(status.ahead) commit\(status.ahead == 1 ? "" : "s") not pushed" : ""))
                .font(.headline)
            if status.changes.isEmpty {
                Text("No uncommitted changes.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status.changes.prefix(60), id: \.self) { line in
                            Text(line).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        if status.changes.count > 60 { Text("… \(status.changes.count - 60) more").font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                HStack {
                    Button("Review Changes") { ask("Review my uncommitted changes (git diff) for bugs and risky edits. List problems by severity with file:line. Don't change anything yet.") }
                    Button("Commit…") { ask("Commit the current changes with a clear message (group related changes into separate commits if it helps). Don't push.") }
                }
                .disabled(running)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func ask(_ text: String) {
        showing = false
        model.send(text, in: thread.id)
    }
}
