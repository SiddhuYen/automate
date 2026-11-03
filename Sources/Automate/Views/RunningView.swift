import SwiftUI
import AutomateCore

/// Everything Claude is working on right now, with a Stop button each.
struct RunningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let threads = model.threads.filter { model.runningThreadIds.contains($0.id) }
        let runs = model.runs.filter { $0.status == .running }
        Group {
            if threads.isEmpty && runs.isEmpty {
                ContentUnavailableView("Nothing running", systemImage: "bolt.slash",
                                       description: Text("Threads and loops show up here while Claude works on them."))
            } else {
                List {
                    if !threads.isEmpty {
                        Section("Threads") {
                            ForEach(threads) { t in
                                row(title: t.title,
                                    detail: (model.project(for: t)?.name ?? "Research") + (t.branch.map { " · \($0)" } ?? ""),
                                    activity: Self.lastActivity(t.items),
                                    open: { model.selection = .thread(t.id) },
                                    stop: { model.stopThread(t.id) })
                            }
                        }
                    }
                    if !runs.isEmpty {
                        Section("Loops") {
                            ForEach(runs) { r in
                                row(title: r.loopName,
                                    detail: "started by \(r.trigger.rawValue) · \(r.startedAt.formatted(.relative(presentation: .named)))",
                                    activity: Self.lastActivity(r.items),
                                    open: { model.selection = .run(r.id) },
                                    stop: { model.cancel(runId: r.id) })
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Running")
    }

    private func row(title: String, detail: String, activity: String, open: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Button(title, action: open).buttonStyle(.plain).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !activity.isEmpty { Text(activity).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button("Stop", action: stop)
        }
        .padding(.vertical, 3)
    }

    /// What it's doing right now: the latest tool call or a bit of text.
    static func lastActivity(_ items: [TranscriptItem]) -> String {
        guard let last = items.last(where: { $0.kind == .toolUse || $0.kind == .assistant }) else { return "" }
        if last.kind == .toolUse { return "\(last.toolName ?? "Tool"): \(last.text)" }
        return last.text.replacingOccurrences(of: "\n", with: " ")
    }
}
