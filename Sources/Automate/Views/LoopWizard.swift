import SwiftUI
import AutomateCore

/// Describe a job in plain English; Claude drafts the loop file; you review, tweak and save it (switched off).
struct LoopWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var job = ""
    @State private var projectId: UUID?
    /// Save the loop in the project's .automate/loops (rather than Automate's own folder).
    @State private var keepInProject = true
    @State private var draft = ""
    @State private var writing = false
    @State private var error: String?
    @State private var session: ClaudeSession?
    @State private var suggestions: [String] = []

    private static let examples = [
        "Every weekday at 7am, check Hacker News and r/MachineLearning for posts about Claude or agents and give me the top 5.",
        "When my Mac wakes up, check my Gmail for interview invites and draft replies for me to approve.",
        "Every 2 hours, run the test suite in this repo; if anything fails, find the cause and propose a fix.",
        "Every Sunday evening, summarize what I worked on this week from git logs across my projects.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("New Loop from Description", systemImage: "wand.and.stars").font(.title3.weight(.semibold))
                Spacer()
            }
            if draft.isEmpty && !suggestions.isEmpty {
                suggestionsStep
            } else if draft.isEmpty {
                describeStep
            } else {
                reviewStep
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") {
                    session?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if writing {
                    ProgressView().controlSize(.small)
                    Text("Claude is thinking…").foregroundStyle(.secondary)
                } else if draft.isEmpty && !suggestions.isEmpty {
                    Button("Back") { suggestions = [] }
                } else if draft.isEmpty {
                    Button("Suggest from My Work") { suggest() }
                        .help("Claude looks at your recent Claude Code sessions and suggests loops for things you keep doing")
                        .disabled(model.claude == nil)
                    Button(Self.looksLikeLoopFile(job) ? "Review Loop" : "Write Loop") {
                        // A pasted loop file (e.g. shared by a friend) goes straight to review, no Claude needed.
                        if Self.looksLikeLoopFile(job) { draft = LoopWriter.extract(job) } else { write() }
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(job.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || model.claude == nil)
                } else {
                    Button("Start Over") { draft = "" }
                    Button("Create Loop") { create() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear {
            if let p = model.wizardPrefill {
                job = p.job
                projectId = p.projectId
            }
        }
    }

    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should run on its own? Say when, what to check, and what it may do without asking. (Or paste a loop file someone shared.)")
                .foregroundStyle(.secondary)
            TextEditor(text: $job)
                .font(.body)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .frame(minHeight: 140)
                .disabled(writing)
            if !model.projects.isEmpty {
                Picker("Works in", selection: $projectId) {
                    Text("Its own notes folder").tag(UUID?.none)
                    ForEach(model.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                .frame(maxWidth: 360)
                if let p = projectId.flatMap({ id in model.projects.first { $0.id == id } }) {
                    Toggle("Keep it in \(p.name)/.automate (the loop file and its notes)", isOn: $keepInProject)
                }
            }
            Text("Examples").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.examples, id: \.self) { ex in
                Button { job = ex } label: {
                    Text(ex).font(.callout).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    static func looksLikeLoopFile(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("---") && t.dropFirst(3).contains("\n---")
    }

    private var suggestionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Based on your recent Claude Code sessions. Pick one to review and edit.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, text in
                        let loop = LoopDefinition.parse(text: text, fileURL: URL(fileURLWithPath: "/tmp/s.md"))
                        Button { draft = text } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(loop.name).font(.headline)
                                Text("\(loop.triggerSummary) · \(loop.autonomy.rawValue) mode").font(.caption).foregroundStyle(.secondary)
                                Text(loop.instructions).lineLimit(3).font(.callout).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func suggest() {
        guard let location = model.claude else { return }
        error = nil
        writing = true
        let skip = [model.store.root.path, "/private/tmp", "/tmp"]
        let existing = model.loops.map(\.name)
        let cwd = model.store.scratchDir
        Task { @MainActor in
            let recent = await Task.detached { SessionImport.recent(limit: 50, skipping: skip) }.value
            guard !recent.isEmpty else {
                writing = false
                error = "No Claude Code sessions found to learn from yet."
                return
            }
            let home = NSHomeDirectory()
            let req = LoopWriter.suggestionsRequest(
                sessions: recent.map { ($0.title, $0.cwd.replacingOccurrences(of: home, with: "~"), $0.modified) },
                existing: existing, cwd: cwd)
            do {
                let s = try ClaudeSession.start(req, location: location, timeout: 300)
                session = s
                var items: [TranscriptItem] = []
                var outcome = TranscriptReducer.Outcome()
                for await e in s.events { TranscriptReducer.apply(e, to: &items, outcome: &outcome) }
                writing = false
                session = nil
                if s.wasCancelled { return }
                let found = LoopWriter.splitSuggestions(outcome.finalText ?? "")
                if found.isEmpty { error = "Claude didn't suggest anything: \(outcome.finalText ?? "no reply")" }
                suggestions = found
            } catch {
                writing = false
                self.error = "Couldn't start claude: \(error.localizedDescription)"
            }
        }
    }

    private var reviewStep: some View {
        let parsed = LoopDefinition.parse(text: draft, fileURL: URL(fileURLWithPath: "/tmp/preview.md"))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(parsed.name).fontWeight(.semibold)
                Text("· \(parsed.triggerSummary) · \(parsed.autonomy.rawValue) mode")
                    .foregroundStyle(.secondary)
            }
            ForEach(parsed.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange)
            }
            if !parsed.riskDescription.isEmpty {
                Label("This loop uses \(parsed.riskDescription.joined(separator: " and ")). Only keep that if you trust it.",
                      systemImage: "exclamationmark.shield")
                    .foregroundStyle(Color.orange)
            }
            Text("Review and edit it. It's saved switched off; turn it on when it looks right.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        }
    }

    private func write() {
        guard let location = model.claude else { return }
        error = nil
        writing = true
        let project = projectId.flatMap { id in model.projects.first { $0.id == id } }
        let req = LoopWriter.request(description: job, cwd: model.store.scratchDir, projectPath: project?.path)
        do {
            let s = try ClaudeSession.start(req, location: location, timeout: 300)
            session = s
            Task { @MainActor in
                var items: [TranscriptItem] = []
                var outcome = TranscriptReducer.Outcome()
                for await e in s.events { TranscriptReducer.apply(e, to: &items, outcome: &outcome) }
                writing = false
                session = nil
                if s.wasCancelled { return }
                if outcome.isError || (outcome.finalText ?? "").isEmpty {
                    error = "Couldn't write the loop: \(outcome.finalText ?? "no reply")"
                } else {
                    draft = LoopWriter.extract(outcome.finalText ?? "")
                }
            }
        } catch {
            writing = false
            self.error = "Couldn't start claude: \(error.localizedDescription)"
        }
    }

    private func create() {
        // Saved switched off whatever the draft says; you turn it on once it looks right.
        let contents = LoopFileEditor.updated(draft, key: "enabled", value: "false")
        let parsed = LoopDefinition.parse(text: contents, fileURL: URL(fileURLWithPath: "/tmp/preview.md"))
        let project = keepInProject ? projectId.flatMap { id in model.projects.first { $0.id == id } } : nil
        let url = model.createLoopFile(named: parsed.name, contents: contents, in: project)
        model.reloadLoops()
        model.selection = .loop(Store.loopId(for: url, in: project))
        dismiss()
    }
}
