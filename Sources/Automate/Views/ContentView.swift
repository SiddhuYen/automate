import SwiftUI
import AutomateCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let undo = model.undo {
                    HStack {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                        Text(undo.text).lineLimit(1)
                        Spacer()
                        Button("Undo") {
                            undo.perform()
                            model.undo = nil
                        }
                        Button { model.undo = nil } label: { Image(systemName: "xmark").accessibilityLabel("Dismiss") }.buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .task(id: undo.id) {
                        try? await Task.sleep(for: .seconds(12))
                        if model.undo?.id == undo.id { model.undo = nil }
                    }
                }
                if let banner = model.banner {
                    BannerView(text: banner) { model.banner = nil }
                }
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let open = openWindow
            model.openMainWindowAction = { open(id: "main") }
        }
        .onChange(of: model.inbox.count, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .sheet(isPresented: Binding(get: { model.showPalette }, set: { model.showPalette = $0 })) {
            CommandPalette().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showLoopWizard }, set: { model.showLoopWizard = $0 })) {
            LoopWizard().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showPromptEditor }, set: { model.showPromptEditor = $0 })) {
            PromptEditor().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showSessionImport }, set: { model.showSessionImport = $0 })) {
            SessionImportSheet().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.showHelp }, set: { model.showHelp = $0 })) {
            HelpView()
        }
        .sheet(isPresented: Binding(get: { model.showWhatsNew }, set: { model.showWhatsNew = $0 })) {
            WhatsNewView().environment(model)
        }
        .sheet(item: Binding(get: { model.editingProject }, set: { model.editingProject = $0 })) { project in
            ProjectSettingsSheet(project: project).environment(model)
        }
        .confirmationDialog("Remove \(model.confirmRemoveProject?.name ?? "project") from Automate?",
                            isPresented: Binding(get: { model.confirmRemoveProject != nil },
                                                 set: { if !$0 { model.confirmRemoveProject = nil } }),
                            presenting: model.confirmRemoveProject) { project in
            Button("Remove and Delete Its Threads", role: .destructive) { model.removeProject(project) }
        } message: { _ in
            Text("Its threads are deleted. The folder itself and the project's memory file are kept, so adding the folder again brings the memory back.")
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .inbox, .none:
            InboxView()
        case .activity:
            ActivityView()
        case .loop(let id):
            LoopDetailView(loopId: id).id(id)
        case .run(let id):
            RunDetailView(runId: id).id(id)
        case .thread(let id):
            ThreadView(threadId: id).id(id)
        case .memory(let id):
            MemoryView(projectId: id).id(id)
        case .unread:
            UnreadView()
        case .messages:
            MessagesView()
        case .running:
            RunningView()
        }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").accessibilityLabel("Dismiss") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

