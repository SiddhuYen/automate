import SwiftUI
import AutomateCore

/// Settings → Messaging: get loop results and approvals on your phone, and text Automate back.
struct MessagingSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var tokenLoaded = false
    @State private var handle = ""
    @State private var webhook = ""
    @State private var photonId = ""
    @State private var photonSecret = ""
    @State private var photonHandle = ""

    var body: some View {
        @Bindable var model = model
        let hub = model.messaging
        let m = model.settings.messaging

        Form {
            Section {
                Text("Get approvals and loop results as texts, and reply to approve, run loops, or chat with Claude from your phone. All of these are free.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Telegram") {
                Toggle("Use Telegram", isOn: $model.settings.messaging.telegramEnabled)
                    .onChange(of: m.telegramEnabled) { hub.restart() }
                if m.telegramEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. In Telegram, message **@BotFather**, send `/newbot`, and pick any name.")
                        Text("2. Paste the token it gives you here:")
                    }
                    .font(.callout)
                    HStack {
                        SecureField("Bot token", text: $token, prompt: Text("123456789:AA…"))
                            .onSubmit(saveToken)
                        Button("Save", action: saveToken)
                            .disabled(token.trimmingCharacters(in: .whitespaces) == hub.telegramToken)
                    }
                    StatusLine(text: hub.telegramStatus, ok: hub.telegramConnected)
                    if hub.telegramConnected {
                        if m.telegramChatId == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("3. Send your bot this pairing code: **\(hub.pairingCode)**")
                                if !m.telegramBotName.isEmpty,
                                   let url = URL(string: "https://t.me/\(m.telegramBotName)?start=\(hub.pairingCode)") {
                                    Link("Open @\(m.telegramBotName) in Telegram", destination: url)
                                }
                                Text("Only the chat that sends this code can control Automate. It changes every 10 minutes; this screen always shows the current one.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Label("Paired with your chat", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Color.green)
                                Spacer()
                                Button("Send Test") { hub.sendTest(.telegram) }
                                Button("Unpair") {
                                    model.settings.messaging.telegramChatId = nil
                                    hub.refreshPairingCode()
                                    hub.restart()
                                }
                            }
                        }
                    }
                }
            }

            Section("iMessage") {
                Toggle("Use iMessage", isOn: $model.settings.messaging.imessageEnabled)
                    .onChange(of: m.imessageEnabled) { hub.restart() }
                if m.imessageEnabled {
                    TextField("Text this number or Apple ID", text: $handle,
                              prompt: Text("+1 555 555 0100 or you@icloud.com"))
                        .onSubmit(applyHandle)
                    Toggle("Read my replies as commands", isOn: $model.settings.messaging.imessageCommands)
                        .onChange(of: m.imessageCommands) { hub.restart() }
                    if m.imessageCommands {
                        TextField("Keyword", text: $model.settings.messaging.imessageKeyword, prompt: Text("none: every message"))
                        Text(m.imessageKeyword.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Every message in this chat goes to Automate. If you text yourself, set a keyword so your own notes aren't treated as commands."
                             : "Only messages that start with \"\(m.imessageKeyword)\" are for Automate, e.g. \"\(m.imessageKeyword) status\" or \"\(m.imessageKeyword) what's on my calendar?\". Everything else in the chat is ignored, and Automate's own texts can never trigger it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    StatusLine(text: hub.imessageStatus, ok: !hub.imessageNeedsFullDiskAccess && hub.imessageStatus.hasPrefix("Listening"))
                    if hub.imessageNeedsFullDiskAccess {
                        HStack {
                            Button("Open Full Disk Access Settings") { MessagingHub.openFullDiskAccessSettings() }
                            Button("Show Automate in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                        }
                        Text("Add Automate to the list (drag it in from Finder), switch it on, then quit and reopen Automate. Messages keeps its history private, so Automate can't read your replies without this. Sending works either way.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Apply", action: applyHandle)
                            .disabled(handle.trimmingCharacters(in: .whitespaces) == m.imessageHandle)
                        Button("Send Test") { hub.sendTest(.imessage) }
                            .disabled(m.imessageHandle.trimmingCharacters(in: .whitespaces).isEmpty
                                      || handle.trimmingCharacters(in: .whitespaces) != m.imessageHandle)
                    }
                    Text("Messages.app sends from this Mac's Apple ID. The first text asks to let Automate control Messages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Photon (iMessage from Photon's line)") {
                Toggle("Use Photon", isOn: $model.settings.messaging.photonEnabled)
                    .onChange(of: m.photonEnabled) { hub.restart() }
                if m.photonEnabled {
                    Text("From your project's Settings on [app.photon.codes](https://app.photon.codes). Texts come from Photon's number, and every reply in that chat goes to Automate: no Messages.app, Full Disk Access or keyword.")
                        .font(.callout)
                    TextField("Project ID", text: $photonId)
                    SecureField("Project secret", text: $photonSecret)
                    TextField("Text this number", text: $photonHandle,
                              prompt: Text(m.imessageHandle.isEmpty ? "+1 555 555 0100" : "\(m.imessageHandle) (your iMessage number)"))
                    StatusLine(text: hub.photonStatus, ok: hub.photonConnected)
                    HStack {
                        Button("Save", action: savePhoton)
                            .disabled(photonId.trimmingCharacters(in: .whitespaces) == hub.photonProjectId
                                      && photonSecret.trimmingCharacters(in: .whitespaces) == hub.photonSecret
                                      && photonHandle.trimmingCharacters(in: .whitespaces) == m.photonHandle)
                        Button("Send Test") { hub.sendTest(.photon) }
                            .disabled(!hub.activeChannels.contains(.photon))
                    }
                    Text("On Photon's Free and Pro plans, add this number as a user of the project first, or texts fail with \"Target not allowed\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Webhook: Discord, Slack or ntfy (send only)") {
                Toggle("Use a webhook", isOn: $model.settings.messaging.webhookEnabled)
                if m.webhookEnabled {
                    HStack {
                        TextField("Webhook URL", text: $webhook, prompt: Text("https://ntfy.sh/your-topic or a Discord/Slack webhook"))
                            .onSubmit { hub.webhookURL = webhook }
                        Button("Save") { hub.webhookURL = webhook }
                            .disabled(webhook.trimmingCharacters(in: .whitespaces) == hub.webhookURL)
                        Button("Send Test") { hub.sendTest(.webhook) }
                            .disabled(Webhook(hub.webhookURL) == nil)
                    }
                    if let hook = Webhook(webhook) {
                        Text("Looks like \(hook.kind == .generic ? "a generic JSON webhook" : hook.kind.rawValue.capitalized).")
                            .font(.caption).foregroundStyle(.secondary)
                        if hook.url.scheme == "http" {
                            Text("This address isn't encrypted (http), so your messages could be read in transit. Use https if you can.")
                                .font(.caption).foregroundStyle(Color.orange)
                        }
                    } else if !webhook.isEmpty {
                        Text("That isn't a web address.").font(.caption).foregroundStyle(Color.orange)
                    }
                    HStack {
                        Text("Free phone notifications without an account: install the ntfy app, then use a hard-to-guess topic.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Make a Topic") {
                            webhook = "https://ntfy.sh/automate-" + UUID().uuidString.prefix(12).lowercased()
                        }
                        .controlSize(.small)
                    }
                    Text("Anyone who knows an ntfy topic can read it, so keep it secret. Webhooks only send; to approve or chat from your phone, use Telegram, iMessage or Photon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("What to send") {
                Toggle("Loops that need my approval", isOn: $model.settings.messaging.sendApprovals)
                Toggle("Loop results (follows each loop's notify setting)", isOn: $model.settings.messaging.sendLoopResults)
                Toggle("Thread replies when I've been away from the Mac for 5 minutes",
                       isOn: $model.settings.messaging.sendThreadsWhenAway)
                Toggle("Let me chat with Claude by text", isOn: $model.settings.messaging.allowRemoteChat)
                Toggle("A daily summary of what loops found", isOn: $model.settings.messaging.dailyDigest)
                if m.dailyDigest {
                    Picker("Send it at", selection: $model.settings.messaging.dailyDigestHour) {
                        ForEach(6..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    .fixedSize()
                }
                Toggle("Quiet hours (hold loop texts until morning)", isOn: $model.settings.messaging.quietHours)
                if m.quietHours {
                    HStack {
                        Picker("From", selection: $model.settings.messaging.quietStart) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        Picker("to", selection: $model.settings.messaging.quietEnd) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    }
                    Text("Replies to what you text still come right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Add `message: never` (or `always`) to a loop file to override for that loop. Chats from your phone go to a research thread; text \"threads\" and \"use 2\" to work in a project thread instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = hub.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Commands you can text") {
                Text(RemoteCommand.helpText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .modifier(SettingsFormStyle())
        .onAppear {
            if !tokenLoaded {
                token = hub.telegramToken
                handle = m.imessageHandle
                webhook = hub.webhookURL
                photonId = hub.photonProjectId
                photonSecret = hub.photonSecret
                photonHandle = m.photonHandle
                tokenLoaded = true
            }
        }
    }

    /// The number only takes effect on Apply, so a half-typed one is never texted.
    private func applyHandle() {
        model.settings.messaging.imessageHandle = handle.trimmingCharacters(in: .whitespaces)
        model.messaging.restart()
    }

    private func savePhoton() {
        let hub = model.messaging
        hub.photonProjectId = photonId
        hub.photonSecret = photonSecret
        model.settings.messaging.photonHandle = photonHandle.trimmingCharacters(in: .whitespaces)
        hub.restart()
    }

    private func saveToken() {
        let hub = model.messaging
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != hub.telegramToken {
            hub.telegramToken = trimmed
            // A different bot means a different chat.
            model.settings.messaging.telegramChatId = nil
            model.settings.messaging.telegramBotName = ""
            AppDefaults.shared.removeObject(forKey: "telegramOffset")
        }
        hub.restart()
    }
}

struct StatusLine: View {
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
