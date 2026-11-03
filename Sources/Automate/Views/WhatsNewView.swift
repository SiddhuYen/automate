import SwiftUI

/// Shown once after updating to a new version: the highlights, with a button for each.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    static let version = "0.2"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's new in Automate \(Self.version)").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                item("message.fill", "Text Automate from your phone",
                     "Approve loops, run them, and chat with Claude over Telegram or iMessage. Free.",
                     "Set Up Messaging") { openSettings(); dismiss() }
                item("sparkle", "Quick Ask from anywhere",
                     "⌃⌥Space opens a box over any app; the answer streams right there.",
                     "Try It") { dismiss(); QuickAsk.shared.show() }
                item("wand.and.stars", "Loops that write and tune themselves",
                     "Describe a job and Claude writes the loop, or let it suggest loops from your recent work. Loops now learn from what you approve and skip.",
                     "New Loop…") { dismiss(); after { model.showLoopWizard = true } }
                item("arrow.triangle.branch", "Better for coding",
                     "Live replies, diffs, git status, each thread on its own branch, Continue in Terminal, and picking up Claude Code sessions from Terminal.",
                     nil, nil)
                item("questionmark.circle", "Everything else",
                     "⌘K to jump anywhere, Send Later, attachments, saved prompts, a usage meter, and more. ⌘? shows it all.",
                     "Open Help") { dismiss(); after { model.showHelp = true } }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    /// Another sheet can only open once this one has finished closing.
    private func after(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated(action) }
    }

    private func item(_ icon: String, _ title: String, _ text: String, _ button: String?, _ action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let button, let action {
                    Button(button, action: action).buttonStyle(.link)
                }
            }
        }
    }
}
