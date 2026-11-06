import SwiftUI
import AutomateCore

/// ⌘K: jump to any thread, loop or project, or run a command, by typing a few letters.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: @MainActor () -> Void
    }

    var body: some View {
        let results = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a thread, loop or command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                            Button { selected = i; run(results) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: e.icon).frame(width: 20).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title).lineLimit(1)
                                        if !e.subtitle.isEmpty {
                                            Text(e.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(i == selected ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                        if results.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding()
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { proxy.scrollTo(selected) }
            }
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func run(_ results: [Entry]) {
        guard results.indices.contains(selected) else { return }
        let action = results[selected].action
        dismiss()
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    private var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = entries
        guard !q.isEmpty else { return all }
        return all.compactMap { e -> (Entry, Int)? in
            guard let score = Self.score(q, e.title) ?? Self.score(q, e.subtitle).map({ $0 - 50 }) else { return nil }
            return (e, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Higher is better; nil means no match. Prefix > word start > substring > letters in order.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = query.lowercased(), t = text.lowercased()
        guard !t.isEmpty else { return nil }
        if t.hasPrefix(q) { return 1000 - t.count }
        if t.contains(" " + q) { return 800 - t.count }
        if t.contains(q) { return 600 - t.count }
        var idx = t.startIndex
        for c in q where c != " " {
            guard let found = t[idx...].firstIndex(of: c) else { return nil }
            idx = t.index(after: found)
        }
        return 200 - t.count
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        out.append(Entry(id: "new-research", title: "New Research Thread", subtitle: "⌘N", icon: "plus.bubble") {
            model.newThread(projectId: nil)
        })
        for p in model.projects {
            out.append(Entry(id: "new-\(p.id)", title: "New Thread in \(p.name)", subtitle: p.path, icon: "plus.bubble") {
                model.newThread(projectId: p.id)
            })
        }
        out.append(Entry(id: "inbox", title: "Inbox", subtitle: model.inbox.isEmpty ? "" : "\(model.inbox.count) waiting", icon: "tray") {
            model.selection = .inbox
        })
        out.append(Entry(id: "activity", title: "Activity", subtitle: "Loop run history", icon: "clock.arrow.circlepath") {
            model.selection = .activity
        })
        out.append(Entry(id: "unread", title: "Unread", subtitle: model.unreadThreads.isEmpty ? "Threads with new replies" : "\(model.unreadThreads.count) unread", icon: "circle.badge") {
            model.selection = .unread
        })
        out.append(Entry(id: "messages", title: "Messages", subtitle: "Texts to and from your phone", icon: "message") {
            model.selection = .messages
        })
        out.append(Entry(id: "new-loop-ai", title: "New Loop from Description…", subtitle: "Describe a job; Claude writes the loop", icon: "wand.and.stars") {
            model.showLoopWizard = true
        })
        out.append(Entry(id: "import-session", title: "Continue a Claude Code Session…", subtitle: "From Terminal or your editor · ⇧⌘I", icon: "terminal") {
            model.showSessionImport = true
        })
        out.append(Entry(id: "add-project", title: "Add Project…", subtitle: "⇧⌘O", icon: "folder.badge.plus") {
            model.addProject()
        })
        out.append(Entry(id: "help", title: "Help", subtitle: "Shortcuts, text commands, loop files · ⌘?", icon: "questionmark.circle") {
            model.showHelp = true
        })
        out.append(Entry(id: "settings", title: "Settings", subtitle: "⌘,", icon: "gearshape") {
            openSettings()
        })
        for t in model.threads.filter({ !$0.archived }).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let place = model.project(for: t)?.name ?? "Research"
            out.append(Entry(id: "t-\(t.id)", title: t.title, subtitle: "\(place) · \(t.updatedAt.formatted(.relative(presentation: .named)))",
                             icon: "bubble.left") {
                model.selection = .thread(t.id)
            })
        }
        for l in model.loops {
            out.append(Entry(id: "l-\(l.id)", title: l.name, subtitle: "Loop · " + (l.enabled ? l.triggerSummary : "off"),
                             icon: "arrow.triangle.2.circlepath") {
                model.selection = .loop(l.id)
            })
            if !model.isRunning(loopId: l.id) {
                out.append(Entry(id: "run-\(l.id)", title: "Run \(l.name) Now", subtitle: "Loop", icon: "play.fill") {
                    model.runNow(l)
                })
            }
        }
        for p in model.projects {
            out.append(Entry(id: "m-\(p.id)", title: "\(p.name) Memory", subtitle: "Project memory", icon: "brain") {
                model.selection = .memory(p.id)
            })
        }
        return out
    }
}
