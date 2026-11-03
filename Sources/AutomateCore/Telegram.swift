import Foundation

/// Just enough of the Telegram Bot API for a private bot that only talks to you. Bots are free: make one by
/// messaging @BotFather in Telegram.
public struct TelegramClient: Sendable {
    public let token: String
    public var session: URLSession = .shared

    public init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the Bot API lives. Only tests point this elsewhere (a local fake server).
    nonisolated(unsafe) public static var apiBase = "https://api.telegram.org"

    public struct Bot: Sendable, Equatable {
        public var id: Int64
        public var username: String
    }

    /// A message or button press from Telegram.
    public struct Update: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// `files`: photos and documents sent with the message (download with `download`).
            case message(text: String, files: [File] = [])
            /// Inline button press. `messageId` is the message the button was on.
            case button(callbackId: String, data: String, messageId: Int64?)
        }
        public var updateId: Int64
        public var chatId: Int64
        public var kind: Kind
        /// "private", "group", "supergroup" or "channel".
        public var chatType: String = "private"
        /// The bot message this one replies to (swipe-to-reply).
        public var replyTo: Int64?
        /// This message's own id, so answers can reply to it.
        public var messageId: Int64?
    }

    public struct File: Sendable, Equatable {
        public var id: String
        public var name: String
        public var size: Int
    }

    public struct APIError: Error, LocalizedError, Sendable {
        public var description: String
        public var isUnauthorized: Bool
        public var errorDescription: String? { description }
    }

    /// Inline buttons: rows of (label, callback data).
    public typealias Keyboard = [[(String, String)]]

    // MARK: Calls

    public func getMe() async throws -> Bot {
        let result = try await call("getMe", [:])
        guard let r = result as? [String: Any], let id = (r["id"] as? NSNumber)?.int64Value else {
            throw APIError(description: "Unexpected reply from Telegram", isUnauthorized: false)
        }
        return Bot(id: id, username: r["username"] as? String ?? "")
    }

    /// Long-polls for new updates (waits up to `timeout` seconds when there are none).
    public func getUpdates(offset: Int64, timeout: Int = 50) async throws -> [Update] {
        let result = try await call("getUpdates", [
            "offset": offset, "timeout": timeout,
            "allowed_updates": ["message", "callback_query"],
        ], timeout: TimeInterval(timeout + 15))
        return Self.parseUpdates(result)
    }

    /// Sends `text` (split into several messages if it's long). Buttons go on the last one; returns its id.
    @discardableResult
    /// `replyTo`: a message id to answer (the first part replies to it; sent anyway if it's gone).
    public func sendMessage(chatId: Int64, text: String, keyboard: Keyboard? = nil, html: Bool = false,
                            replyTo: Int64? = nil) async throws -> Int64? {
        // HTML can't be split safely (a cut could land inside a tag), so it's sent whole.
        let parts = html ? [text] : Self.split(text)
        var lastId: Int64?
        for (i, part) in parts.enumerated() {
            var params: [String: Any] = ["chat_id": chatId, "text": part, "disable_web_page_preview": true]
            if html { params["parse_mode"] = "HTML" }
            if let replyTo, i == 0 { params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
            if let keyboard, i == parts.count - 1 { params["reply_markup"] = Self.markup(keyboard) }
            let result = try await call("sendMessage", params)
            lastId = ((result as? [String: Any])?["message_id"] as? NSNumber)?.int64Value
        }
        return lastId
    }

    /// Telegram allows 4096 UTF-16 units per message. Split at paragraph or line breaks; at most `maxParts`.
    public static func split(_ text: String, limit: Int = 3900, maxParts: Int = 4) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.utf16.count <= limit || parts.count == maxParts - 1 {
                var last = String(rest)
                while last.utf16.count > limit { last = String(last.prefix(last.count * 9 / 10)) + "…" }
                parts.append(last)
                break
            }
            // Longest prefix within the limit, cut at a paragraph, line or word break when there's one.
            var cut = rest.startIndex
            var units = 0
            for i in rest.indices {
                units += rest[i].utf16.count
                if units > limit { break }
                cut = rest.index(after: i)
            }
            let window = rest[..<cut]
            let half = window.index(window.startIndex, offsetBy: window.count / 2)
            if let r = window.range(of: "\n\n", options: .backwards), r.lowerBound > half { cut = r.upperBound }
            else if let r = window.range(of: "\n", options: .backwards), r.lowerBound > half { cut = r.upperBound }
            else if let r = window.range(of: " ", options: .backwards), r.lowerBound > half { cut = r.upperBound }
            parts.append(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...]
        }
        return parts.filter { !$0.isEmpty }
    }

    public func answerButton(_ callbackId: String, text: String? = nil) async {
        var params: [String: Any] = ["callback_query_id": callbackId]
        if let text { params["text"] = text }
        _ = try? await call("answerCallbackQuery", params)
    }

    /// Replace a message's buttons (e.g. with nothing once you've answered).
    public func setButtons(chatId: Int64, messageId: Int64, keyboard: Keyboard) async {
        _ = try? await call("editMessageReplyMarkup", [
            "chat_id": chatId, "message_id": messageId, "reply_markup": Self.markup(keyboard),
        ])
    }

    /// Download a file someone sent the bot (bots can fetch files up to 20 MB).
    public func download(_ file: File) async throws -> Data {
        let result = try await call("getFile", ["file_id": file.id])
        guard let path = (result as? [String: Any])?["file_path"] as? String,
              let url = URL(string: "\(Self.apiBase)/file/bot\(token)/\(path)") else {
            throw APIError(description: "Telegram didn't give a download link", isUnauthorized: false)
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(description: "Download failed", isUnauthorized: false)
        }
        return data
    }

    /// The command menu Telegram shows when you type "/".
    public func setCommands(_ commands: [(String, String)]) async {
        _ = try? await call("setMyCommands", ["commands": commands.map { ["command": $0.0, "description": $0.1] }])
    }

    /// Shows "typing…" in the chat for about 5 seconds.
    public func sendTyping(chatId: Int64) async {
        _ = try? await call("sendChatAction", ["chat_id": chatId, "action": "typing"])
    }

    // MARK: Plumbing

    static func markup(_ keyboard: Keyboard) -> [String: Any] {
        ["inline_keyboard": keyboard.map { row in row.map { ["text": $0.0, "callback_data": $0.1] } }]
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> Any {
        guard !token.isEmpty, let url = URL(string: "\(Self.apiBase)/bot\(token)/\(method)") else {
            throw APIError(description: "No bot token", isUnauthorized: true)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(description: "Telegram returned HTTP \(status)", isUnauthorized: status == 401)
        }
        if (obj["ok"] as? Bool) == true, let result = obj["result"] { return result }
        let desc = obj["description"] as? String ?? "HTTP \(status)"
        throw APIError(description: desc, isUnauthorized: status == 401 || status == 404)
    }

    public static func parseUpdates(_ result: Any) -> [Update] {
        guard let list = result as? [[String: Any]] else { return [] }
        return list.compactMap { u -> Update? in
            guard let updateId = (u["update_id"] as? NSNumber)?.int64Value else { return nil }
            if let m = u["message"] as? [String: Any],
               let chat = m["chat"] as? [String: Any], let chatId = (chat["id"] as? NSNumber)?.int64Value {
                let text = m["text"] as? String ?? m["caption"] as? String ?? ""
                var files: [File] = []
                // Photos come in several sizes; take the largest.
                if let sizes = m["photo"] as? [[String: Any]],
                   let best = sizes.max(by: { (($0["file_size"] as? Int) ?? 0) < (($1["file_size"] as? Int) ?? 0) }),
                   let id = best["file_id"] as? String {
                    files.append(File(id: id, name: "photo-\(updateId).jpg", size: best["file_size"] as? Int ?? 0))
                }
                if let doc = m["document"] as? [String: Any], let id = doc["file_id"] as? String {
                    files.append(File(id: id, name: doc["file_name"] as? String ?? "file-\(updateId)", size: doc["file_size"] as? Int ?? 0))
                }
                var update = Update(updateId: updateId, chatId: chatId, kind: .message(text: text, files: files),
                                    chatType: chat["type"] as? String ?? "private")
                update.replyTo = ((m["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber)?.int64Value
                update.messageId = (m["message_id"] as? NSNumber)?.int64Value
                return update
            }
            if let q = u["callback_query"] as? [String: Any], let id = q["id"] as? String {
                let msg = q["message"] as? [String: Any]
                let chatId = ((msg?["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value
                    ?? ((q["from"] as? [String: Any])?["id"] as? NSNumber)?.int64Value
                guard let chatId else { return nil }
                return Update(updateId: updateId, chatId: chatId,
                              kind: .button(callbackId: id, data: q["data"] as? String ?? "",
                                            messageId: (msg?["message_id"] as? NSNumber)?.int64Value))
            }
            // Other update kinds still advance the offset.
            return Update(updateId: updateId, chatId: 0, kind: .message(text: ""))
        }
    }
}

/// Reading iMessage's database (`~/Library/Messages/chat.db`). Newer macOS versions leave `text` empty and keep
/// the message in `attributedBody`, an archived NSAttributedString.
public enum IMessageText {
    public static func decode(attributedBody data: Data) -> String? {
        // typedstream layout: ... "NSString" <5 bytes> <length> <utf8 bytes> ...
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = bytes.firstRange(of: marker)?.upperBound else { return nil }
        var i = start + 5
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81 { // 16-bit little-endian length
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        } else if length == 0x82 { // 32-bit little-endian length
            guard i + 3 < bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }
}

/// Claude's markdown as Telegram's small HTML subset (<b>, <i>, <code>, <pre>, <a>). Everything else is escaped text.
public enum TelegramHTML {
    public static func from(markdown: String) -> String {
        var out: [String] = []
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case let .heading(_, text): out.append("<b>" + inline(text) + "</b>")
            case let .paragraph(text): out.append(inline(text))
            case let .listItem(marker, indent, text):
                out.append(String(repeating: "  ", count: indent) + (marker == "•" ? "•" : escape(marker)) + " " + inline(text))
            case let .code(_, text): out.append("<pre>" + escape(text) + "</pre>")
            case let .quote(text): out.append("<i>" + inline(text) + "</i>")
            case let .table(header, rows):
                out.append("<pre>" + escape(([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")) + "</pre>")
            case .rule: out.append("—")
            }
        }
        // Keep list items together; blank line between other blocks.
        var text = ""
        for (i, line) in out.enumerated() {
            if i > 0 { text += (line.hasPrefix("•") || line.first?.isNumber == true || line.hasPrefix("  ")) ? "\n" : "\n\n" }
            text += line
        }
        return text
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `code`, **bold**, *italic*/_italic_, [label](url). Unmatched markers stay as text.
    static func inline(_ s: String) -> String {
        var result = ""
        var rest = Substring(s)
        while !rest.isEmpty {
            if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                result += "<code>" + escape(String(rest[rest.index(after: rest.startIndex)..<end])) + "</code>"
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), let r = rest.dropFirst(2).range(of: "**"), !rest.dropFirst(2)[..<r.lowerBound].isEmpty {
                result += "<b>" + inline(String(rest.dropFirst(2)[..<r.lowerBound])) + "</b>"
                rest = rest[r.upperBound...]
            } else if rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
                      rest[rest.index(after: close)...].hasPrefix("("),
                      let paren = rest[close...].firstIndex(of: ")") {
                let label = rest[rest.index(after: rest.startIndex)..<close]
                let url = rest[rest.index(close, offsetBy: 2)..<paren]
                if url.hasPrefix("http") {
                    result += "<a href=\"" + escape(String(url)).replacingOccurrences(of: "\"", with: "&quot;") + "\">" + escape(String(label)) + "</a>"
                    // Show where it goes, so a link's label can't pretend to be somewhere else.
                    if let host = URL(string: String(url))?.host, !label.lowercased().contains(host.lowercased()) {
                        result += " (" + escape(host) + ")"
                    }
                } else {
                    result += escape(String(rest[...paren]))
                }
                rest = rest[rest.index(after: paren)...]
            } else if let c = rest.first, c == "*" || c == "_", rest.count > 2,
                      !(result.last.map { $0.isLetter || $0.isNumber } ?? false), // not inside a word (snake_case)
                      let end = rest.dropFirst().firstIndex(of: c), end != rest.index(after: rest.startIndex),
                      rest[rest.index(after: rest.startIndex)] != " ",
                      !(rest[rest.index(after: end)...].first.map { $0.isLetter || $0.isNumber } ?? false) {
                result += "<i>" + escape(String(rest[rest.index(after: rest.startIndex)..<end])) + "</i>"
                rest = rest[rest.index(after: end)...]
            } else {
                result += escape(String(rest.first!))
                rest = rest.dropFirst()
            }
        }
        return result
    }
}
