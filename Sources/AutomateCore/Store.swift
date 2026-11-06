import Foundation

/// Everything Automate keeps lives in ~/Library/Application Support/Automate:
///
///   projects.json        code folders you've added
///   memory/<name>.md     each project's memory — you and Claude both edit it
///   threads/<id>.json    chat threads (ADE + research)
///   loops/<name>.md      loop definitions — edit these in any editor
///   loops-new/           loops a thread wrote for you, waiting to be imported
///   loop-data/<name>/    each loop's private notes, kept between runs
///   runs/<id>.json       loop run history and transcripts
///   loop-state.json      when each loop last ran
///   scratch/             working folder for research threads
///   attachments/         files you attached to messages
///   dispatch/<id>/       tasks a coordinator thread is handing out, waiting to be started
///   trash/               deleted threads, kept 30 days
///
/// Loops can also live inside a project, so they travel with it:
///
///   <project>/.automate/loops/<name>.md      the loop (id "<project>/<name>")
///   <project>/.automate/loop-data/<name>/    its notes (git-ignored)
public final class Store: @unchecked Sendable {
    public let root: URL
    public var projectsFile: URL { root.appendingPathComponent("projects.json") }
    public var threadsDir: URL { root.appendingPathComponent("threads", isDirectory: true) }
    public var loopsDir: URL { root.appendingPathComponent("loops", isDirectory: true) }
    public var loopDataRoot: URL { root.appendingPathComponent("loop-data", isDirectory: true) }
    public var runsDir: URL { root.appendingPathComponent("runs", isDirectory: true) }
    public var stateFile: URL { root.appendingPathComponent("loop-state.json") }
    public var scratchDir: URL { root.appendingPathComponent("scratch", isDirectory: true) }
    public var memoryDir: URL { root.appendingPathComponent("memory", isDirectory: true) }
    /// Where threads put loops they write for you; Automate imports them into `loops/` after a safety check.
    public var incomingLoopsDir: URL { root.appendingPathComponent("loops-new", isDirectory: true) }
    /// Files you attach to a message (copied here so every thread can read them).
    public var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    /// Where a coordinator thread writes the tasks it hands out (one folder per thread).
    public func dispatchDir(for threadId: UUID) -> URL {
        root.appendingPathComponent("dispatch", isDirectory: true).appendingPathComponent(threadId.uuidString, isDirectory: true)
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let dir = ProcessInfo.processInfo.environment["AUTOMATE_DATA_DIR"], !dir.isEmpty {
            // For development: run a copy of Automate against a separate data folder.
            self.root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Automate", isDirectory: true)
            // The app used to be called Loom; carry its data over once.
            let legacy = base.appendingPathComponent("Loom", isDirectory: true)
            if !FileManager.default.fileExists(atPath: self.root.path), FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.moveItem(at: legacy, to: self.root)
            }
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in [self.root, threadsDir, loopsDir, loopDataRoot, runsDir, scratchDir, memoryDir, attachmentsDir, incomingLoopsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The loop's notes folder: inside its project for project loops, else `loop-data/<id>/`.
    public func loopDataDir(for loop: LoopDefinition) -> URL {
        guard let root = loop.projectRoot else { return loopDataDir(for: loop.id) }
        let dir = Store.projectAutomateDir(root).appendingPathComponent("loop-data", isDirectory: true)
            .appendingPathComponent(loop.fileStem, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func loopDataDir(for loopId: String) -> URL {
        let dir = loopDataRoot.appendingPathComponent(loopId, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Generic JSON

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Projects

    public func loadProjects() -> [Project] { read([Project].self, from: projectsFile) ?? [] }
    public func saveProjects(_ projects: [Project]) { write(projects, to: projectsFile) }

    // MARK: Project memory

    /// Keyed by the folder's path (not the project id), so removing and re-adding a folder keeps its memory.
    public func memoryFile(for project: Project) -> URL {
        memoryDir.appendingPathComponent(ProjectMemory.fileName(name: project.name, path: project.path))
    }

    public func loadMemory(for project: Project) -> String {
        (try? String(contentsOf: memoryFile(for: project), encoding: .utf8)) ?? ""
    }

    public func saveMemory(_ text: String, for project: Project) throws {
        try text.write(to: memoryFile(for: project), atomically: true, encoding: .utf8)
    }

    // MARK: Threads

    public func loadThreads() -> [ChatThread] {
        let files = (try? fm.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { read(ChatThread.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ thread: ChatThread) {
        write(thread, to: threadsDir.appendingPathComponent("\(thread.id.uuidString).json"))
    }

    public var trashDir: URL { root.appendingPathComponent("trash", isDirectory: true) }

    /// Moves the thread to `trash/` (restorable; emptied after 30 days by `emptyTrash`).
    public func delete(_ thread: ChatThread) {
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let name = "\(thread.id.uuidString).json"
        let dest = trashDir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        if (try? fm.moveItem(at: threadsDir.appendingPathComponent(name), to: dest)) != nil {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        }
    }

    public func restoreThread(id: UUID) -> ChatThread? {
        let name = "\(id.uuidString).json"
        let src = trashDir.appendingPathComponent(name)
        guard let thread = read(ChatThread.self, from: src) else { return nil }
        try? fm.moveItem(at: src, to: threadsDir.appendingPathComponent(name))
        return thread
    }

    public func emptyTrash(olderThan days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        for url in (try? fm.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if d < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Runs

    public func loadRuns(limit: Int = 300) -> [LoopRun] {
        let files = (try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        return sorted.prefix(limit).compactMap { read(LoopRun.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Delete finished runs older than `days` (anything still waiting for you is kept). Returns how many.
    @discardableResult
    public func pruneRuns(olderThan days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let files = (try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for url in files where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard modified < cutoff, let run = read(LoopRun.self, from: url),
                  run.status.isFinished, run.status != .needsApproval, run.startedAt < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    public func save(_ run: LoopRun) {
        write(run, to: runsDir.appendingPathComponent("\(run.id.uuidString).json"))
    }

    // MARK: Loops

    public static func projectAutomateDir(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".automate", isDirectory: true)
    }

    public static func projectLoopsDir(_ project: Project) -> URL {
        projectAutomateDir(project.url).appendingPathComponent("loops", isDirectory: true)
    }

    /// "<project-slug>/<file name>": unique across projects and Automate's own `loops/` (file names have no "/").
    public static func projectLoopId(project: Project, stem: String) -> String {
        "\(slug(project.name, fallback: "project"))/\(stem)"
    }

    /// Loops from Automate's `loops/` folder and from each project's `.automate/loops/`.
    public func loadLoops(projects: [Project] = []) -> [LoopDefinition] {
        var all = markdownFiles(in: loopsDir).compactMap { try? LoopDefinition.load(from: $0) }
        var ids = Set(all.map(\.id))
        for project in projects {
            for url in markdownFiles(in: Store.projectLoopsDir(project)) {
                guard var loop = try? LoopDefinition.load(from: url) else { continue }
                loop.id = Store.projectLoopId(project: project, stem: loop.fileStem)
                guard ids.insert(loop.id).inserted else { continue } // two projects with the same name
                loop.projectId = project.id
                loop.projectRoot = project.url
                all.append(loop)
            }
        }
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A fingerprint of the loops folders so the app can notice edits made in other editors.
    public func loopsFingerprint(projects: [Project] = []) -> String {
        let dirs = [loopsDir] + projects.map(Store.projectLoopsDir)
        return dirs.flatMap { dir in
            markdownFiles(in: dir, keys: [.contentModificationDateKey]).map { url -> String in
                let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                return "\(url.path)@\(d)"
            }
        }.sorted().joined(separator: "|")
    }

    private func markdownFiles(in dir: URL, keys: [URLResourceKey]? = nil) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "md" }
    }

    static func slug(_ name: String, fallback: String) -> String {
        let s = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? fallback : s
    }

    /// Writes a new loop file (never overwriting one) in Automate's `loops/`, or in `project`'s `.automate/loops/`.
    @discardableResult
    public func createLoop(named name: String, contents: String, in project: Project? = nil) -> URL {
        let dir: URL
        if let project {
            dir = Store.projectLoopsDir(project)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Loop files can be committed with the project; their notes are local state.
            let ignore = Store.projectAutomateDir(project.url).appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignore.path) {
                try? "loop-data/\n".write(to: ignore, atomically: true, encoding: .utf8)
            }
        } else {
            dir = loopsDir
        }
        let base = Store.slug(name, fallback: "loop")
        var url = dir.appendingPathComponent("\(base).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The id a loop file will get once loaded (see `loadLoops`).
    public static func loopId(for url: URL, in project: Project?) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return project.map { projectLoopId(project: $0, stem: stem) } ?? stem
    }

    // MARK: Loop state

    public struct LoopState: Codable, Sendable {
        public var lastRun: [String: Date] = [:]
        public var firstSeen: [String: Date] = [:]
        /// Fingerprint of each loop's `check:` output last time it ran Claude (optional: older files lack it).
        public var checkFingerprints: [String: String]?
        /// The risky settings (see LoopDefinition.riskSignature) you've OK'd for each loop.
        public var acceptedRisk: [String: String]?
        /// 2 once project loops' OKs include their acting settings (nil = older file, carried over on load).
        public var riskFormat: Int?
        public init() {}
    }

    public func loadState() -> LoopState { read(LoopState.self, from: stateFile) ?? LoopState() }
    public func saveState(_ s: LoopState) { write(s, to: stateFile) }
}
