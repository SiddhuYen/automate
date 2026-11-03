import Foundation

/// One markdown file per project that you and Claude share. Every thread (and any loop whose `cwd` is the
/// project folder) sees its current contents and may edit it.
public enum ProjectMemory {
    /// "<folder-name>-<hash of path>.md": readable in Finder, and unique even if two folders share a name.
    public static func fileName(name: String, path: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let suffix = String(String(hash, radix: 16).suffix(8))
        return "\(slug.isEmpty ? "project" : slug)-\(suffix).md"
    }

    public static func systemPrompt(file: URL, contents: String) -> String {
        let body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        This project has a memory file shared by every Automate thread and loop that works in it: \(file.path)
        The user reads and edits it too. Its current contents:
        <project-memory>
        \(body.isEmpty ? "(empty)" : body)
        </project-memory>

        Keep it useful for the next session. When you learn something durable it would need (decisions and why,
        conventions, gotchas, the user's preferences, where unfinished work stands), edit that file. Keep it short
        and organized in markdown: update or remove stale entries instead of piling on new ones. Don't record what
        the code or git history already says. Never delete or rewrite what the user wrote without being asked.
        """
    }

    /// Give a request the project's memory: its contents in the system prompt, and access to the file.
    public static func attach(to request: inout ClaudeRequest, file: URL, contents: String) {
        let memory = systemPrompt(file: file, contents: contents)
        if let existing = request.appendSystemPrompt, !existing.isEmpty {
            request.appendSystemPrompt = existing + "\n\n" + memory
        } else {
            request.appendSystemPrompt = memory
        }
        // Otherwise a resumed session keeps the memory as it was at its first message.
        request.freshSystemPrompt = true
        let dir = file.deletingLastPathComponent()
        if !request.addDirs.contains(where: { $0.standardizedFileURL == dir.standardizedFileURL }) {
            request.addDirs.append(dir)
        }
    }
}
