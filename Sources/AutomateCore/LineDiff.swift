import Foundation

/// A small line diff (LCS) for showing what a loop changed in its notes. Lines come back as "- old" / "+ new",
/// with unchanged runs trimmed to a little context.
public enum LineDiff {
    public static func diff(_ old: String, _ new: String, context: Int = 1, maxLines: Int = 1500) -> [String] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        // Too big for the O(n·m) table: just say how much changed.
        guard a.count <= maxLines, b.count <= maxLines else {
            return ["@@ \(a.count) → \(b.count) lines (too long to show)"]
        }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { ops.append((" ", a[i])); i += 1; j += 1 }
            else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(("-", a[i])); i += 1 }
            else { ops.append(("+", b[j])); j += 1 }
        }
        // Keep changes plus `context` unchanged lines around them.
        var keep = Array(repeating: false, count: ops.count)
        for (k, op) in ops.enumerated() where op.0 != " " {
            for c in max(0, k - context)...min(ops.count - 1, k + context) { keep[c] = true }
        }
        var out: [String] = []
        var skipped = false
        for (k, op) in ops.enumerated() {
            if keep[k] {
                if skipped, !out.isEmpty { out.append("@@") }
                skipped = false
                out.append(op.0 == " " ? "  " + op.1 : "\(op.0) " + op.1)
            } else {
                skipped = true
            }
        }
        return out
    }

    /// What changed between two snapshots of a folder (relative path → text).
    public static func folderChanges(before: [String: String], after: [String: String]) -> [(path: String, added: Int, removed: Int, diff: [String])] {
        var out: [(String, Int, Int, [String])] = []
        for path in Set(before.keys).union(after.keys).sorted() {
            let old = before[path] ?? "", new = after[path] ?? ""
            guard old != new else { continue }
            let d = diff(old, new)
            out.append((path, d.filter { $0.hasPrefix("+ ") }.count, d.filter { $0.hasPrefix("- ") }.count, d))
        }
        return out
    }

    /// Text files (≤ 200 KB) in a folder and one level down, by relative path.
    public static func snapshot(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e {
            if e.level >= 2 { e.skipDescendants() }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= 200_000,
                  let data = try? Data(contentsOf: url), !data.prefix(4096).contains(0) else { continue }
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            out[parts.dropFirst(base.count).joined(separator: "/")] = String(decoding: data, as: UTF8.self)
            if out.count >= 200 { break }
        }
        return out
    }
}
