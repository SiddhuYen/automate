import SwiftUI
import AutomateCore

struct TranscriptView: View {
    let items: [TranscriptItem]
    let isRunning: Bool

    var body: some View {
        let results = Dictionary(
            items.compactMap { item -> (String, TranscriptItem)? in
                guard item.kind == .toolResult, let id = item.toolUseId else { return nil }
                return (id, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let toolUseIds = Set(items.compactMap { $0.kind == .toolUse ? $0.toolUseId : nil })
        let timed = Self.timedIds(items, isRunning: isRunning)
        let newDay = Self.newDayIds(items)

        ScrollViewReader { proxy in
            ScrollView {
                // Not Lazy: a LazyVStack only measures rows as they scroll in, so the content height
                // (and the scroll bar) kept jumping. Replies cache their measured size, so this stays cheap.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        if newDay.contains(item.id) { DayDivider(date: item.date) }
                        // Tool results are shown inside their tool call row.
                        if item.kind == .toolResult, let id = item.toolUseId, toolUseIds.contains(id) {
                            EmptyView()
                        } else {
                            TranscriptRow(item: item, result: item.toolUseId.flatMap { results[$0] },
                                          showTime: timed.contains(item.id))
                        }
                    }
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: items.count) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

extension TranscriptView {
    /// Rows that get a time: everything you sent, and Claude's last text before your next message (one per turn).
    static func timedIds(_ items: [TranscriptItem], isRunning: Bool) -> Set<UUID> {
        var ids = Set<UUID>()
        var lastReply: UUID?
        for item in items {
            switch item.kind {
            case .user:
                if let r = lastReply { ids.insert(r) }
                lastReply = nil
                ids.insert(item.id)
            case .assistant:
                lastReply = item.id
            default: break
            }
        }
        // While Claude is still working its latest text may not be the reply yet.
        if let r = lastReply, !isRunning { ids.insert(r) }
        return ids
    }

    /// Rows that start a new calendar day, after the first (a divider goes above them).
    static func newDayIds(_ items: [TranscriptItem]) -> Set<UUID> {
        var ids = Set<UUID>()
        var day: Date?
        for item in items {
            let d = Calendar.current.startOfDay(for: item.date)
            if let day, d != day { ids.insert(item.id) }
            day = d
        }
        return ids
    }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        return cal.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }
}

/// A message's time, with the full date on hover.
struct MessageTime: View {
    let date: Date

    var body: some View {
        Text(Self.label(date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(date.formatted(date: .complete, time: .standard))
    }

    /// Time only for today; otherwise the date too, since the day divider may be far up.
    static func label(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

struct TranscriptRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let result: TranscriptItem?
    var showTime = false

    var body: some View {
        if item.kind == .assistant {
            VStack(alignment: .leading, spacing: 4) {
                // The text view supplies its own menu (Copy, Copy Message, Copy Code Block); add Send to Phone to it.
                MarkdownText(item.text, actions: model.messaging.isAnyChannelOn
                    ? [MarkdownAction(title: "Send to Phone") { model.messaging.send(RemoteText.plain(item.text)) }] : [])
                if showTime { MessageTime(date: item.date) }
            }
        } else if item.kind == .user {
            VStack(alignment: .trailing, spacing: 4) {
                content.contextMenu {
                    Button("Copy") { copyToPasteboard(item.text) }
                    if model.messaging.isAnyChannelOn {
                        Button("Send to Phone") { model.messaging.send(RemoteText.plain(item.text)) }
                    }
                }
                if showTime { MessageTime(date: item.date) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            MarkdownText(item.text)
        case .toolUse:
            ToolRow(item: item, result: result)
        case .toolResult:
            ToolOutput(text: item.text, isError: item.isError)
        case .info:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.red)
                .textSelection(.enabled)
        case .result:
            Label(item.text, systemImage: item.isError ? "xmark.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(item.isError ? Color.red : Color.secondary)
        }
    }
}

/// Claude's markdown (headings, lists, code with a Copy button, quotes, tables) as one selectable text, so a
/// whole reply can be selected and copied at once.
struct MarkdownText: View {
    let text: String
    var actions: [MarkdownAction] = []

    init(_ text: String, actions: [MarkdownAction] = []) {
        self.text = text
        self.actions = actions
    }

    var body: some View {
        SelectableMarkdown(text: text, actions: actions)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownText.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)
        case let .paragraph(text):
            Text(MarkdownText.inline(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .listItem(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(MarkdownText.inline(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .code(language, text):
            CodeBlockView(language: language, code: text)
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(MarkdownText.inline(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                            Text(MarkdownText.inline(h)).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownText.inline(cell)).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToPasteboard(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct ToolRow: View {
    let item: TranscriptItem
    let result: TranscriptItem?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: icon)
                    Text(item.toolName ?? "Tool").fontWeight(.medium)
                    Text(item.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let detail = item.detail {
                        let counts = DiffView.counts(detail)
                        HStack(spacing: 4) {
                            if counts.added > 0 { Text("+\(counts.added)").foregroundStyle(Color.green) }
                            if counts.removed > 0 { Text("−\(counts.removed)").foregroundStyle(Color.red) }
                        }
                        .font(.caption.monospacedDigit())
                    }
                    if result?.isError == true {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Color.red)
                    }
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let detail = item.detail { DiffView(diff: detail) }
                if let result, item.detail == nil || result.isError {
                    ToolOutput(text: result.text, isError: result.isError)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch item.toolName ?? "" {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebSearch": return "globe"
        case "WebFetch": return "link"
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "checklist"
        case "Notes changed": return "note.text"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct ToolOutput: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text.isEmpty ? "(no output)" : text)
            .font(.caption.monospaced())
            .foregroundStyle(isError ? Color.red : Color.primary)
            .textSelection(.enabled)
            .lineLimit(60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// An edit as removed (red) and added (green) lines.
struct DiffView: View {
    let diff: String

    static func counts(_ diff: String) -> (added: Int, removed: Int) {
        var a = 0, r = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+ ") || line == "+" { a += 1 } else if line.hasPrefix("- ") || line == "-" { r += 1 }
        }
        return (a, r)
    }

    @State private var showAll = false

    var body: some View {
        let lines = diff.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(showAll ? 2000 : 30).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(line.hasPrefix("+") ? Color.green.opacity(0.14)
                                : line.hasPrefix("-") ? Color.red.opacity(0.14) : Color.clear)
            }
            if lines.count > 30 && !showAll {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(6)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
