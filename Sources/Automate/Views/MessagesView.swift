import SwiftUI
import AutomateCore

/// Everything Automate texted you and you texted back, across Telegram, iMessage and webhooks.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var note = ""

    var body: some View {
        let hub = model.messaging
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Messages").font(.title3.weight(.semibold))
                    HStack(spacing: 12) {
                        if model.settings.messaging.telegramEnabled { StatusLine(text: "Telegram: " + hub.telegramStatus, ok: hub.telegramConnected) }
                        if model.settings.messaging.imessageEnabled { StatusLine(text: "iMessage: " + hub.imessageStatus, ok: hub.imessageStatus.hasPrefix("Listening")) }
                        if model.settings.messaging.photonEnabled { StatusLine(text: "Photon: " + hub.photonStatus, ok: hub.photonConnected) }
                        if hub.activeChannels.contains(.webhook) { StatusLine(text: "Webhook on", ok: true) }
                        if hub.heldCount > 0 { Label("\(hub.heldCount) held for quiet hours", systemImage: "moon").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                Button("Settings…") { openSettings() }
                Menu {
                    Button("Clear History", role: .destructive) { hub.clearLog() }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("More") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .padding(16)
            if let err = hub.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            if hub.log.isEmpty {
                ContentUnavailableView {
                    Label("No messages yet", systemImage: "message")
                } description: {
                    Text(hub.isAnyChannelOn ? "Texts to and from your phone show up here. Try texting \"status\"."
                                            : "Set up Telegram, iMessage or a webhook in Settings → Messaging.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(hub.log) { entry in MessageBubble(entry: entry).id(entry.id) }
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo(hub.log.last?.id, anchor: .bottom) }
                    .onChange(of: hub.log.count) { proxy.scrollTo(hub.log.last?.id, anchor: .bottom) }
                }
            }
            if hub.isAnyChannelOn {
                Divider()
                HStack {
                    TextField("Send yourself a note (goes to your phone)", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendNote)
                    Button("Send", action: sendNote).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
        }
    }

    private func sendNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.messaging.send(text)
        note = ""
    }
}

struct MessageBubble: View {
    let entry: MessagingHub.LogEntry

    var body: some View {
        HStack {
            if !entry.incoming { Spacer(minLength: 80) }
            VStack(alignment: entry.incoming ? .leading : .trailing, spacing: 3) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(entry.incoming ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12))
                Text("\(entry.incoming ? "From you" : "To you") · \(entry.channel.label) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if entry.incoming { Spacer(minLength: 80) }
        }
    }
}
