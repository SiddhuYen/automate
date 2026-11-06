import SwiftUI
import AutomateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshots.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if CommandLine.arguments.contains("--imessagetest") {
            SelfTest.runIMessageReader()
            SelfTest.imessageKeyword()
            exit(SelfTest.failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--telegramtest") {
            TelegramTest.run()
            return
        }
        if CommandLine.arguments.contains("--keytest") {
            KeyTest.run()
            return
        }
        if CommandLine.arguments.contains("--suggest") {
            SelfTest.suggest()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        if CommandLine.arguments.contains("--coordtest") {
            SelfTest.run(only: SelfTest.coordinator)
            return
        }
        #endif
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        AppModel.shared.bootstrap()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = AutomateURL.parse(url) else { continue }
            AppModel.shared.handle(action)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    // Closing the window keeps Automate running in the menu bar so loops keep firing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AutomateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Automate", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 580)
        }
        .commands { AutomateCommands(model: model) }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            // The count of runs waiting for you sits next to the icon, so it's visible without opening the menu.
            if model.inbox.isEmpty {
                Image(systemName: "circle.hexagongrid")
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "circle.hexagongrid.fill")
                    Text("\(model.inbox.count)")
                }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct AutomateCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Research Thread") { model.newThread(projectId: nil) }
                .keyboardShortcut("n")
            Button("Add Project…") { model.addProject() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Loop from Description…") { model.showLoopWizard = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Continue a Claude Code Session…") { model.showSessionImport = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Automate Help") { model.showHelp = true }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Go to…") { model.showPalette = true }
                .keyboardShortcut("k")
            Button("Inbox") { model.selection = .inbox }
                .keyboardShortcut("1")
            Button("Activity") { model.selection = .activity }
                .keyboardShortcut("2")
        }
    }
}
