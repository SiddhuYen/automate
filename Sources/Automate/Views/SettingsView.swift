import SwiftUI
import AutomateCore

struct SettingsView: View {
    @State private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            LoopSettingsView()
                .tabItem { Label("Loops", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.loops)
            MessagingSettingsView()
                .tabItem { Label("Messaging", systemImage: "message") }
                .tag(SettingsTab.messaging)
            AccessSettingsView(tab: $tab)
                .tabItem { Label("Access", systemImage: "lock.shield") }
                .tag(SettingsTab.access)
        }
        .frame(width: 580, height: 660)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var notificationStatus = "Checking…"

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Claude") {
                LabeledContent("Detected") {
                    if model.isLocatingClaude {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.detectedClaude?.executable ?? "Not found")
                            .textSelection(.enabled)
                            .foregroundStyle(model.detectedClaude == nil ? Color.red : Color.primary)
                    }
                }
                TextField("Path override", text: $model.settings.claudeExecutableOverride,
                          prompt: Text("Leave empty to auto-detect"))
                LabeledContent("Account") {
                    if let a = model.auth {
                        if !a.loggedIn {
                            Text("Not signed in").foregroundStyle(Color.red)
                        } else if a.usesSubscription {
                            Text("Signed in · \(a.plan.map { $0.capitalized + " plan" } ?? "subscription") (no per-use charges)")
                        } else {
                            Text("\(a.method): billed per use").foregroundStyle(Color.orange)
                        }
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                }
                Button("Detect Again") { model.locateClaude() }
                Text("Automate runs your logged-in Claude Code CLI, so everything uses your Claude subscription. In Terminal, run `claude` once and sign in with your Max account (`/login`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("New threads") {
                Picker("Model", selection: $model.settings.defaultModel) {
                    ForEach(ComposerView.models, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Effort", selection: $model.settings.defaultEffort) {
                    ForEach(ComposerView.efforts, id: \.self) { Text($0).tag($0) }
                }
                Picker("Permissions", selection: $model.settings.defaultPermission) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Notify when a thread finishes while Automate is in the background",
                       isOn: $model.settings.notifyWhenThreadFinishesInBackground)
                Toggle("Show replies word by word as Claude writes them", isOn: $model.settings.streamReplies)
                Toggle("Return sends (Shift-Return for a new line)", isOn: $model.settings.returnSends)
                Toggle("Let Claude set up loops and reminders when you ask in a thread", isOn: $model.settings.threadsCanMakeLoops)
                Toggle("New project threads work on their own git branch", isOn: $model.settings.worktreeByDefault)
                    .help("Each thread gets a git worktree under .claude/worktrees, so parallel threads never edit the same files.")
                Toggle("⌃⌥Space opens Quick Ask from any app", isOn: $model.settings.quickAskHotKey)
                    .onChange(of: model.settings.quickAskHotKey) { _, on in QuickAsk.shared.setEnabled(on) }
            }

            Section("About you") {
                TextEditor(text: $model.settings.customInstructions)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                Text("Standing instructions for every thread and loop, e.g. \"I'm a CS student. Keep answers short. Use Python unless I say otherwise.\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Status") {
                    Text(notificationStatus).foregroundStyle(notificationStatus.hasPrefix("On") ? Color.primary : Color.orange)
                }
                HStack {
                    Button("Send Test Notification") {
                        Notifier.shared.post(title: "Automate", body: "Notifications work. Loops will reach you here.",
                                             targetId: "", needsApproval: false)
                    }
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .task { notificationStatus = await Notifier.shared.statusText() }

            Section("Startup") {
                Toggle("Open Automate at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color.red)
                }
                Text("With this on, loops set to run on launch start when you log in. Automate also listens for wake and unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(SettingsFormStyle())
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.inbox.isEmpty {
            Text("Waiting for you")
            ForEach(model.inbox) { run in
                Menu("\(run.approvalNumber.map { "#\($0) " } ?? "")\(run.loopName)") {
                    Button("Approve") { model.approve(runId: run.id) }
                    Button("Skip") { model.skip(runId: run.id) }
                    Divider()
                    Button("View…") { open(.run(run.id)) }
                }
            }
            Divider()
        }
        Text(model.runningLoopCount == 0 ? "No loops running" : "\(model.runningLoopCount) loop(s) running")
        if model.runningLoopCount > 0 {
            Button("Stop All Loops") {
                for run in model.runs where run.status == .running { model.cancel(runId: run.id) }
            }
        }
        if !model.runningThreadIds.isEmpty {
            Text("\(model.runningThreadIds.count) thread(s) working")
        }
        if let week = model.usage.first(where: { $0.name == "seven_day" }) {
            Text("Usage: \(Int((week.utilization * 100).rounded()))% of 7-day limit")
        }
        if model.pausedUntil != nil {
            Button("Resume Loops") { model.pauseLoops(until: nil) }
        } else {
            Menu("Pause Loops") {
                Button("For 1 Hour") { model.pauseLoops(until: Date().addingTimeInterval(3600)) }
                Button("For 4 Hours") { model.pauseLoops(until: Date().addingTimeInterval(4 * 3600)) }
                Button("Until Tomorrow Morning") {
                    let cal = Calendar.current
                    let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
                    model.pauseLoops(until: cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow))
                }
                Button("Until I Resume") { model.pauseLoops(until: .distantFuture) }
            }
        }
        if let held = model.loopsHeldReason { Text(held) }
        Menu("Run Loop") {
            ForEach(model.loops) { loop in
                Button(loop.name) { model.runNow(loop) }
                    .disabled(model.isRunning(loopId: loop.id))
            }
        }
        Button("Quick Ask…  ⌃⌥Space") { QuickAsk.shared.show() }
        Button("New Research Thread") {
            model.newThread(projectId: nil)
            open(nil)
        }
        Divider()
        Button("Open Automate") { open(nil) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Automate") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ item: SidebarItem?) {
        if let item { model.selection = item }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Grouped forms, except in snapshots (grouped forms don't draw offscreen).
struct SettingsFormStyle: ViewModifier {
    @Environment(\.plainForms) private var plain
    func body(content: Content) -> some View {
        if plain { content.formStyle(.columns) } else { content.formStyle(.grouped) }
    }
}

private struct PlainFormsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var plainForms: Bool {
        get { self[PlainFormsKey.self] }
        set { self[PlainFormsKey.self] = newValue }
    }
}

struct LoopSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Loops") {
                Stepper("Run up to \(model.settings.maxConcurrentLoops) loops at once",
                        value: $model.settings.maxConcurrentLoops, in: 1...6)
                Picker("Hold loops when usage reaches", selection: $model.settings.usageGuardPercent) {
                    Text("Never").tag(0)
                    ForEach([75, 85, 90, 95], id: \.self) { Text("\($0)% of a limit").tag($0) }
                }
                Text("Saves what's left of your Claude limits for you. Run Now still works. Runs that came due while loops were held are skipped, not all run at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Loops Folder") { NSWorkspace.shared.open(model.store.loopsDir) }
                    Button("Open Data Folder") { NSWorkspace.shared.open(model.store.root) }
                    Button("Back Up Data…") { model.backUpData() }
                        .help("A zip of your loops, notes, threads, runs and memory (without your bot token)")
                }
            }

            Section("Links & Shortcuts") {
                Text("`automate://ask?text=…`, `automate://run/<loop>`, `automate://open/inbox` and `automate://quick-ask` work from Shortcuts, Raycast, Alfred or `open` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("automate://ask links send the message right away", isOn: $model.settings.urlsMaySend)
                Text("Off: a link opens a new thread with the message filled in, and you press Send. Keep it off unless you need hands-free Shortcuts, since any web page can open these links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .modifier(SettingsFormStyle())
    }
}