/// Section header with a small trailing control (usually a + button).
struct SectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showArchived = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                sections
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search threads & loops")
        // Drop a folder here to add it as a project.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for folder in folders { model.addProject(at: folder) }
            return !folders.isEmpty
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let held = model.loopsHeldReason {
                    HStack {
                        Label(held, systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer()
                        if model.pausedUntil != nil {
                            Button("Resume") { model.pauseLoops(until: nil) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
                if !model.usage.isEmpty { UsageMeter(windows: model.usage) }
                HStack {
                    Button { model.addProject() } label: { Label("Add Project…", systemImage: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    let busy = model.runningLoopCount + model.runningThreadIds.count
                    if busy > 0 {
                        Button { model.selection = .running } label: {
                            Label("\(busy) running", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("See and stop what's running")
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var searchResults: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let loops = model.loops.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.instructions.localizedCaseInsensitiveContains(q) }
        let threads = model.threads.filter { t in
            t.title.localizedCaseInsensitiveContains(q) || t.items.contains { $0.kind != .toolResult && $0.text.localizedCaseInsensitiveContains(q) }
        }
        if loops.isEmpty && threads.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        }
        if !loops.isEmpty {
            Section("Loops") {
                ForEach(loops) { loop in LoopRow(loop: loop).tag(SidebarItem.loop(loop.id)) }
            }
        }
        if !threads.isEmpty {
            Section("Threads") {
                ForEach(threads) { thread in
                    VStack(alignment: .leading, spacing: 2) {
                        ThreadRow(thread: thread)
                        if let snippet = Self.snippet(in: thread, matching: q) {
                            Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .tag(SidebarItem.thread(thread.id))
                }
            }
        }
    }

    /// Collapsed sections are remembered across launches.
    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !model.collapsedSections.contains(key) },
                set: { open in if open { model.collapsedSections.remove(key) } else { model.collapsedSections.insert(key) } })
    }

    static func snippet(in thread: ChatThread, matching q: String) -> String? {
        guard let item = thread.items.first(where: { $0.kind != .toolResult && $0.text.localizedCaseInsensitiveContains(q) }),
              let r = item.text.range(of: q, options: .caseInsensitive) else { return nil }
        let start = item.text.index(r.lowerBound, offsetBy: -40, limitedBy: item.text.startIndex) ?? item.text.startIndex
        let end = item.text.index(r.upperBound, offsetBy: 80, limitedBy: item.text.endIndex) ?? item.text.endIndex
        return (start > item.text.startIndex ? "…" : "") + item.text[start..<end].replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder private var sections: some View {
            Section {
                Label("Inbox", systemImage: "tray")
                    .badge(model.inbox.count)
                    .tag(SidebarItem.inbox)
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.activity)
                Label("Unread", systemImage: "circle.badge")
                    .badge(model.unreadThreads.count)
                    .tag(SidebarItem.unread)
                if model.runningLoopCount + model.runningThreadIds.count > 0 {
                    Label("Running", systemImage: "bolt.fill")
                        .badge(model.runningLoopCount + model.runningThreadIds.count)
                        .tag(SidebarItem.running)
                }
                if model.messaging.isAnyChannelOn || !model.messaging.log.isEmpty {
                    Label("Messages", systemImage: "message")
                        .tag(SidebarItem.messages)
                }
            }

            Section(isExpanded: expanded("loops")) {
                ForEach(model.loops.filter { $0.projectId == nil }) { loop in
                    LoopRow(loop: loop).tag(SidebarItem.loop(loop.id))
                }
            } header: {
                SectionHeader("Loops") {
                    Menu {
                        Button("New Loop from Description…") { model.showLoopWizard = true }
                        Button(LoopTemplates.blank.title) { model.createLoop(from: LoopTemplates.blank) }
                        Button("Open Loops Folder") { NSWorkspace.shared.open(model.store.loopsDir) }
                    } label: {
                        Label("New loop", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            Section(isExpanded: expanded("research")) {
                ThreadList(threads: model.threads(in: nil), key: "research")
            } header: {
                SectionHeader("Research") {
                    Button { model.newThread(projectId: nil) } label: { Label("New research thread", systemImage: "plus") }
                }
            }

            ForEach(model.projects) { project in
                Section(isExpanded: expanded(project.id.uuidString)) {
                    Label("Memory", systemImage: "brain")
                        .tag(SidebarItem.memory(project.id))
                    // Loops kept in this project's .automate/loops folder.
                    ForEach(model.loops.filter { $0.projectId == project.id }) { loop in
                        LoopRow(loop: loop).tag(SidebarItem.loop(loop.id))
                    }
                    ThreadList(threads: model.threads(in: project.id), key: project.id.uuidString)
                } header: {
                    SectionHeader(project.name) {
                        Button { model.newThread(projectId: project.id) } label: { Label("New thread", systemImage: "plus") }
                    }
                    .contextMenu {
                        Button("New Thread") { model.newThread(projectId: project.id) }
                        Button("New Loop in Project…") {
                            model.wizardPrefill = ("", project.id)
                            model.showLoopWizard = true
                        }
                        Button("Edit Memory") { model.selection = .memory(project.id) }
                        Button("Project Settings…") { model.editingProject = project }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                        Divider()
                        Button("Remove from Automate…", role: .destructive) { model.confirmRemoveProject = project }
                    }
                }
            }

            let archived = model.threads.filter(\.archived)
            if !archived.isEmpty {
                Section(isExpanded: $showArchived) {
                    ForEach(archived) { thread in
                        ThreadRow(thread: thread).tag(SidebarItem.thread(thread.id))
                    }
                } header: {
                    Text("Archived (\(archived.count))")
                }
            }
    }
}

/// How much of the Claude subscription's usage limits are used, from the latest reply.
struct UsageMeter: View {
    let windows: [UsageWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(windows) { w in
                HStack(spacing: 6) {
                    Text(w.label).font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    ProgressView(value: min(max(w.utilization, 0), 1))
                        .tint(w.utilization > 0.9 ? .red : w.utilization > 0.75 ? .orange : .accentColor)
                    Text("\(Int((w.utilization * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .help(w.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
        }
    }
}

struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 6) {
            if model.runningThreadIds.contains(thread.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: thread.pinned ? "pin.fill" : "bubble.left")
                    .foregroundStyle(.secondary)
            }
            Text(thread.title).lineLimit(1)
                .fontWeight(model.unreadThreadIds.contains(thread.id) ? .semibold : .regular)
            if model.unreadThreadIds.contains(thread.id) {
                Spacer(minLength: 0)
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("New reply")
            }
            if model.messaging.canReceive, model.remoteThreadId == thread.id || thread.isOnPhone {
                let current = model.remoteThreadId == thread.id
                Spacer(minLength: 0)
                Image(systemName: "iphone")
                    .font(.caption)
                    .foregroundStyle(current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .help(current ? "Texts from your phone go to this thread"
                          : "In use from your phone: swipe-reply to its texts to continue it")
            }
        }
        .contextMenu {
            if model.unreadThreadIds.contains(thread.id) {
                Button("Mark as Read") { model.setUnread(thread.id, false) }
            } else {
                Button("Mark as Unread") { model.setUnread(thread.id, true) }
            }
            Button(thread.pinned ? "Unpin" : "Pin") { model.updateThread(thread.id) { $0.pinned.toggle() } }
            Button(thread.archived ? "Unarchive" : "Archive") { model.updateThread(thread.id) { $0.archived.toggle() } }
            if model.messaging.canReceive, model.remoteThreadId != thread.id {
                Button("Use for Texts from Phone") { model.remoteThreadId = thread.id }
            }
            if model.remoteThreadId == thread.id || thread.isOnPhone {
                Button("Stop Continuing on Phone") { model.stopContinuingOnPhone(thread.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteThread(thread.id) }
        }
    }
}

struct LoopRow: View {
    @Environment(AppModel.self) private var model
    let loop: LoopDefinition

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(loop.name).lineLimit(1)
                Text(loop.enabled ? loop.triggerSummary : "off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isRunning(loopId: loop.id) { ProgressView().controlSize(.small) }
        }
        .opacity(loop.enabled ? 1 : 0.55)
    }

    private var dotColor: Color {
        if !loop.warnings.isEmpty { return .orange }
        guard loop.enabled else { return .gray }
        switch model.runs(for: loop.id).first?.status {
        case .failed: return .red
        case .needsApproval: return .blue
        default: return .green
        }
    }
}

/// A section's threads: the 8 most recent (plus pinned and the selected one), and "Show N more".
struct ThreadList: View {
    @Environment(AppModel.self) private var model
    let threads: [ChatThread]
    let key: String

    var body: some View {
        let showAll = model.expandedThreadLists.contains(key)
        let selectedId: UUID? = { if case let .thread(id)? = model.selection { return id }; return nil }()
        let shown = showAll ? threads : threads.enumerated()
            .filter { $0.offset < 8 || $0.element.pinned || $0.element.id == selectedId }.map(\.element)
        ForEach(shown) { thread in
            ThreadRow(thread: thread).tag(SidebarItem.thread(thread.id))
        }
        if threads.count > shown.count || (showAll && threads.count > 8) {
            Button(showAll ? "Show fewer" : "Show \(threads.count - shown.count) more") {
                if showAll { model.expandedThreadLists.remove(key) } else { model.expandedThreadLists.insert(key) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
