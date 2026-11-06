import AppKit
import SwiftUI
import AutomateCore

/// An extra item for a message's right-click menu.
struct MarkdownAction {
    let title: String
    let run: () -> Void
}

/// Claude's markdown in one read-only NSTextView, so a drag (or ⌘A) selects across paragraphs, lists, code and
/// tables at once. SwiftUI can only select inside a single Text, which made copying a reply one block at a time.
struct SelectableMarkdown: NSViewRepresentable {
    let text: String
    var actions: [MarkdownAction] = []

    func makeNSView(context: Context) -> MarkdownTextView { MarkdownTextView() }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.actions = actions
        view.setMarkdown(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        view.fittingSize(width: proposal.width)
    }
}

extension NSAttributedString.Key {
    /// Shown but left out when copying (code-block language labels, rules).
    static let mdNoCopy = NSAttributedString.Key("automate.noCopy")
    /// What this character becomes when copied as plain text ("\t" between table cells, "\n\n" after a block).
    static let mdPlain = NSAttributedString.Key("automate.plain")
    /// Marks a code block's characters; the value (a CodeRef) holds its source.
    static let mdCode = NSAttributedString.Key("automate.code")
}

final class CodeRef: NSObject {
    let code: String
    init(_ code: String) { self.code = code }
}

final class MarkdownTextView: NSTextView {
    private(set) var markdown: String?
    var actions: [MarkdownAction] = []
    private var copyButtons: [NSButton] = []
    private var buttonCode: [ObjectIdentifier: String] = [:]
    /// Measured sizes by proposed width (-1 = no width); SwiftUI asks again on every layout pass.
    private var sizeCache: [CGFloat: CGSize] = [:]

