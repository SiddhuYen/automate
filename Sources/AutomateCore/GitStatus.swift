import Foundation

/// `git status` for a folder: the branch and what's changed, for the thread header.
public struct GitStatus: Equatable, Sendable {
    public var branch: String
    public var ahead: Int
    public var behind: Int
    /// "M src/app.swift", "?? notes.md", ...
    public var changes: [String]

    /// Parses `git status --porcelain=v1 -b`.
    public static func parse(_ output: String) -> GitStatus? {
        var lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let head = lines.first, head.hasPrefix("## ") else { return nil }
        lines.removeFirst()
        var info = String(head.dropFirst(3))
        var ahead = 0, behind = 0
        if let r = info.range(of: " [") {
            let bracket = info[r.upperBound...].dropLast()
            for part in bracket.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("ahead ") { ahead = Int(p.dropFirst(6)) ?? 0 }
                if p.hasPrefix("behind ") { behind = Int(p.dropFirst(7)) ?? 0 }
            }
            info = String(info[..<r.lowerBound])
        }
        var branch = info.components(separatedBy: "...").first ?? info
        if branch.hasPrefix("No commits yet on ") { branch = String(branch.dropFirst(18)) }
        if branch.hasPrefix("HEAD (no branch)") { branch = "detached HEAD" }
        let changes = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        return GitStatus(branch: branch, ahead: ahead, behind: behind, changes: changes)
    }

    /// Runs git in `folder` (nil if it isn't a repo or git is missing). Call off the main thread.
    public static func read(_ folder: URL) -> GitStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Read-only and safe to run just because a thread is on screen: no index lock (which could make Claude's own
        // git commands fail) and no fsmonitor hook from the repo's config.
        p.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", folder.path,
                       "status", "--porcelain=v1", "-b", "--untracked-files=normal"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
