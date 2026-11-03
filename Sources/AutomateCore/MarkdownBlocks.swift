import Foundation

/// Splits Claude's markdown into blocks the app renders natively: headings, paragraphs, lists, code, quotes,
/// tables and rules. Inline styling (bold, links, `code`) is left in the text for AttributedString to handle.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for bullets, "3." for numbered items, "☐"/"☑" for task items.
    case listItem(marker: String, indent: Int, text: String)
    case code(language: String, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (``` or ~~~). An unclosed fence (still streaming) runs to the end.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Horizontal rule
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let c = trimmed.first, "-*_".contains(c) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a row of pipes followed by a |---|---| separator.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quoted.append(String(q))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // List item
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                i += 1
                continue
            }

            // A line indented under a list item continues it.
            if paragraph.isEmpty, line.hasPrefix("  "), case let .listItem(marker, indent, text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, indent: indent, text: text + "\n" + trimmed)
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(leading.count)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            var text = String(body.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return .listItem(marker: marker, indent: indent, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", indent: indent, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