    init() {
        // An explicit NSLayoutManager keeps this on TextKit 1, which NSTextBlock/NSTextTable need.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = true
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setMarkdown(_ text: String) {
        guard text != markdown else { return }
        markdown = text
        sizeCache.removeAll()
        textStorage?.setAttributedString(MarkdownAttributed.make(text))
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func fittingSize(width: CGFloat?) -> CGSize {
        guard let layoutManager, let textContainer else { return .zero }
        let w = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let cached = sizeCache[w ?? -1] { return cached }
        textContainer.containerSize = NSSize(width: w ?? 100_000, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let size = CGSize(width: w ?? ceil(used.width), height: ceil(used.height))
        sizeCache[w ?? -1] = size
        // Measuring at another width moved the live layout; put it back so what's shown doesn't reflow.
        if bounds.width > 0, textContainer.containerSize.width != bounds.width {
            textContainer.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        return size
    }

    override func layout() {
        // sizeThatFits may have measured at another width; lay out at the real one.
        if let textContainer, textContainer.containerSize.width != bounds.width {
            textContainer.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        super.layout()
        placeCopyButtons()
    }

    // MARK: Code-block Copy buttons

    private func placeCopyButtons() {
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        layoutManager.ensureLayout(for: textContainer)
        var blocks: [(NSRange, CodeRef)] = []
        storage.enumerateAttribute(.mdCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let ref = value as? CodeRef { blocks.append((range, ref)) }
        }
        while copyButtons.count < blocks.count {
            let b = NSButton(title: "Copy", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(copyCodeBlock(_:)))
            b.isBordered = false
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.imagePosition = .imageLeading
            b.contentTintColor = .secondaryLabelColor
            addSubview(b)
            copyButtons.append(b)
        }
        buttonCode = [:]
        for (i, button) in copyButtons.enumerated() {
            guard i < blocks.count else { button.isHidden = true; continue }
            let (range, ref) = blocks[i]
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if let block = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first {
                rect = layoutManager.boundsRect(for: block, at: glyph, effectiveRange: nil)
            }
            button.sizeToFit()
            let size = button.frame.size
            button.frame = NSRect(x: rect.maxX - size.width - 8, y: rect.minY + 5, width: size.width, height: size.height)
            button.isHidden = false
            buttonCode[ObjectIdentifier(button)] = ref.code
        }
    }

    @objc private func copyCodeBlock(_ sender: NSButton) {
        guard let code = buttonCode[ObjectIdentifier(sender)] else { return }
        copyToPasteboard(code)
        sender.title = "Copied"
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sender] in
            sender?.title = "Copy"
            sender?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
    }

    // MARK: Copying

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let rich = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        rich.enumerateAttribute(.mdNoCopy, in: NSRange(location: 0, length: rich.length), options: .reverse) { value, r, _ in
            if value != nil { rich.deleteCharacters(in: r) }
        }
        // Colors are resolved for the current appearance (white text in dark mode), so leave them to the target app.
        let all = NSRange(location: 0, length: rich.length)
        rich.removeAttribute(.foregroundColor, range: all)
        rich.removeAttribute(.backgroundColor, range: all)
        if let rtf = rich.rtf(from: all, documentAttributes: [:]) { pb.setData(rtf, forType: .rtf) }
        pb.setString(plainText(in: range), forType: .string)
    }

    /// The selection as plain text: lists as "• item", tables tab-separated, a blank line between blocks.
    func plainText(in range: NSRange) -> String {
        guard let storage = textStorage else { return "" }
        let s = storage.string as NSString
        var out = ""
        storage.enumerateAttributes(in: range) { attrs, r, _ in
            if attrs[.mdNoCopy] != nil { return }
            if let p = attrs[.mdPlain] as? String {
                out += String(repeating: p, count: r.length)
            } else {
                out += s.substring(with: r)
            }
        }
        return out.trimmingCharacters(in: .newlines)
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var items: [NSMenuItem] = []
        if let storage = textStorage, storage.length > 0 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if index < storage.length, let ref = storage.attribute(.mdCode, at: index, effectiveRange: nil) as? CodeRef {
                items.append(ClosureMenuItem("Copy Code Block") { copyToPasteboard(ref.code) })
            }
        }
        if let markdown {
            items.append(ClosureMenuItem("Copy Message") { copyToPasteboard(markdown) })
        }
        items += actions.map { ClosureMenuItem($0.title, $0.run) }
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        if !items.isEmpty, menu.items.count > items.count { menu.insertItem(.separator(), at: items.count) }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Builds the attributed text for SelectableMarkdown from MarkdownBlock.parse.
enum MarkdownAttributed {
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    static let blockGap: CGFloat = 8
    static let listGap: CGFloat = 3
    static var codeBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var hairline: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.25) }

    static func make(_ markdown: String) -> NSAttributedString {
        let blocks = MarkdownBlock.parse(markdown)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let next = i + 1 < blocks.count ? blocks[i + 1] : nil
            append(block, first: i == 0, next: next, to: out)
        }
        // Drop the last block's terminator (and a trailing spacer) so there's no empty line at the bottom.
        while out.length > 0, (out.string as NSString).character(at: out.length - 1) == 10 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func append(_ block: MarkdownBlock, first: Bool, next: MarkdownBlock?, to out: NSMutableAttributedString) {
        let endPlain = "\n\n"
        switch block {
        case let .heading(level, text):
            let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : NSFont.systemFontSize
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = first ? 0 : (level <= 2 ? 4 : 2)
            appendParagraphs(inline(text, font: font), style: style, after: blockGap, plainEnd: endPlain, to: out)

        case let .paragraph(text):
            appendParagraphs(inline(text, font: bodyFont), style: NSMutableParagraphStyle(), after: blockGap,
                             plainEnd: endPlain, to: out)

        case let .listItem(marker, indent, text):
            let lead = CGFloat(indent) * 16
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = lead
            style.headIndent = lead + 22
            style.tabStops = [NSTextTab(textAlignment: .left, location: lead + 22)]
            let line = NSMutableAttributedString()
            let markerAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]
            line.append(NSAttributedString(string: marker, attributes: markerAttrs))
            // Plain copies get "  • item" instead of the tab.
            line.addAttribute(.mdPlain, value: String(repeating: "  ", count: indent) + String(marker.prefix(1)),
                              range: NSRange(location: 0, length: (String(marker.prefix(1)) as NSString).length))
            line.append(NSAttributedString(string: "\t", attributes: markerAttrs.merging([.mdPlain: " "]) { $1 }))
            line.append(inline(text, font: bodyFont))
            let nextIsList: Bool = { if case .listItem? = next { return true } else { return false } }()
            appendParagraphs(line, style: style, after: nextIsList ? listGap : blockGap,
                             plainEnd: nextIsList ? nil : endPlain, to: out)

        case let .code(language, text):
            let box = NSTextBlock()
            box.backgroundColor = codeBackground
            box.setBorderColor(hairline)
            box.setWidth(1, type: .absoluteValueType, for: .border)
            box.setWidth(10, type: .absoluteValueType, for: .padding)
            box.setContentWidth(100, type: .percentageValueType)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [box]
            let start = out.length
            let label = NSMutableParagraphStyle()
            label.textBlocks = [box]
            label.paragraphSpacing = 4
            out.append(NSAttributedString(string: (language.isEmpty ? "code" : language) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: label,
                .mdNoCopy: true,
            ]))
            out.append(NSAttributedString(string: (text.isEmpty ? " " : text) + "\n", attributes: [
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]))
            out.addAttribute(.mdPlain, value: endPlain, range: NSRange(location: out.length - 1, length: 1))
            out.addAttribute(.mdCode, value: CodeRef(text), range: NSRange(location: start, length: out.length - start))
            appendSpacer(to: out)

        case let .quote(text):
            let bar = NSTextBlock()
            bar.setBorderColor(NSColor.secondaryLabelColor.withAlphaComponent(0.4))
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            bar.setContentWidth(100, type: .percentageValueType)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [bar]
            appendParagraphs(inline(text, font: bodyFont, color: .secondaryLabelColor), style: style, after: 0,
                             plainEnd: endPlain, to: out)
            appendSpacer(to: out)

        case let .table(header, rows):
            let table = NSTextTable()
            table.numberOfColumns = max(header.count, 1)
            table.collapsesBorders = true
            let all = [header] + rows
            for (r, row) in all.enumerated() {
                for c in 0..<table.numberOfColumns {
                    let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    cell.setBorderColor(hairline)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setWidth(4, type: .absoluteValueType, for: .padding)
                    cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                    if r == 0 { cell.backgroundColor = codeBackground }
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [cell]
                    let text = c < row.count ? row[c] : ""
                    let content = inline(text, font: r == 0 ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) : bodyFont)
                    let lastColumn = c == table.numberOfColumns - 1
                    let plain = !lastColumn ? "\t" : (r == all.count - 1 ? endPlain : nil)
                    appendParagraphs(content, style: style, after: 0, plainEnd: plain, to: out)
                }
            }
            appendSpacer(to: out)

        case .rule:
            let line = NSTextBlock()
            line.setBorderColor(hairline)
            line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            line.setContentWidth(100, type: .percentageValueType)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [line]
            out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
                .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style, .mdNoCopy: true,
            ]))
            appendSpacer(to: out)
        }
    }

    /// The gap after a boxed block (code, quote, table, rule). NSTextBlock margins paint the box's background and
    /// table margins are ignored, so it's an empty line of fixed height instead.
    private static func appendSpacer(to out: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = blockGap
        style.maximumLineHeight = blockGap
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style, .mdNoCopy: true,
        ]))
    }

    /// Appends `content` plus a terminator. Line breaks inside it become their own paragraphs (same style); only the
    /// last one gets the gap after the block.
    private static func appendParagraphs(_ content: NSMutableAttributedString, style: NSMutableParagraphStyle, after: CGFloat,
                                         plainEnd: String?, to out: NSMutableAttributedString) {
        let start = out.length
        var attrs: [NSAttributedString.Key: Any] = content.length > 0
            ? content.attributes(at: content.length - 1, effectiveRange: nil) : [.font: bodyFont]
        // A line ending in `code` or a link mustn't paint/link the rest of the line.
        for key in [NSAttributedString.Key.backgroundColor, .link, .strikethroughStyle] { attrs[key] = nil }
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: attrs))
        let inner = style.copy() as! NSParagraphStyle
        let lastStyle = style.mutableCopy() as! NSMutableParagraphStyle
        lastStyle.paragraphSpacing = after
        let ns = out.string as NSString
        let lastPara = ns.paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        let lastStart = max(lastPara.location, start)
        out.addAttribute(.paragraphStyle, value: inner, range: NSRange(location: start, length: lastStart - start))
        out.addAttribute(.paragraphStyle, value: lastStyle, range: NSRange(location: lastStart, length: out.length - lastStart))
        out.removeAttribute(.mdPlain, range: NSRange(location: out.length - 1, length: 1))
        if let plainEnd { out.addAttribute(.mdPlain, value: plainEnd, range: NSRange(location: out.length - 1, length: 1)) }
    }

    /// Inline markdown (bold, italic, `code`, links, strikethrough) as AppKit attributes.
    static func inline(_ s: String, font: NSFont, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let parsed = MarkdownText.inline(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    f = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = codeBackground
                }
                var traits = f.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if traits != f.fontDescriptor.symbolicTraits {
                    f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
