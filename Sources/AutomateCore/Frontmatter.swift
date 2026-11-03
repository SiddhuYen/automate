import Foundation

/// Minimal YAML-frontmatter reader: `key: value`, `key: [a, b]`, block lists (`- a`), quotes, `#` comments.
public enum Frontmatter {
    public enum Value: Equatable, Sendable {
        case string(String)
        case list([String])

        public var string: String? {
            switch self {
            case .string(let s): return s
            case .list(let l): return l.joined(separator: ", ")
            }
        }

        public var list: [String] {
            switch self {
            case .string(let s):
                return s.isEmpty ? [] : s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case .list(let l): return l
            }
        }

        public var bool: Bool? {
            guard case .string(let s) = self else { return nil }
            switch s.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        }
    }

    /// Returns the metadata and the body (everything after the closing `---`).
    public static func parse(_ text: String) -> (meta: [String: Value], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], normalized)
        }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], normalized)
        }
        let header = Array(lines[..<end])
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var meta: [String: Value] = [:]
        var currentListKey: String?
        var currentList: [String] = []

        func flushList() {
            if let k = currentListKey { meta[k] = .list(currentList) }
            currentListKey = nil
            currentList = []
        }

        for raw in header {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("- "), currentListKey != nil {
                currentList.append(clean(String(line.dropFirst(2))))
                continue
            }
            flushList()

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Shell commands are taken as written: only a fully quoted value is unquoted, and only a comment set off by
            // two or more spaces is dropped (so `[ -f x ]`, `"$HOME/bin/x" --json` and `jq '" #"'` survive).
            if Self.rawKeys.contains(key) {
                if let r = rawValue.range(of: "\\s{2,}#.*$", options: .regularExpression) {
                    rawValue = rawValue[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                }
                var v = rawValue
                if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q, v.dropFirst().dropLast().firstIndex(of: q) == nil {
                    v = String(v.dropFirst().dropLast())
                }
                if !v.isEmpty { meta[key] = .string(v) }
                continue
            }
            // Strip a trailing " # comment" unless the value is quoted.
            if let first = rawValue.first, first != "\"", first != "'", let r = rawValue.range(of: " #") {
                rawValue = rawValue[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            } else if let first = rawValue.first, first == "\"" || first == "'",
                      let close = rawValue.dropFirst().firstIndex(of: first) {
                rawValue = String(rawValue[...close])
            }

            if rawValue.isEmpty {
                currentListKey = key // a block list may follow
                continue
            }
            if rawValue.hasPrefix("[") && rawValue.hasSuffix("]") {
                let inner = rawValue.dropFirst().dropLast()
                let items = inner.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
                meta[key] = .list(items)
            } else {
                meta[key] = .string(clean(rawValue))
            }
        }
        flushList()
        return (meta, body)
    }

    /// Keys whose value is a shell command, kept exactly as written.
    static let rawKeys: Set<String> = ["check"]

    /// Strip surrounding quotes, or a trailing ` # comment` on unquoted values.
    static func clean(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            return String(v.dropFirst().dropLast())
        }
        if let r = v.range(of: " #") { v = String(v[..<r.lowerBound]) }
        return v.trimmingCharacters(in: .whitespaces)
    }
}
