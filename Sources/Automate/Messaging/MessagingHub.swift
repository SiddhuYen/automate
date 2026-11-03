import AppKit
import Foundation
import AutomateCore

/// Where messages go: Telegram (a free bot you make with @BotFather), iMessage (through Messages.app) and/or
/// Photon (iMessage from Photon's own line).
enum MessageChannel: String, Codable, CaseIterable, Sendable {
    case telegram, imessage, photon
    /// One-way: Discord, Slack, ntfy or any JSON webhook.
    case webhook
    var label: String {
        switch self {
        case .telegram: return "Telegram"
        case .imessage: return "iMessage"
        case .photon: return "Photon"
        case .webhook: return "Webhook"
        }
    }
}

/// A text for your phone. Approval requests get Approve/Skip buttons on Telegram and reply hints on iMessage.
struct OutgoingMessage {
    var text: String
    var approval: (runId: UUID, number: Int)?
    /// A list of waiting runs ("status"): a following "yes" may answer it.
    var asksForApproval = false
    /// Claude's reply in a chat: a following "yes" is for Claude.
    var isChatReply = false
    /// Not a reply to something you texted (loop results, approvals): held during quiet hours.
    var unsolicited = false
    /// The same message as markdown, for channels that can show formatting (Telegram).
    var markdown: String?
    /// The loop run this is about, so swipe-replying to it continues that run's conversation.
    var runId: UUID?
    /// The thread this is from, so swipe-replying to it continues that thread.
    var threadId: UUID?
    /// Your text this answers, per channel (Photon guid, Telegram message id): it's sent as a reply to it, so each
    /// conversation stays in its own reply thread on the phone.
    var inReplyTo: [MessageChannel: String] = [:]

    var replyTarget: ReplyTarget? {
        if let run = runId ?? approval?.runId { return .run(run) }
        return threadId.map { .thread($0) }
    }
}

/// Small secrets (the Telegram bot token) in a file only you can read, next to Automate's other data.
/// Not the Keychain: ad-hoc-signed rebuilds would make it ask for access after every build.
@MainActor
enum Secrets {
    private static var url: URL { AppModel.shared.store.root.appendingPathComponent("secrets.json") }

    static func get(_ key: String) -> String {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return dict[key] ?? ""
    }

