import Foundation

/// `automate://` links, for Shortcuts, Raycast, Alfred or a shell (`open "automate://ask?text=hi"`).
///
///   automate://ask?text=…[&project=<name>][&background=1]   ask Claude in a new thread
///   automate://run/<loop>                                   run a loop now (file name or name)
///   automate://open/inbox | activity | loop/<id> | thread/<uuid>
///   automate://quick-ask                                    show the Quick Ask box
public enum AutomateURL: Equatable, Sendable {
    case ask(text: String, project: String?, background: Bool)
    case run(loop: String)
    case open(page: String, id: String?)
    case quickAsk

    public static func parse(_ url: URL) -> AutomateURL? {
        guard url.scheme?.lowercased() == "automate" else { return nil }
        let host = (url.host ?? "").lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
        switch host {
        case "ask":
            let text = (query["text"] ?? query["q"] ?? parts.joined(separator: "/")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .quickAsk }
            let bg = ["1", "true", "yes"].contains((query["background"] ?? "").lowercased())
            return .ask(text: text, project: query["project"].flatMap { $0.isEmpty ? nil : $0 }, background: bg)
        case "run":
            guard let loop = parts.first ?? query["loop"], !loop.isEmpty else { return nil }
            return .run(loop: loop)
        case "open":
            guard let page = parts.first?.lowercased() else { return .open(page: "inbox", id: nil) }
            return .open(page: page, id: parts.dropFirst().first)
        case "quick-ask", "quickask":
            return .quickAsk
        default:
            return nil
        }
    }
}
