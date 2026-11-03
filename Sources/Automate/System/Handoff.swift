import AppKit
import AutomateCore

/// Taking a thread elsewhere: an interactive `claude` in Terminal, or the folder in your code editor.
enum Handoff {
    /// Opens Terminal running `claude --resume <session>` in the thread's folder. There you can answer the
    /// permission prompts Automate can't show. Uses a .command file, so no extra permissions are needed.
    static func continueInTerminal(sessionId: String, folder: URL, claude: String) -> String? {
        let script = """
        #!/bin/zsh -l
        cd \(shellQuote(folder.path)) || exit 1
        clear
        echo "Continuing your Automate thread. Answer permission prompts here; come back to Automate any time."
        exec \(shellQuote(claude)) --resume \(shellQuote(sessionId))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("automate-\(sessionId.prefix(8)).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return error.localizedDescription
        }
        NSWorkspace.shared.open(file)
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    struct Editor: Identifiable {
        let id: String   // bundle id
        let name: String
        let url: URL
    }

    /// Code editors that are installed, most common first.
    static let editors: [Editor] = {
        let known = [("com.microsoft.VSCode", "VS Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"),
                     ("dev.zed.Zed", "Zed"), ("com.exafunction.windsurf", "Windsurf"), ("com.apple.dt.Xcode", "Xcode"),
                     ("com.sublimetext.4", "Sublime Text"), ("com.jetbrains.intellij", "IntelliJ IDEA")]
        return known.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Editor(id: id, name: name, url: $0) }
        }
    }()

    static func open(_ items: [URL], in editor: Editor) {
        NSWorkspace.shared.open(items, withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