    static func set(_ key: String, _ value: String) {
        var dict = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        dict[key] = value.isEmpty ? nil : value
        guard let data = try? JSONEncoder().encode(dict) else { return }
        // Create it private first, then write in place, so the token is never readable by others even briefly.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

@MainActor
@Observable
final class MessagingHub {
    // Shown in Settings.
    var telegramStatus = "Off"
    var telegramConnected = false
    var imessageStatus = "Off"
    var imessageNeedsFullDiskAccess = false
    var photonStatus = "Off"
    var photonConnected = false
    var lastError: String?
    /// Send this to the bot to pair your Telegram chat. Changes every 10 minutes, after a few wrong tries, and
    /// whenever you unpair, so it can't be guessed.
    private(set) var pairingCode = MessagingHub.newPairingCode()
    @ObservationIgnored private var pairingCodeDate = Date()
    @ObservationIgnored private var wrongPairingTries = 0

    static func newPairingCode() -> String {
        String((0..<8).map { _ in "0123456789".randomElement()! })
    }

    func refreshPairingCode() {
        // Message ids are per chat: after pairing or unpairing, old ones mean nothing.
        telegramTargets = [:]
        AppDefaults.shared.removeObject(forKey: "telegramRunMessages")
        pairingCode = Self.newPairingCode()
        pairingCodeDate = Date()
        wrongPairingTries = 0
    }

    @ObservationIgnored private var cachedToken: String?
    var telegramToken: String {
        get {
            if let cachedToken { return cachedToken }
            let t = Secrets.get("telegramToken")
            cachedToken = t
            return t
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // A different bot numbers its updates from scratch: forget where the old one was up to.
            if t != telegramToken {
                telegramOffset = 0
                AppDefaults.shared.removeObject(forKey: "telegramOffset")
            }
            Secrets.set("telegramToken", t)
            cachedToken = t
        }
    }

    /// Channels where Automate's latest text asked you to approve something, so "yes" / "no" answer it.
    @ObservationIgnored private var awaitingApproval: Set<MessageChannel> = []
    /// Telegram update offset, kept here so a restarted poller never handles an update twice.
    @ObservationIgnored private var telegramOffset = Int64(AppDefaults.shared.integer(forKey: "telegramOffset"))

    @ObservationIgnored private var telegramTask: Task<Void, Never>?
    @ObservationIgnored private var imessageTask: Task<Void, Never>?
    @ObservationIgnored private var photonTask: Task<Void, Never>?
    @ObservationIgnored private var typingTasks: [UUID: Task<Void, Never>] = [:]
    /// Approval messages on Telegram, so their buttons can be removed once answered (from anywhere).
    @ObservationIgnored private var approvalMessages: [UUID: (chat: Int64, message: Int64)] = [:]
    /// iMessage texts Automate sent recently; in a conversation with yourself they come back as new messages.
    @ObservationIgnored private var recentlySent: [(text: String, date: Date)] = []
    @ObservationIgnored private var recentlyHandled: [(text: String, date: Date)] = []

    private var model: AppModel { AppModel.shared }
    private var settings: MessagingSettings { model.settings.messaging }

    var isAnyChannelOn: Bool { !activeChannels.isEmpty }
    /// You can text Automate (not just receive from it).
    var canReceive: Bool { activeChannels.contains { $0 != .webhook } }

    /// Channels that can deliver right now.
    var activeChannels: [MessageChannel] {
        var c: [MessageChannel] = []
        if settings.telegramEnabled, settings.telegramChatId != nil, !telegramToken.isEmpty { c.append(.telegram) }
        if settings.imessageEnabled, !settings.imessageHandle.trimmingCharacters(in: .whitespaces).isEmpty { c.append(.imessage) }
        if settings.photonEnabled, photonClient != nil, !settings.photonAddress.isEmpty { c.append(.photon) }
        if settings.webhookEnabled, Webhook(webhookURL) != nil { c.append(.webhook) }
        return c
    }

    // MARK: - Lifecycle

    func restart() {
        loadLog()
        telegramTask?.cancel()
        imessageTask?.cancel()
        photonTask?.cancel()
        telegramTask = nil
        imessageTask = nil
        photonTask = nil
        photonChat = nil

        if settings.telegramEnabled, !telegramToken.isEmpty {
            telegramStatus = "Connecting…"
            let token = telegramToken
            telegramTask = Task { [weak self] in await self?.runTelegram(token: token) }
        } else {
            telegramConnected = false
            telegramStatus = settings.telegramEnabled ? "Add your bot token" : "Off"
        }

        imessageNeedsFullDiskAccess = false
        if settings.imessageEnabled, !settings.imessageHandle.trimmingCharacters(in: .whitespaces).isEmpty {
            if settings.imessageCommands {
                imessageStatus = "Starting…"
                imessageTask = Task { [weak self] in await self?.runIMessage() }
            } else {
                imessageStatus = "Sending only"
            }
        } else {
            imessageStatus = settings.imessageEnabled ? "Add your phone number or Apple ID" : "Off"
        }

        photonConnected = false
        if settings.photonEnabled, let client = photonClient, !settings.photonAddress.isEmpty {
            photonStatus = "Connecting…"
            let address = PhotonClient.address(from: settings.photonAddress)
            photonTask = Task { [weak self] in await self?.runPhoton(client: client, address: address) }
        } else {
            photonStatus = !settings.photonEnabled ? "Off"
                : photonClient == nil ? "Add your Photon project id and secret" : "Add the number to text"
        }
    }

    // MARK: - Sending

    func send(_ message: OutgoingMessage, via channels: [MessageChannel]? = nil) {
        if message.unsolicited && settings.isQuiet() {
            held.append((message, channels))
            return
        }
        for channel in channels ?? activeChannels where activeChannels.contains(channel) {
            if message.approval != nil || message.asksForApproval { awaitingApproval.insert(channel) }
            else if message.isChatReply { awaitingApproval.remove(channel) }
            switch channel {
            case .telegram: sendTelegram(message)
            case .imessage: sendIMessage(message)
            case .photon: sendPhoton(message)
            case .webhook: sendWebhook(message)
            }
            record(.init(channel: channel, incoming: false, text: message.text))
        }
    }

    func send(_ text: String, via channels: [MessageChannel]? = nil) {
        send(OutgoingMessage(text: text), via: channels)
    }

    /// The text being handled right now (only while handling it), so whatever it starts can answer it.
    @ObservationIgnored private(set) var incoming: (channel: MessageChannel, id: String)?

    func incomingId(on channel: MessageChannel) -> String? {
        incoming.flatMap { $0.channel == channel ? $0.id : nil }
    }

    /// A text of yours went to this thread: replying to it (or within its reply thread) continues the thread too.
    func linkIncoming(_ id: String, on channel: MessageChannel, to target: ReplyTarget) {
        switch channel {
        case .photon: rememberPhotonMessage(id, target: target)
        case .telegram: if let n = Int64(id) { rememberTelegramMessage(n, target: target) }
        case .imessage, .webhook: break
        }
    }

    /// Answer the text being handled, as a reply to it.
    private func answer(_ text: String, on channel: MessageChannel) {
        var m = OutgoingMessage(text: text)
        if let id = incomingId(on: channel) { m.inReplyTo[channel] = id }
        send(m, via: [channel])
    }

    /// Texts held during quiet hours.
    @ObservationIgnored private var held: [(OutgoingMessage, [MessageChannel]?)] = []
    var heldCount: Int { held.count }

    /// Send what was held overnight, once quiet hours are over (called every 30 seconds).
    func flushHeld() {
        guard !held.isEmpty, !settings.isQuiet() else { return }
        // Approvals you've already answered in the app overnight don't need texting.
        let messages = held.filter { m, _ in
            guard let a = m.approval else { return true }
            return model.runs.first { $0.id == a.runId }?.status == .needsApproval
        }
        held = []
        guard !messages.isEmpty else { return }
        let n = messages.count
        send(OutgoingMessage(text: "🌅 \(n) update\(n == 1 ? "" : "s") from overnight:"))
        for (m, channels) in messages {
            var m = m
            m.unsolicited = false
            send(m, via: channels)
        }
    }

    func isAwaitingApproval(on channel: MessageChannel) -> Bool { awaitingApproval.contains(channel) }
    func markAwaitingApproval(on channel: MessageChannel) { awaitingApproval.insert(channel) }
    func clearAwaitingApproval(on channel: MessageChannel) { awaitingApproval.remove(channel) }

    /// A test message from Settings.
    func sendTest(_ channel: MessageChannel) {
        lastError = nil
        let keyword = settings.imessageKeyword.trimmingCharacters(in: .whitespaces)
        let help = channel == .imessage && !keyword.isEmpty ? "\(keyword) help" : "help"
        send("👋 Automate is connected. Reply \"\(help)\" to see what you can do from here.", via: [channel])
    }

    private func sendTelegram(_ message: OutgoingMessage) {
        guard let chat = settings.telegramChatId else { return }
        let client = TelegramClient(token: telegramToken)
        var text = message.text
        var keyboard: TelegramClient.Keyboard?
        if let a = message.approval {
            keyboard = [[("✅ Approve", "approve:\(a.runId.uuidString)"), ("⏭ Skip", "skip:\(a.runId.uuidString)")]]
            text += "\n\nTo approve with a note, reply: approve \(a.number) <note>"
        }
        // Formatted when it fits in one message; plain text otherwise, or if Telegram rejects the formatting.
        var html: String?
        if let md = message.markdown {
            var h = TelegramHTML.from(markdown: md)
            if let a = message.approval { h += "\n\n<i>To approve with a note, reply: approve \(a.number) &lt;note&gt;</i>" }
            if h.utf16.count <= 3900 { html = h }
        }
        let replyTo = message.inReplyTo[.telegram].flatMap { Int64($0) }
        Task { [weak self] in
            do {
                var id: Int64?
                if let html {
                    do {
                        id = try await client.sendMessage(chatId: chat, text: html, keyboard: keyboard, html: true, replyTo: replyTo)
                    } catch let e as TelegramClient.APIError where e.description.localizedCaseInsensitiveContains("parse entities") {
                        id = nil // Telegram didn't like the formatting: send it plain (below)
                    }
                    if id == nil { id = try await client.sendMessage(chatId: chat, text: text, keyboard: keyboard, replyTo: replyTo) }
                } else {
                    id = try await client.sendMessage(chatId: chat, text: text, keyboard: keyboard, replyTo: replyTo)
                }
                if let a = message.approval, let id { self?.approvalMessages[a.runId] = (chat, id) }
                if let target = message.replyTarget, let id { self?.rememberTelegramMessage(id, target: target) }
            } catch {
                self?.lastError = "Telegram: \(error.localizedDescription)"
            }
        }
    }

    @ObservationIgnored private var cachedWebhook: String?
    /// Kept with the bot token: Discord and Slack webhook URLs contain a secret.
    var webhookURL: String {
        get {
            if let cachedWebhook { return cachedWebhook }
            let v = Secrets.get("webhookURL")
            cachedWebhook = v
            return v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Secrets.set("webhookURL", v)
            cachedWebhook = v
        }
    }

    private func sendWebhook(_ message: OutgoingMessage) {
        guard let hook = Webhook(webhookURL) else { return }
        var lines = message.text.components(separatedBy: "\n")
        let title = lines.removeFirst()
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = message.approval {
            body += "\n\nApprove or skip #\(a.number) in Automate, or by text if Telegram/iMessage is set up."
        }
        Task { [weak self] in
            if let err = await hook.send(title: title, body: body) { self?.lastError = "Webhook: \(err)" }
        }
    }

    private func sendIMessage(_ message: OutgoingMessage) {
        let handle = settings.imessageHandle.trimmingCharacters(in: .whitespaces)
        let keyword = settings.imessageKeyword.trimmingCharacters(in: .whitespaces)
        let say = keyword.isEmpty ? "" : keyword + " "
        var text = RemoteText.clip(message.text, limit: 1800)
        if let a = message.approval {
            text += "\n\nSwipe to reply \"yes\" or \"no\" (or with a note), or send \"\(say)approve \(a.number)\" / \"\(say)skip \(a.number)\"."
        }
        // Never let Automate's own text look like a message to it when it shows up in your chat.
        text = MessageKeyword.guardOutgoing(text, keyword: keyword)
        recentlySent.append((text, Date()))
        recentlySent.removeAll { Date().timeIntervalSince($0.date) > 600 }
        if let target = message.replyTarget {
            pendingIMessageTargets.append((text, target, Date()))
            pendingIMessageTargets.removeAll { Date().timeIntervalSince($0.date) > 600 }
        }
        Task { [weak self] in
            if let err = await IMessage.send(text, to: handle) { self?.lastError = "iMessage: \(err)" }
        }
    }

    // MARK: - Photon

    /// Photon project credentials, kept with the bot token in secrets.json.
    var photonProjectId: String {
        get { Secrets.get("photonProjectId") }
        set { Secrets.set("photonProjectId", newValue.trimmingCharacters(in: .whitespacesAndNewlines)); cachedPhoton = nil }
    }
    var photonSecret: String {
        get { Secrets.get("photonSecret") }
        set { Secrets.set("photonSecret", newValue.trimmingCharacters(in: .whitespacesAndNewlines)); cachedPhoton = nil }
    }

    @ObservationIgnored private var cachedPhoton: PhotonClient?
    /// One client while the credentials stay the same, so its access token is reused.
    var photonClient: PhotonClient? {
        if let cachedPhoton { return cachedPhoton }
        let id = photonProjectId, secret = photonSecret
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        let c = PhotonClient(projectId: id, secret: secret)
        cachedPhoton = c
        return c
    }

    /// The chat with your number, looked up once per (re)start.
    @ObservationIgnored private var photonChat: String?
    /// Sends go one after another, so "On it…" and the answer (or the overnight batch) arrive in order.
    @ObservationIgnored private var photonSendChain: Task<Void, Never>?
    /// Guids of texts Automate sent, so they're never read back as yours even if Photon misflags one.
    @ObservationIgnored private var photonSent: [String] = []

    private func photonChatGuid(_ client: PhotonClient) async throws -> String {
        if let photonChat { return photonChat }
        let guid = try await client.chatGuid(for: PhotonClient.address(from: settings.photonAddress))
        photonChat = guid
        return guid
    }

    private func sendPhoton(_ message: OutgoingMessage) {
        guard let client = photonClient else { return }
        var text = RemoteText.clip(message.text, limit: 1800)
        if let a = message.approval {
            text += "\n\nSwipe to reply \"yes\" or \"no\" (or with a note), or send \"approve \(a.number)\" / \"skip \(a.number)\"."
        }
        let previous = photonSendChain
        photonSendChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let chat = try await self.photonChatGuid(client)
                let guid: String?
                if let replyTo = message.inReplyTo[.photon] {
                    // If Photon won't send it as a reply (e.g. that text is gone), send it plain rather than lose it.
                    do { guid = try await client.sendText(text, chatGuid: chat, replyTo: replyTo) }
                    catch let e as PhotonClient.APIError where !e.isUnauthorized {
                        guid = try await client.sendText(text, chatGuid: chat)
                    }
                } else {
                    guid = try await client.sendText(text, chatGuid: chat)
                }
                if let guid, !guid.isEmpty {
                    self.photonSent.append(guid)
                    if self.photonSent.count > 100 { self.photonSent.removeFirst() }
                }
                if let target = message.replyTarget, let guid, !guid.isEmpty { self.rememberPhotonMessage(guid, target: target) }
            } catch {
                self.lastError = "Photon: \(error.localizedDescription)"
            }
        }
    }

