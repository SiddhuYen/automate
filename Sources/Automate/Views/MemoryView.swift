import SwiftUI
import AutomateCore

/// A project's memory file. Claude may edit it during any thread, so this watches the file and reloads
/// when it changes — unless you have unsaved edits, in which case it asks.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    @State private var draft = ""
    @State private var savedText = ""
    @State private var diskDate: Date?
    @State private var changedOnDisk = false

    var body: some View {
        if let project = model.projects.first(where: { $0.id == projectId }) {
            let file = model.memoryFile(for: project)
            VStack(spacing: 0) {
                header(project, file: file)
                if changedOnDisk {
                    HStack {
                        Label("Claude changed this file since you started editing.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                        Spacer()
                        Button("Load Theirs") { load(file) }
                        Button("Keep Mine") { changedOnDisk = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(file.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revert") { draft = savedText }.disabled(draft == savedText)
                        Button("Save") { save(project, file: file) }
                            .keyboardShortcut("s")
                            .disabled(draft == savedText)
                    }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                        if draft.isEmpty {
                            Text("Nothing remembered yet. Write down anything every thread in \(project.name) should know: goals, conventions, decisions, what's in progress. Claude adds to it as it works.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(12)
            }
            .onAppear { load(file) }
            .task(id: file) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    checkDisk(file)
                }
            }
        } else {
            ContentUnavailableView("Project not found", systemImage: "questionmark.folder")
        }
    }

    private func header(_ project: Project, file: URL) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(project.name) memory").font(.title3.weight(.semibold))
                Text("Every thread in this project reads this, and Claude keeps it up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.newThread(projectId: project.id) } label: { Label("New Thread", systemImage: "plus") }
            Menu {
                Button("Open in Editor") {
                    ensureExists(project, file: file)
                    NSWorkspace.shared.open(file)
                }
                Button("Show in Finder") {
                    ensureExists(project, file: file)
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(16)
    }

    private func modificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func load(_ file: URL) {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        draft = text
        savedText = text
        diskDate = modificationDate(file)
        changedOnDisk = false
    }

    private func checkDisk(_ file: URL) {
        let date = modificationDate(file)
        guard date != diskDate else { return }
        if draft == savedText {
            load(file)
        } else {
            diskDate = date
            changedOnDisk = true
        }
    }

    private func save(_ project: Project, file: URL) {
        model.saveMemory(draft, for: project)
        savedText = draft
        diskDate = modificationDate(file)
        changedOnDisk = false
    }

    /// External editors need a file to open.
    private func ensureExists(_ project: Project, file: URL) {
        if !FileManager.default.fileExists(atPath: file.path) { model.saveMemory("", for: project) }
    }
}
