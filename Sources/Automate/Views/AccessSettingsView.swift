import SwiftUI
import CoreServices
import AutomateCore

/// Settings → Access: everything Automate (and the Claude it runs) is allowed to do, in one place, read-only,
/// with where to change each thing.
struct AccessSettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: SettingsTab
    @State private var system = SystemAccess()
    @State private var claudeConfig = ClaudeConfig.load()

    var body: some View {
        let s = model.settings
        let m = s.messaging
        Form {
            Section {
                Text("What Automate and the Claude it runs are allowed to do. Nothing here can be changed on this page; each part says where to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude account") {
                AccessRow("Account", accountText, tone: accountTone)
                AccessRow("claude command", model.detectedClaude?.executable ?? "Not found",
                          tone: model.detectedClaude == nil ? .bad : .normal)
                HowTo("General tab → Claude. To switch accounts, run `claude` in Terminal and use /login.") {
                    Button("Open General") { tab = .general }
                }
            }

            Section("Threads") {
                AccessRow("Default permissions", s.defaultPermission.label, tone: tone(s.defaultPermission),
                          detail: Self.explain(s.defaultPermission))
                ForEach(model.projects.filter { $0.permissionMode != nil }) { p in
                    AccessRow("\(p.name) (project)", p.permissionMode!.label, tone: tone(p.permissionMode!))
                }
                let risky = model.threads.filter { !$0.archived && [.bypassPermissions, .dontAsk].contains($0.permissionMode) }
                if !risky.isEmpty {
                    AccessRow("Threads set to bypass / don't ask", risky.map(\.title).prefix(5).joined(separator: ", "), tone: .warn)
                }
                AccessRow("Threads may set up loops", s.threadsCanMakeLoops ? "Yes (they arrive switched off for review)" : "No")
                AccessRow("Project threads on their own git branch", s.worktreeByDefault ? "Yes" : "No")
                let coordinators = model.threads.filter { !$0.archived && $0.isCoordinator == true }
                AccessRow("Coordinator threads (start threads in your projects)",
                          coordinators.isEmpty ? "None" : coordinators.map(\.title).prefix(5).joined(separator: ", "),
                          tone: coordinators.isEmpty ? .normal : .warn,
                          detail: "Each can hand out up to \(Dispatch.budget) tasks per message you send it. To change: the Coordinator button under that thread's message box.")
                HowTo("Default: General tab → New threads. One project: right-click it in the sidebar → Project Settings…. One thread: the Permissions picker in that thread's settings.") {
                    Button("Open General") { tab = .general }
                }
            }

            Section("Loops") {
                let on = model.loops.filter(\.enabled)
                AccessRow("Switched on", "\(on.count) of \(model.loops.count)")
                AccessRow("Hold loops at usage", s.usageGuardPercent == 0 ? "Never" : "\(s.usageGuardPercent)% of a limit")
                ForEach(model.loops) { loop in
                    LoopAccessRow(loop: loop, accepted: model.isRiskAccepted(loop)) {
                        model.selection = .loop(loop.id)
                        model.showMainWindow()
                    }
                }
                HowTo("Each loop's own settings (permission, autonomy, tools, Chrome, check:) live at the top of its file: open the loop and press Edit. Hold-at-usage is in the Loops tab.") {
                    Button("Open Loops Folder") { NSWorkspace.shared.open(model.store.loopsDir) }
                }
            }

            Section("Texting") {
                AccessRow("Telegram", m.telegramEnabled ? model.messaging.telegramStatus : "Off")
                AccessRow("iMessage (Messages.app)", m.imessageEnabled
                          ? (m.imessageCommands ? "On, reads replies starting with \"\(m.imessageKeyword)\"" : "On, send only") : "Off")
                AccessRow("Photon", m.photonEnabled ? model.messaging.photonStatus : "Off")
                AccessRow("Webhook (send only)", m.webhookEnabled ? "On" : "Off")
                if model.messaging.canReceive {
                    AccessRow("Chat with Claude by text", m.allowRemoteChat ? "Yes, with \(s.defaultPermission.label)" : "No",
                              tone: m.allowRemoteChat ? tone(s.defaultPermission) : .normal,
                              detail: m.allowRemoteChat ? "Texts start threads that use the default thread permissions." : nil)
                    AccessRow("Approve loops by text", m.sendApprovals ? "Yes" : "No")
                    AccessRow("Run loops by text", "Only loops whose settings you've OK'd")
                }
                HowTo("Messaging tab.") { Button("Open Messaging") { tab = .messaging } }
            }

            Section("Links & shortcuts") {
                AccessRow("automate:// links act on their own", s.urlsMaySend ? "Yes: they send messages and run switched-on loops" : "No: they only fill a draft or open the loop",
                          tone: s.urlsMaySend ? .warn : .normal,
                          detail: "Any web page can open these links.")
                AccessRow("⌃⌥Space Quick Ask", s.quickAskHotKey ? "On" : "Off")
                HowTo("Links: Loops tab → Links & Shortcuts. Hotkey: General tab → New threads.") {
                    Button("Open Loops") { tab = .loops }
                }
            }

            Section("macOS privacy (the \"Automate would like to access…\" popups)") {
                Text("Claude runs inside Automate, so when it touches your Desktop, Photos library, Music folder and so on (say, while searching your home folder), macOS asks on Automate's behalf. These are your answers so far.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(system.privacy) { item in
                    PrivacyRow(item: item) { open(Self.pane(item.pane)) }
                }
                AccessRow("Control Messages (Automation)", system.automateMessages,
                          detail: "Used to send iMessages through Messages.app.")
                AccessRow("Notifications", system.notifications, tone: system.notifications.hasPrefix("On") ? .normal : .warn)
                AccessRow("Open at login", LaunchAtLogin.isEnabled ? "On" : "Off")
                if let signing = system.signing {
                    AccessRow("Answers survive updates", signing.adhoc ? "No (ad-hoc signed build)" : "Yes (signed by \(signing.team ?? "you"))",
                              tone: signing.adhoc ? .warn : .normal,
                              detail: signing.adhoc ? "macOS forgets these answers each time Automate is rebuilt, so the popups come back. Builds signed with your Apple Development certificate keep them." : nil)
                }
                HowTo("Press Open next to a row, then switch Automate on or off in that list (\"Not asked yet\" items aren't listed there until macOS has asked once). Full Disk Access covers every folder above at once. To forget every answer and be asked again: `tccutil reset All com.siddhuyen.automate` in Terminal.") {
                    Button("Privacy & Security") { open(Self.pane("Privacy")) }
                    Button("Notifications") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                    Button("Login Items") { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                }
            }

            Section("Claude Code's own rules (apply to every thread and loop)") {
                AccessRow("Always allowed", claudeConfig.allow.isEmpty ? "None" : claudeConfig.allow.joined(separator: ", "))
                AccessRow("Always asked", claudeConfig.ask.isEmpty ? "None" : claudeConfig.ask.joined(separator: ", "))
                AccessRow("Never allowed", claudeConfig.deny.isEmpty ? "None" : claudeConfig.deny.joined(separator: ", "))
                if let mode = claudeConfig.defaultMode { AccessRow("Default mode in Claude Code", mode) }
                AccessRow("Plugins on", claudeConfig.plugins.isEmpty ? "None" : claudeConfig.plugins.joined(separator: ", "))
                AccessRow("Local MCP servers", claudeConfig.mcpServers.isEmpty ? "None" : claudeConfig.mcpServers.joined(separator: ", "))
                AccessRow("claude.ai connectors", "Gmail, Calendar and the like come from your claude.ai account")
                HowTo("Rules and plugins: ~/.claude/settings.json (or /permissions and /plugin in `claude`). MCP servers: `claude mcp`. Connectors: claude.ai → Settings → Connectors.") {
                    Button("Show settings.json") { reveal(ClaudeConfig.settingsURL) }
                    Button("Connectors") { open("https://claude.ai/settings/connectors") }
                }
            }

            Section("What Automate keeps") {
                AccessRow("Data folder", model.store.root.path)
                AccessRow("Secrets (owner-only file)", secretNames.isEmpty ? "None" : secretNames.joined(separator: ", "),
                          detail: "Only the names are shown here, never the values.")
                HowTo("Messaging tab removes tokens when you turn a channel off or unpair.") {
                    Button("Open Data Folder") { NSWorkspace.shared.open(model.store.root) }
                }
            }
        }
        .modifier(SettingsFormStyle())
        .task {
            claudeConfig = ClaudeConfig.load()
            system = await SystemAccess.check()
        }
    }

    private var accountText: String {
        guard let a = model.auth else { return "Unknown" }
        if !a.loggedIn { return "Not signed in" }
        if a.usesSubscription { return "\(a.plan.map { $0.capitalized + " plan" } ?? "Subscription") (no per-use charges)" }
        return "\(a.method): billed per use"
    }

    private var accountTone: AccessRow.Tone {
        guard let a = model.auth else { return .normal }
        return !a.loggedIn ? .bad : (a.usesSubscription ? .normal : .warn)
    }

    private var secretNames: [String] {
        let url = model.store.root.appendingPathComponent("secrets.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return dict.keys.sorted()
    }

    private func tone(_ mode: PermissionMode) -> AccessRow.Tone {
        switch mode {
        case .bypassPermissions: return .bad
        case .dontAsk: return .warn
        default: return .normal
        }
    }

    static func explain(_ mode: PermissionMode) -> String {
        switch mode {
        case .plan: return "Read-only: Claude can look and suggest, but can't edit files or run changing commands."
        case .acceptEdits: return "Edits files without asking; other actions need approval."
        case .auto: return "A safety check approves routine actions and blocks risky ones."
        case .dontAsk: return "Only tools on the allow list run; everything else is refused."
        case .bypassPermissions: return "Claude does anything without asking."
        case .manual: return "Asks before each action; unattended runs can't ask, so those actions are refused."
        }
    }

    static func pane(_ anchor: String) -> String {
        "x-apple.systempreferences:com.apple.preference.security?" + anchor
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum SettingsTab: Hashable { case general, loops, messaging, access }

private struct AccessRow: View {
    enum Tone { case normal, warn, bad }
    let title: String
    let value: String
    var tone: Tone = .normal
    var detail: String?

    init(_ title: String, _ value: String, tone: Tone = .normal, detail: String? = nil) {
        self.title = title
        self.value = value
        self.tone = tone
        self.detail = detail
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .foregroundStyle(tone == .bad ? Color.red : tone == .warn ? Color.orange : Color.primary)
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

/// "To change: …" at the bottom of a section, with buttons that take you there.
private struct HowTo<Buttons: View>: View {
    let text: String
    let buttons: Buttons

    init(_ text: String, @ViewBuilder buttons: () -> Buttons) {
        self.text = text
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To change: " + text)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack { buttons }.controlSize(.small)
        }
    }
}

private struct LoopAccessRow: View {
    let loop: LoopDefinition
    let accepted: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: loop.enabled ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(loop.enabled ? Color.green : Color.secondary)
                    Text(loop.name)
                    if loop.projectRoot != nil {
                        Text(loop.projectRoot!.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(facts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(loop.permissionMode == .bypassPermissions || loop.chrome ? Color.orange : Color.secondary)
                if !accepted {
                    Text("Has settings you haven't OK'd yet (\(loop.riskDescription.joined(separator: ", "))), so it stays off.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }
            Spacer()
            Button("Open", action: open).controlSize(.small)
        }
    }

    private var facts: [String] {
        var f = [loop.autonomy == .ask ? "Plan (read-only) until approved" : loop.permissionMode.label,
                 "autonomy: \(loop.autonomy.rawValue)"]
        if !loop.allowedTools.isEmpty { f.append("tools: " + loop.allowedTools.joined(separator: ", ")) }
        if !loop.disallowedTools.isEmpty { f.append("blocked: " + loop.disallowedTools.joined(separator: ", ")) }
        if loop.chrome { f.append("uses your Chrome") }
        if loop.check != nil { f.append("runs a check: command") }
        if let cwd = loop.cwd { f.append("works in \(cwd)") }
        return f
    }
}

/// Claude Code's user-level settings (~/.claude/settings.json) and MCP servers (~/.claude.json).
private struct ClaudeConfig {
    var allow: [String] = []
    var ask: [String] = []
    var deny: [String] = []
    var defaultMode: String?
    var plugins: [String] = []
    var mcpServers: [String] = []

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func load() -> ClaudeConfig {
        var c = ClaudeConfig()
        if let json = object(at: settingsURL) {
            let perms = json["permissions"] as? [String: Any] ?? [:]
            c.allow = perms["allow"] as? [String] ?? []
            c.ask = perms["ask"] as? [String] ?? []
            c.deny = perms["deny"] as? [String] ?? []
            c.defaultMode = perms["defaultMode"] as? String
            let plugins = json["enabledPlugins"] as? [String: Bool] ?? [:]
            c.plugins = plugins.filter(\.value).keys.map { $0.split(separator: "@").first.map(String.init) ?? $0 }.sorted()
        }
        let global = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let json = object(at: global), let servers = json["mcpServers"] as? [String: Any] {
            c.mcpServers = servers.keys.sorted()
        }
        return c
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// One macOS privacy permission (a TCC service) and your answer for Automate.
struct PrivacyItem: Identifiable {
    enum Answer { case allowed, denied, notAsked, unknown }
    let service: String
    let name: String
    let why: String
    /// The Privacy & Security pane, as a `?Privacy_…` anchor.
    let pane: String
    var answer: Answer = .unknown
    var id: String { service }

    static let all: [PrivacyItem] = [
        .init(service: "kTCCServiceSystemPolicyAllFiles", name: "Full Disk Access",
              why: "Every folder, plus reading your iMessage replies. Never asked; only you can add it.", pane: "Privacy_AllFiles"),
        .init(service: "kTCCServiceSystemPolicyDesktopFolder", name: "Desktop folder",
              why: "When Claude reads or saves files on your Desktop.", pane: "Privacy_FilesAndFolders"),
        .init(service: "kTCCServiceSystemPolicyDocumentsFolder", name: "Documents folder",
              why: "When Claude works with files in Documents.", pane: "Privacy_FilesAndFolders"),
        .init(service: "kTCCServiceSystemPolicyDownloadsFolder", name: "Downloads folder",
              why: "When Claude opens something you downloaded.", pane: "Privacy_FilesAndFolders"),
        .init(service: "kTCCServiceSystemPolicyNetworkVolumes", name: "Network drives",
              why: "When Claude looks at a mounted server or NAS.", pane: "Privacy_FilesAndFolders"),
        .init(service: "kTCCServiceSystemPolicyRemovableVolumes", name: "USB and external drives",
              why: "When Claude looks at a plugged-in drive.", pane: "Privacy_FilesAndFolders"),
        .init(service: "kTCCServicePhotos", name: "Photos",
              why: "When Claude looks inside ~/Pictures, where the Photos library lives.", pane: "Privacy_Photos"),
        .init(service: "kTCCServiceMediaLibrary", name: "Apple Music and media",
              why: "When Claude looks inside ~/Music.", pane: "Privacy_Media"),
        .init(service: "kTCCServiceContacts", name: "Contacts",
              why: "When Claude reads your Contacts data.", pane: "Privacy_Contacts"),
        .init(service: "kTCCServiceCalendar", name: "Calendars",
              why: "When Claude reads the Calendar app's data.", pane: "Privacy_Calendars"),
        .init(service: "kTCCServiceReminders", name: "Reminders",
              why: "When Claude reads the Reminders app's data.", pane: "Privacy_Reminders"),
        .init(service: "kTCCServiceAccessibility", name: "Accessibility",
              why: "Controlling other apps. Automate doesn't need it.", pane: "Privacy_Accessibility"),
        .init(service: "kTCCServiceScreenCapture", name: "Screen recording",
              why: "Seeing your screen. Automate doesn't need it.", pane: "Privacy_ScreenCapture"),
        .init(service: "kTCCServiceCamera", name: "Camera", why: "Automate doesn't need it.", pane: "Privacy_Camera"),
        .init(service: "kTCCServiceMicrophone", name: "Microphone", why: "Automate doesn't need it.", pane: "Privacy_Microphone"),
    ]
}

private struct PrivacyRow: View {
    let item: PrivacyItem
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(answerText, systemImage: answerIcon)
                .foregroundStyle(answerColor)
            Button("Open", action: open).controlSize(.small)
        }
    }

    private var answerText: String {
        switch item.answer {
        case .allowed: return "Allowed"
        case .denied: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case .unknown: return "Unknown"
        }
    }

    private var answerIcon: String {
        switch item.answer {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle"
        case .notAsked: return "questionmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    private var answerColor: Color {
        switch item.answer {
        case .allowed: return .green
        case .denied: return .secondary
        case .notAsked, .unknown: return .secondary
        }
    }
}

/// macOS privacy permissions, checked without ever prompting.
private struct SystemAccess {
    var notifications = "Checking…"
    var automateMessages = "Checking…"
    var privacy = PrivacyItem.all
    var signing: (adhoc: Bool, team: String?)?

    @MainActor
    static func check() async -> SystemAccess {
        var s = SystemAccess()
        s.notifications = await Notifier.shared.statusText()
        let (privacy, messages, signing) = await Task.detached {
            (PrivacyItem.all.map { item in var i = item; i.answer = preflight(item.service); return i },
             messagesAutomation(), signingInfo())
        }.value
        s.privacy = privacy
        s.automateMessages = messages
        s.signing = signing
        return s
    }

    /// TCC's own "what would happen if I asked" check (private, but stable since 10.14). It never shows a popup.
    /// 0 = allowed, 1 = denied, 2 = would ask.
    nonisolated private static func preflight(_ service: String) -> PrivacyItem.Answer {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let lib = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let sym = dlsym(lib, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service as CFString, nil) {
        case 0: return .allowed
        case 1: return .denied
        case 2: return .notAsked
        default: return .unknown
        }
    }

    /// macOS keys privacy answers to the app's signature; an ad-hoc one changes with every build.
    nonisolated private static func signingInfo() -> (adhoc: Bool, team: String?)? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let unsigned = dict[kSecCodeInfoIdentifier as String] == nil
        return (adhoc: unsigned || flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
                team: dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    nonisolated private static func messagesAutomation() -> String {
        var target = AEAddressDesc()
        let bundleId = "com.apple.MobileSMS"
        let created = bundleId.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return "Unknown" }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
        case noErr: return "Allowed"
        case OSStatus(errAEEventNotPermitted): return "Not allowed"
        case OSStatus(errAEEventWouldRequireUserConsent): return "Not asked yet"
        case OSStatus(procNotFound): return "Unknown (Messages isn't open)"
        default: return "Unknown"
        }
    }
}

#if DEBUG
/// For `--snapshot`: just the privacy rows (the full form doesn't render offscreen).
struct PrivacyRowsPreview: View {
    @State private var system = SystemAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(system.privacy) { PrivacyRow(item: $0) {} }
            Text("signed: \(system.signing.map { $0.adhoc ? "ad-hoc" : ($0.team ?? "?") } ?? "nil") · messages: \(system.automateMessages)")
        }
        .padding()
        .task { system = await SystemAccess.check() }
    }
}
#endif