    /// Photon message guid → what it was about, for the last 200 run/thread texts (swipe-reply to one to answer it).
    @ObservationIgnored private var photonTargets: [String: (target: ReplyTarget, date: Date)] = {
        guard let d = AppDefaults.shared.dictionary(forKey: "photonReplyTargets") as? [String: [String: Any]] else { return [:] }
        return d.compactMapValues { v in
            guard let t = (v["target"] as? String).flatMap(ReplyTarget.init(stored:)), let date = v["date"] as? Date else { return nil }
            return (t, date)
        }
    }()

    private func rememberPhotonMessage(_ guid: String, target: ReplyTarget) {
        photonTargets[guid] = (target, Date())
        if photonTargets.count > 200 {
            for (key, _) in photonTargets.sorted(by: { $0.value.date < $1.value.date }).prefix(photonTargets.count - 200) {
                photonTargets[key] = nil
            }
        }
        AppDefaults.shared.set(photonTargets.mapValues { ["target": $0.target.stored, "date": $0.date] as [String: Any] },
                               forKey: "photonReplyTargets")
    }

    private func runPhoton(client: PhotonClient, address: String) async {
        var delay: Double = 2
        while !Task.isCancelled {
            do {
                let chat = try await photonChatGuid(client)
                let events = try await client.events(chatGuid: chat)
                if Task.isCancelled { return }
                photonConnected = true
                photonStatus = "Connected: texting \(address)"
                delay = 2
                for try await event in events {
                    if Task.isCancelled { return } // a restarted listener takes over from here
                    // Only your texts in your chat; Automate's own come back as "from me".
                    guard case let .message(m) = event, !m.isFromMe, !photonSent.contains(m.guid) else { continue }
                    handlePhoton(m)
                }
                // The server ends streams now and then; reconnect right away.
            } catch {
                if Task.isCancelled { return }
                photonConnected = false
                if let e = error as? PhotonClient.APIError, e.isUnauthorized {
                    photonStatus = "Photon rejected the project id/secret."
                    return
                }
                photonStatus = "Reconnecting… (\(error.localizedDescription))"
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    /// Photon's line is a chat of its own, so every message in it is for Automate: no keyword.
    func handlePhoton(_ m: PhotonClient.Incoming) {
        record(.init(channel: .photon, incoming: true, text: m.text))
        incoming = m.guid.isEmpty ? nil : (.photon, m.guid)
        defer { incoming = nil }
        if let target = m.replyTo.flatMap({ photonTargets[$0]?.target }), !m.text.hasPrefix("/") {
            if let reply = handleReply(to: target, text: m.text, channel: .photon) { answer(reply, on: .photon) }
            return
        }
        if let reply = model.handleRemote(m.text, from: .photon) { answer(reply, on: .photon) }
    }

    /// Telegram message id → what it was about, for the last 200 run/thread texts (swipe-reply to one to answer it).
    @ObservationIgnored private var telegramTargets: [Int64: ReplyTarget] = {
        guard let d = AppDefaults.shared.dictionary(forKey: "telegramRunMessages") as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Int64(k).flatMap { id in ReplyTarget(stored: v).map { (id, $0) } } })
    }()

    private func rememberTelegramMessage(_ messageId: Int64, target: ReplyTarget) {
        telegramTargets[messageId] = target
        if telegramTargets.count > 200 {
            for key in telegramTargets.keys.sorted().prefix(telegramTargets.count - 200) { telegramTargets[key] = nil }
        }
        AppDefaults.shared.set(Dictionary(uniqueKeysWithValues: telegramTargets.map { (String($0.key), $0.value.stored) }),
                               forKey: "telegramRunMessages")
    }

    /// iMessage guid → what it was about. Messages.app gives no id when we send, so texts we sent wait in
    /// `pendingIMessageTargets` until they show up in chat.db, where they're matched by text.
    @ObservationIgnored private var imessageTargets: [String: (target: ReplyTarget, date: Date)] = {
        guard let d = AppDefaults.shared.dictionary(forKey: "imessageReplyTargets") as? [String: [String: Any]] else { return [:] }
        return d.compactMapValues { v in
            guard let t = (v["target"] as? String).flatMap(ReplyTarget.init(stored:)), let date = v["date"] as? Date else { return nil }
            return (t, date)
        }
    }()
    @ObservationIgnored private var pendingIMessageTargets: [(text: String, target: ReplyTarget, date: Date)] = []

    private func rememberIMessage(guid: String, target: ReplyTarget) {
        imessageTargets[guid] = (target, Date())
        if imessageTargets.count > 200 {
            for (key, _) in imessageTargets.sorted(by: { $0.value.date < $1.value.date }).prefix(imessageTargets.count - 200) {
                imessageTargets[key] = nil
            }
        }
        AppDefaults.shared.set(imessageTargets.mapValues { ["target": $0.target.stored, "date": $0.date] as [String: Any] },
                               forKey: "imessageReplyTargets")
    }

    /// A swipe-reply to one of Automate's texts. On an approval request, "ok"/"no" answer that request (never another
    /// one); anything else, and replies to results, ask about the run in its session. Replies to a thread continue it.
    private func handleReply(to target: ReplyTarget, text: String, channel: MessageChannel) -> String? {
        // Only Telegram shows "typing…"; elsewhere, say we got it.
        func followUp(_ runId: UUID) -> String? {
            model.followUp(onRun: runId, message: text, replyVia: channel) ?? (channel == .telegram ? nil : "💭 On it…")
        }
        switch target {
        case .thread(let threadId):
            return model.replyInThread(threadId, message: text, from: channel)
        case .run(let runId):
            guard model.runs.first(where: { $0.id == runId })?.status == .needsApproval else { return followUp(runId) }
            clearAwaitingApproval(on: channel)
            switch RemoteCommand.parse(text, expectingApproval: true) {
            case let .approve(nil, note): return model.remoteApprove(runId: runId, note: note)
            case .skip(nil): return model.remoteSkip(runId: runId)
            default: return followUp(runId)
            }
        }
    }

    /// Once a run is approved or skipped (here or in the app), take the buttons off its Telegram message.
    func approvalResolved(runId: UUID, label: String) {
        guard let m = approvalMessages.removeValue(forKey: runId) else { return }
        let client = TelegramClient(token: telegramToken)
        Task { await client.setButtons(chatId: m.chat, messageId: m.message, keyboard: [[(label, "noop")]]) }
    }

    /// "typing…" on Telegram while Claude works on something you sent from there.
    func startTyping(for threadId: UUID) {
        guard activeChannels.contains(.telegram), let chat = settings.telegramChatId else { return }
        let client = TelegramClient(token: telegramToken)
        typingTasks[threadId]?.cancel()
        typingTasks[threadId] = Task {
            for _ in 0..<720 where !Task.isCancelled { // gives up after an hour
                await client.sendTyping(chatId: chat)
                try? await Task.sleep(for: .seconds(4.5))
            }
        }
    }

    func stopTyping(for threadId: UUID) {
        typingTasks.removeValue(forKey: threadId)?.cancel()
    }

    // MARK: - Telegram

    private func runTelegram(token: String) async {
        let client = TelegramClient(token: token)
        var delay: Double = 2
        // Find out who the bot is (also checks the token).
        while !Task.isCancelled {
            do {
                let bot = try await client.getMe()
                if model.settings.messaging.telegramBotName != bot.username {
                    model.settings.messaging.telegramBotName = bot.username
                }
                await client.setCommands([
                    ("status", "What's waiting and running"), ("loops", "List loops"), ("skills", "List skills"), ("threads", "Recent threads"),
                    ("new", "Start a new research thread"), ("stop", "Stop the current reply"), ("help", "All commands"),
                ])
                break
            } catch let e as TelegramClient.APIError where e.isUnauthorized {
                telegramStatus = "Telegram rejected the bot token. Check it in @BotFather."
                telegramConnected = false
                return
            } catch {
                telegramStatus = "Can't reach Telegram, retrying… (\(error.localizedDescription))"
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 120)
            }
        }
        updateTelegramStatus()

        delay = 2
        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(offset: telegramOffset)
                if Task.isCancelled { return } // a restarted poller takes over from here
                if !telegramConnected { updateTelegramStatus() }
                delay = 2
                for u in updates where u.updateId >= telegramOffset {
                    // Save first: if handling one crashes the app, it isn't handled again on every launch.
                    telegramOffset = u.updateId + 1
                    AppDefaults.shared.set(Int(telegramOffset), forKey: "telegramOffset")
                    handleTelegram(u, client: client)
                }
            } catch {
                if Task.isCancelled { return }
                if let e = error as? TelegramClient.APIError, e.isUnauthorized {
                    telegramStatus = "Telegram rejected the bot token."
                    telegramConnected = false
                    return
                }
                telegramConnected = false
                telegramStatus = "Reconnecting… (\(error.localizedDescription))"
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    /// Photos and documents from your phone: saved to the attachments folder and handed to Claude with the caption.
    private func receiveFiles(_ files: [TelegramClient.File], caption: String, client: TelegramClient) {
        let dir = model.store.attachmentsDir
        Task { [weak self] in
            var paths: [String] = []
            for f in files {
                guard f.size <= 20_000_000 else {
                    self?.send("\(f.name) is over Telegram's 20 MB bot limit, so I couldn't get it.", via: [.telegram])
                    continue
                }
                do {
                    let data = try await client.download(f)
                    let safe = f.name.replacingOccurrences(of: "/", with: "-")
                    var url = dir.appendingPathComponent("telegram-\(safe)")
                    var n = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        url = dir.appendingPathComponent("telegram-\(n)-\(safe)")
                        n += 1
                    }
                    try data.write(to: url)
                    paths.append(url.path)
                } catch {
                    self?.send("Couldn't download \(f.name): \(error.localizedDescription)", via: [.telegram])
                }
            }
            guard let self, !paths.isEmpty else { return }
            let question = caption.isEmpty ? "Take a look at this." : caption
            let text = question + "\n\n" + paths.map { "Attached file: \($0)" }.joined(separator: "\n")
            // Always a message for Claude: a caption like "approve" shouldn't approve anything.
            if let reply = self.model.handleChat(text, from: .telegram) { self.send(reply, via: [.telegram]) }
        }
    }

