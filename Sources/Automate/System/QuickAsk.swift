import AppKit
import Carbon.HIToolbox
import SwiftUI
import AutomateCore

/// ⌃⌥Space from anywhere: a small floating box to ask Claude something without finding the Automate window.
@MainActor
final class QuickAsk {
    static let shared = QuickAsk()
    private var panel: NSPanel?
    private var resizeObserver: NSObjectProtocol?
    private var topEdge: CGFloat?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickAsk.shared.toggle() } }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4155_544D), id: 1) // "AUTM"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    /// Text to start the box with (from the Services menu).
    var prefill: String?

    func show(prefill text: String? = nil) {
        prefill = text
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 150),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingController(rootView: QuickAskView().environment(AppModel.shared))
            host.sizingOptions = [.preferredContentSize] // the panel grows when an answer appears
            p.contentViewController = host
            // Grow downward, keeping the box where you're typing.
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard let top = QuickAsk.shared.topEdge, let panel = QuickAsk.shared.panel else { return }
                    if abs(panel.frame.maxY - top) > 0.5 { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height)) }
                }
            }
            panel = p
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.22 - panel.frame.height))
        }
        topEdge = panel.frame.maxY
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAskShown, object: nil)
    }

    func close() {
        panel?.orderOut(nil)
    }
}

extension Notification.Name {
    static let quickAskShown = Notification.Name("AutomateQuickAskShown")
}

struct QuickAskView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var projectId: UUID?
    /// The conversation shown in the panel (follow-ups continue it).
    @State private var threadId: UUID?
    @FocusState private var focused: Bool

    init(threadId: UUID? = nil) {
        _threadId = State(initialValue: threadId)
    }

    var body: some View {
        let thread = threadId.flatMap { id in model.threads.first { $0.id == id } }
        let running = threadId.map { model.runningThreadIds.contains($0) } ?? false

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.title2).foregroundStyle(Color.accentColor)
                TextField(thread == nil ? "Ask Claude…" : "Ask a follow-up…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { submit(background: false) }
                    .onKeyPress(.escape) { QuickAsk.shared.close(); return .handled }
            }
            if let thread {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Self.latestExchange(thread.items)) { item in
                                if item.kind == .user {
                                    Text(item.text).foregroundStyle(.secondary).lineLimit(3)
                                } else if item.kind == .assistant {
                                    MarkdownText(item.text)
                                } else if item.kind == .toolUse {
                                    Label(item.toolName ?? "Tool", systemImage: "wrench.and.screwdriver")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if item.kind == .error {
                                    Label(item.text, systemImage: "exclamationmark.triangle").foregroundStyle(Color.red)
                                }
                            }
                            if running {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 300)
                    .onChange(of: thread.items.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            HStack(spacing: 10) {
                if thread == nil {
                    Picker("In", selection: $projectId) {
                        Text("Research").tag(UUID?.none)
                        ForEach(model.projects) { p in Text(p.name).tag(UUID?.some(p.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("↩ ask here · ⌘↩ answer in a notification · esc close")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Open in Automate") {
                        if let threadId { model.selection = .thread(threadId) }
                        QuickAsk.shared.close()
                        model.showMainWindow()
                    }
                    Button("New Question") {
                        threadId = nil
                        focused = true
                    }
                    if running, let threadId {
                        Button("Stop") { model.stopThread(threadId) }
                    }
                }
                Spacer()
                Button("") { submit(background: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onReceive(NotificationCenter.default.publisher(for: .quickAskShown)) { _ in
            if let p = QuickAsk.shared.prefill {
                text = p
                threadId = nil
                QuickAsk.shared.prefill = nil
            }
            focused = true
        }
        .onAppear { focused = true }
    }

    /// Your latest question and everything after it.
    static func latestExchange(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard let i = items.lastIndex(where: { $0.kind == .user }) else { return items }
        return Array(items[i...])
    }

    private func submit(background: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        text = ""
        let id = threadId ?? model.createThread(projectId: projectId, select: false)
        model.send(message, in: id)
        if background {
            threadId = nil
            QuickAsk.shared.close()
            NSApp.hide(nil) // notifications only show while Automate isn't frontmost
        } else {
            threadId = id // the answer streams in right here
        }
    }
}

/// "Ask Automate" in the Services menu (select text in any app → right-click → Services), and
/// "Ask Automate about Files" for files selected in Finder.
final class ServiceProvider: NSObject {
    @objc func askAboutFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppModel.shared.startThread(withFiles: urls) }
        }
    }

    @objc func askAutomate(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let selection = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty else { return }
        let quoted = selection.count > 4000 ? String(selection.prefix(4000)) + "…" : selection
        DispatchQueue.main.async {
            MainActor.assumeIsolated { QuickAsk.shared.show(prefill: "\"\"\"\n\(quoted)\n\"\"\"\n\n") }
        }
    }
}
