import Foundation

/// One-way notifications to a webhook: Discord, Slack, ntfy (free phone push, no account), or anything that takes JSON.
public struct Webhook: Sendable {
    public enum Kind: String, Sendable { case discord, slack, ntfy, generic }

    public let url: URL
    public var session: URLSession = .shared

    public init?(_ string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        self.url = url
    }

    public var kind: Kind {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("discord.com") || host.hasSuffix("discordapp.com") { return .discord }
        if host == "hooks.slack.com" { return .slack }
        if host == "ntfy.sh" || host.hasPrefix("ntfy.") { return .ntfy }
        return .generic
    }

    /// The HTTP request for a message (title is the first line for services that show one).
    public func request(title: String, body: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        let full = title.isEmpty ? body : (body.isEmpty ? title : title + "\n\n" + body)
        switch kind {
        case .ntfy:
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // Header values must be plain ASCII.
            let asciiTitle = title.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(String.init).joined()
                .trimmingCharacters(in: .whitespaces)
            if !asciiTitle.isEmpty { req.setValue(String(asciiTitle.prefix(200)), forHTTPHeaderField: "Title") }
            req.httpBody = Data(String(body.isEmpty ? title : body).prefix(4000).utf8)
        case .discord:
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Loop output must never ping @everyone or roles.
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": String(full.prefix(1990)),
                                                                        "allowed_mentions": ["parse": [String]()]])
        case .slack, .generic:
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Slack treats <!channel>, <@user> and & specially; escape them so output can't ping anyone.
            let escaped = full.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": String((kind == .slack ? escaped : full).prefix(3900)),
                                                                        "title": title, "body": body])
        }
        return req
    }

    /// Returns an error message, or nil when it went through.
    public func send(title: String, body: String) async -> String? {
        do {
            let (_, response) = try await session.data(for: request(title: title, body: body))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? nil : "webhook returned HTTP \(code)"
        } catch {
            return error.localizedDescription
        }
    }
}