    private func updateTelegramStatus() {
        let name = settings.telegramBotName.isEmpty ? "your bot" : "@\(settings.telegramBotName)"
        telegramConnected = true
        telegramStatus = settings.telegramChatId == nil ? "Connected to \(name). Pair your chat below."
                                                        : "Connected to \(name)"
    }

    private func handleTelegram(_ update: TelegramClient.Update, client: TelegramClient) {
        guard update.chatId != 0 else { return }
        let paired = settings.telegramChatId

        switch update.kind {
        case let .message(text, files):
            guard !text.isEmpty || !files.isEmpty else { return }
            if paired == nil {
                // Only someone who can see the code in Automate can pair. Private chats only (in a group, every
                // member could control the Mac), exact code only, and the code changes after a few wrong tries.
                guard update.chatType == "private" else { return }
                if Date().timeIntervalSince(pairingCodeDate) > 600 { refreshPairingCode() }
                var attempt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if attempt.lowercased().hasPrefix("/start") { attempt = String(attempt.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                if attempt == pairingCode {
                    model.settings.messaging.telegramChatId = update.chatId
                    refreshPairingCode()
                    updateTelegramStatus()
                    Task { _ = try? await client.sendMessage(chatId: update.chatId, text: "✅ Paired with Automate on your Mac.\n\n" + RemoteCommand.helpText) }
                } else {
                    wrongPairingTries += 1
                    if wrongPairingTries >= 5 { refreshPairingCode() }
                    if attempt.isEmpty || wrongPairingTries <= 2 {
                        Task { _ = try? await client.sendMessage(chatId: update.chatId, text: "Send the 8-digit pairing code from Automate → Settings → Messaging.") }
                    }
                }
                return
            }
            guard update.chatId == paired else { return } // a private bot: ignore everyone else
            record(.init(channel: .telegram, incoming: true,
                         text: text + (files.isEmpty ? "" : (text.isEmpty ? "" : "\n") + files.map { "📎 \($0.name)" }.joined(separator: "\n"))))
            if !files.isEmpty {
                receiveFiles(files, caption: text, client: client)
                return
            }
            incoming = update.messageId.map { (.telegram, String($0)) }
            defer { incoming = nil }
            // A swipe-reply to a loop's or thread's text is about that run or thread.
            if let replyTo = update.replyTo, let target = telegramTargets[replyTo], !text.hasPrefix("/") {
                if let reply = handleReply(to: target, text: text, channel: .telegram) { answer(reply, on: .telegram) }
                return
            }
            // Decide on buttons before handling: handling can change what's waiting.
            let buttons = model.remoteButtons(for: RemoteCommand.parse(text, expectingApproval: isAwaitingApproval(on: .telegram)))
            if let reply = model.handleRemote(text, from: .telegram) {
                if let buttons {
                    record(.init(channel: .telegram, incoming: false, text: reply))
                    Task { [weak self] in
                        do { _ = try await client.sendMessage(chatId: update.chatId, text: reply, keyboard: buttons, replyTo: update.messageId) }
                        catch { self?.lastError = "Telegram: \(error.localizedDescription)" }
                    }
                } else {
                    answer(reply, on: .telegram)
                }
            }

        case let .button(callbackId, data, messageId):
            guard update.chatId == paired else {
                Task { await client.answerButton(callbackId) }
                return
            }
            let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "run" {
                let answer = model.loops.first { $0.id == parts[1] }.map { model.remoteRun($0, from: .telegram) }
                    ?? "That loop is gone."
                Task { await client.answerButton(callbackId, text: String(answer.prefix(190))) }
                send(answer, via: [.telegram])
                return
            }
            guard parts.count == 2, let runId = UUID(uuidString: parts[1]) else {
                Task { await client.answerButton(callbackId) }
                return
            }
            if let messageId { approvalMessages[runId] = (update.chatId, messageId) }
            let answer: String
            switch parts[0] {
            case "approve": answer = model.remoteApprove(runId: runId, note: "")
            case "skip": answer = model.remoteSkip(runId: runId)
            default: answer = ""
            }
            Task { await client.answerButton(callbackId, text: answer.isEmpty ? nil : String(answer.prefix(190))) }
            if !answer.isEmpty { send(answer, via: [.telegram]) }
        }
    }

    // MARK: - iMessage

    private func runIMessage() async {
        let handle = settings.imessageHandle.trimmingCharacters(in: .whitespaces)
        var lastRow: Int64 = 0
        var selfChat = false
        // Start from the newest message so old texts aren't treated as commands.
        while !Task.isCancelled {
            do {
                lastRow = try await Task.detached { try IMessage.latestRowId() }.value
                let own = (try? await Task.detached { try IMessage.ownHandles() }.value) ?? []
                selfChat = own.contains { RemoteText.sameHandle($0, handle) }
                imessageNeedsFullDiskAccess = false
                imessageStatus = "Listening for replies from \(handle)" + (selfChat ? " (your own number)" : "")
                break
            } catch IMessage.ReadError.noAccess {
                imessageNeedsFullDiskAccess = true
                imessageStatus = "Sending works. To read your replies, give Automate Full Disk Access, then restart it."
                try? await Task.sleep(for: .seconds(15))
            } catch {
                imessageStatus = "Couldn't read Messages: \(error)"
                try? await Task.sleep(for: .seconds(30))
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let after = lastRow
            guard let batch = try? await Task.detached(operation: { try IMessage.messages(after: after, handle: handle) }).value
            else { continue }
            if Task.isCancelled { return }
            lastRow = max(lastRow, batch.lastRow)
            for m in batch.messages {
                // One of our texts arriving in chat.db: now we know its guid, so a swipe-reply to it can be placed.
                // (Texting yourself, it arrives twice with different guids; either may be the one replied to.)
                if !m.guid.isEmpty, let p = pendingIMessageTargets.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == m.text }) {
                    rememberIMessage(guid: m.guid, target: p.target)
                }
                // Talking to someone else: only their messages are commands, never what you send them.
                if !selfChat && m.isFromMe { continue }
                handleIMessage(m.text, selfChat: selfChat, replyTo: m.replyTo)
            }
        }
    }

    func handleIMessage(_ raw: String, selfChat: Bool, replyTo: String? = nil) {
        // With a keyword set, only "automate …" messages are for Automate; the rest of the chat is yours.
        // A swipe-reply to one of Automate's texts is for Automate, keyword or not.
        let keyword = settings.imessageKeyword.trimmingCharacters(in: .whitespaces)
        let target = replyTo.flatMap { imessageTargets[$0]?.target }
        guard let text = MessageKeyword.strip(raw, keyword: keyword) ?? (target != nil ? raw : nil) else { return }
        if selfChat {
            let now = Date()
            recentlySent.removeAll { now.timeIntervalSince($0.date) > 600 }
            recentlyHandled.removeAll { now.timeIntervalSince($0.date) > 8 }
            // Texting yourself, Automate's own texts come back, and each of yours can show up twice at once.
            if recentlySent.contains(where: { $0.text == raw }) { return }
            if recentlyHandled.contains(where: { $0.text == raw }) { return }
            recentlyHandled.append((raw, now))
        }
        record(.init(channel: .imessage, incoming: true, text: raw))
        if let target, !text.hasPrefix("/") {
            if let reply = handleReply(to: target, text: text, channel: .imessage) { send(reply, via: [.imessage]) }
            return
        }
        guard var reply = model.handleRemote(text, from: .imessage) else { return }
        if reply == RemoteCommand.helpText, !keyword.isEmpty {
            reply += "\n\nOn iMessage, start each message with \"\(keyword)\", e.g. \"\(keyword) status\"."
        }
        send(reply, via: [.imessage])
    }

    // MARK: - Log

    struct LogEntry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date = Date()
        var channel: MessageChannel
        var incoming: Bool
        var text: String
    }

    /// What was texted each way (last 300), for the Messages page.
    /// Loaded in restart(), not here: the hub is created inside AppModel's init, before AppModel.shared exists.
    private(set) var log: [LogEntry] = []
    @ObservationIgnored private var logLoaded = false

    private func loadLog() {
        guard !logLoaded else { return }
        logLoaded = true
        guard let data = try? Data(contentsOf: Self.logURL) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        log = ((try? d.decode([LogEntry].self, from: data)) ?? []) + log
    }

    private static var logURL: URL { AppModel.shared.store.root.appendingPathComponent("messages-log.json") }

    private func record(_ entry: LogEntry) {
        loadLog()
        log.append(entry)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(log) { try? data.write(to: Self.logURL, options: .atomic) }
    }

    #if DEBUG
    func debugRecord(_ channel: MessageChannel, incoming: Bool, _ text: String) {
        record(.init(channel: channel, incoming: incoming, text: text))
    }
    #endif

    func clearLog() {
        log = []
        try? FileManager.default.removeItem(at: Self.logURL)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
