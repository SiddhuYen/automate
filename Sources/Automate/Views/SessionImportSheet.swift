import SwiftUI
import AutomateCore

/// Pick a Claude Code session from Terminal or your IDE and keep going with it in Automate (or from your phone).
struct SessionImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionImport.Summary]?
    @State private var query = ""
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue a Claude Code Session").font(.title3.weight(.semibold))
            Text("Sessions from Terminal or your editor. Opening one here resumes the same conversation, so Claude remembers everything. Close it in the other app first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder)
            Group {
                if let sessions {
                    let shown = sessions.filter {
                        query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
                    }
                    if shown.isEmpty {
                        Text("No sessions found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(shown, selection: $selected) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).lineLimit(1)
                                HStack {
                                    Text(s.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(s.modified.formatted(.relative(presentation: .named)))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(s.id)
                        }
                    }
                } else {
                    ProgressView("Looking for sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue in Automate") {
                    if let s = sessions?.first(where: { $0.id == selected }) {
                        model.importSession(s)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(16)
        .frame(width: 640, height: 480)
        .task {
            // Automate's own sessions are already threads here (and the old Loom folder is from before the rename).
            let legacy = model.store.root.deletingLastPathComponent().appendingPathComponent("Loom").path
            let skip = [model.store.root.path, legacy, "/private/tmp/automate", "/tmp/automate"]
            let known = Set(model.threads.compactMap(\.sessionId) + model.runs.compactMap(\.sessionId))
            sessions = await Task.detached { SessionImport.recent(limit: 60, skipping: skip) }.value
                .filter { !known.contains($0.id) }
        }
    }
}
