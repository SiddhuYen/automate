import SwiftUI
import AutomateCore

/// Help → Automate Help: shortcuts, text commands, and the loop file format in one place.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    static let shortcuts: [(String, String)] = [
        ("⌘K", "Go to any thread, loop or command"),
        ("⌃⌥Space", "Quick Ask, from any app"),
        ("⌘N", "New research thread"),
        ("⇧⌘O", "Add a project folder"),
        ("⇧⌘L", "New loop from a description"),
        ("⇧⌘I", "Continue a Claude Code session"),
        ("⌘1 / ⌘2", "Inbox / Activity"),
        ("⌘↩", "Send (or Return, if you turned that on)"),
        ("⌘.", "Stop Claude"),
        ("⌘S", "Save a loop or memory file"),
        ("⌘↩ on a run", "Approve it"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Shortcuts").tag(0)
                Text("Text Commands").tag(1)
                Text("Loop Files").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                Group {
                    switch tab {
                    case 0:
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            ForEach(Self.shortcuts, id: \.0) { key, what in
                                GridRow {
                                    Text(key).font(.body.monospaced()).foregroundStyle(.secondary)
                                    Text(what)
                                }
                            }
                        }
                    case 1:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Text these to your Telegram bot or by iMessage (Settings → Messaging).").foregroundStyle(.secondary)
                            Text(RemoteCommand.helpText).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    default:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Loops are markdown files in Automate's loops folder. The bar above a loop's editor sets the common options.")
                                .foregroundStyle(.secondary)
                            Text(LoopWriter.formatGuide).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 520)
    }
}
