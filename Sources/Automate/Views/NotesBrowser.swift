import SwiftUI
import AutomateCore

/// The files a loop keeps between runs (pipeline.md, seen.json, history.csv…), readable without leaving Automate.
struct NotesBrowser: View {
    let folder: URL
    /// "Ask Claude about these notes".
    var ask: (() -> Void)?
    @State private var files: [URL] = []
    @State private var selected: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if files.isEmpty {
                VStack(spacing: 6) {
                    Text("No notes yet.").foregroundStyle(.secondary)
                    Text("The loop writes files here as it runs, and reads them next time.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                Picker("File", selection: $selected) {
                    ForEach(files, id: \.self) { f in
                        Text(relativeName(f)).tag(URL?.some(f))
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                if let selected {
                    HStack {
                        if let date = try? selected.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                            Text("Updated \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ask {
                            Button("Ask Claude…", action: ask)
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Start a thread in this notes folder to ask about or change these files")
                        }
                        Button("Open") { NSWorkspace.shared.open(selected) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    Divider().padding(.top, 4)
                    ScrollView([.vertical]) {
                        FilePreview(url: selected)
                            .padding(12)
                    }
                }
            }
        }
        .task(id: folder) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// "seen.json", or "drafts/acme.md" for files in subfolders.
    private func relativeName(_ file: URL) -> String {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard parts.starts(with: base) else { return file.lastPathComponent }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    private func reload() {
        let fm = FileManager.default
        var found: [URL] = []
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                 options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                if e.level >= 2 { e.skipDescendants() } // top level and one folder down
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(url) }
                if found.count >= 300 { break }
            }
        }
        found.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        if found != files { files = found }
        if selected == nil || !found.contains(selected!) { selected = found.first }
    }
}

struct FilePreview: View {
    let url: URL

    var body: some View {
        let ext = url.pathExtension.lowercased()
        let text = Self.load(url)
        Group {
            if let text {
                switch ext {
                case "md", "markdown":
                    MarkdownText(text)
                case "csv", "tsv":
                    MarkdownBlockView(block: Self.table(text, separator: ext == "tsv" ? "\t" : ","))
                case "json":
                    Text(Self.prettyJSON(text)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                default:
                    Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                Text("Can't preview this file.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func load(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let clipped = data.prefix(300_000)
        // Binary files (images, archives) aren't previewed.
        if clipped.prefix(4096).contains(0) { return nil }
        let s = String(decoding: clipped, as: UTF8.self)
        return data.count > clipped.count ? s + "\n… (file continues)" : s
    }

    static func prettyJSON(_ s: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let out = String(data: data, encoding: .utf8) else { return s }
        return out
    }

    /// Simple CSV (quoted fields with commas are kept together). Shows the last 300 rows.
    static func table(_ s: String, separator: Character) -> MarkdownBlock {
        var rows = s.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> [String] in
                var cells: [String] = [], cur = "", quoted = false
                for c in line {
                    if c == "\"" { quoted.toggle() }
                    else if c == separator && !quoted { cells.append(cur); cur = "" }
                    else { cur.append(c) }
                }
                cells.append(cur)
                return cells.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        guard !rows.isEmpty else { return .paragraph("(empty)") }
        let header = rows.removeFirst()
        let body = rows.suffix(300).map { r in Array((r + Array(repeating: "", count: max(0, header.count - r.count))).prefix(header.count)) }
        return .table(header: header, rows: Array(body))
    }
}
