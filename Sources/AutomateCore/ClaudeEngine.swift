import Foundation

/// Everything needed for one `claude -p` invocation.
public struct ClaudeRequest: Sendable {
    public var prompt: String
    public var cwd: URL
    public var resumeSessionId: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode?
    public var allowedTools: [String]
    public var disallowedTools: [String]
    public var appendSystemPrompt: String?
    public var addDirs: [URL]
    public var sessionName: String?
    /// Turn on Claude in Chrome (`--chrome`): browser tools that act in your real Chrome.
    public var chrome: Bool
    /// Stream Claude's text as it's written (`--include-partial-messages`).
    public var streamText: Bool
    /// Re-render the system prompt on every message instead of freezing it at the first one. Needed when it
    /// carries something that changes between messages, like project memory.
    public var freshSystemPrompt: Bool
    /// Limit the built-in tools (`--tools`); an empty list turns them all off. nil = the default set.
    public var tools: [String]?
    /// With `resumeSessionId`: continue from that conversation in a new session (`--fork-session`).
    public var forkSession: Bool
    /// Start a new session in its own git worktree and branch (`--worktree <name>`); ignored when resuming.
    public var worktree: String?

    public init(prompt: String, cwd: URL) {
        self.prompt = prompt
        self.cwd = cwd
        self.resumeSessionId = nil
        self.model = nil
        self.effort = nil
        self.permissionMode = nil
        self.allowedTools = []
        self.disallowedTools = []
        self.appendSystemPrompt = nil
        self.addDirs = []
        self.sessionName = nil
        self.chrome = false
        self.streamText = false
        self.freshSystemPrompt = false
        self.tools = nil
        self.forkSession = false
        self.worktree = nil
    }

    /// CLI arguments (not including the executable). The prompt is sent on stdin.
    public func arguments() -> [String] {
        // In -p mode nobody answers permission prompts: anything that would prompt is denied,
        // and the permission mode decides the rest.
        var args = ["-p", "--output-format", "stream-json", "--verbose"]
        if let id = resumeSessionId, !id.isEmpty {
            args += ["--resume", id]
            if forkSession { args.append("--fork-session") }
        }
        if let m = model, !m.isEmpty { args += ["--model", m] }
        if let e = effort, !e.isEmpty { args += ["--effort", e] }
        if let p = permissionMode { args += ["--permission-mode", p.rawValue] }
        if let tools { args += ["--tools", tools.joined(separator: ",")] }
        if !allowedTools.isEmpty { args += ["--allowed-tools", allowedTools.joined(separator: ",")] }
        if !disallowedTools.isEmpty { args += ["--disallowed-tools", disallowedTools.joined(separator: ",")] }
        if let s = appendSystemPrompt, !s.isEmpty { args += ["--append-system-prompt", s] }
        for dir in addDirs { args += ["--add-dir", dir.path] }
        if let n = sessionName, !n.isEmpty, resumeSessionId == nil { args += ["--name", n] }
        if let w = worktree, !w.isEmpty, resumeSessionId == nil { args += ["--worktree", w] }
        if chrome { args.append("--chrome") }
        if streamText { args.append("--include-partial-messages") }
        if freshSystemPrompt { args += ["--system-prompt-snapshot", "off"] }
        return args
    }
}

/// Where the `claude` binary lives and the PATH it needs (GUI apps don't inherit your shell PATH).
public struct ClaudeLocation: Codable, Sendable, Equatable {
    public var executable: String
    public var path: String

    public init(executable: String, path: String) {
        self.executable = executable
        self.path = path
    }
}

public enum ClaudeLocator {
    /// Ask your login+interactive zsh where `claude` is, so nvm/homebrew/~/.local setups all work.
    public static func locate() -> ClaudeLocation? {
        let marker = "__AUTOMATE__"
        let script = "printf '\(marker)%s\\n\(marker)%s\\n' \"$(command -v claude)\" \"$PATH\""
        if let out = run("/bin/zsh", ["-l", "-i", "-c", script]) {
            let lines = out.components(separatedBy: "\n").filter { $0.hasPrefix(marker) }
                .map { String($0.dropFirst(marker.count)) }
            if lines.count >= 2, !lines[0].isEmpty, FileManager.default.isExecutableFile(atPath: lines[0]) {
                return ClaudeLocation(executable: lines[0], path: lines[1])
            }
        }
        // Fallbacks for common install locations.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let defaultPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return ClaudeLocation(executable: c, path: defaultPath)
        }
        return nil
    }

    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // A slow or hanging shell config shouldn't block startup forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// A running `claude -p` process. Read `events`; call `cancel()` to stop it.
public final class ClaudeSession: @unchecked Sendable {
    public let events: AsyncStream<ClaudeEvent>
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    private var timedOutFlag = false

    /// Ignore SIGPIPE once per process, so a claude process that exits early can't kill the app.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private init(process: Process, events: AsyncStream<ClaudeEvent>) {
        self.process = process
        self.events = events
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        guard process.isRunning else { return }
        process.interrupt() // SIGINT, like pressing Ctrl-C
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }
        }
    }

    /// Stop immediately (SIGTERM), for when the app is quitting.
    public func terminateNow() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// True if the run was stopped because it hit its time limit (not by you).
    public var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOutFlag
    }

    fileprivate func markTimedOut() {
        lock.lock(); timedOutFlag = true; lock.unlock()
    }

    /// Start Claude Code. Uses whatever account the CLI is logged into (your Max subscription).
    public static func start(_ request: ClaudeRequest, location: ClaudeLocation,
                             timeout: TimeInterval? = nil) throws -> ClaudeSession {
        _ = ignoreSigpipe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.executable)
        process.arguments = request.arguments()
        process.currentDirectoryURL = request.cwd

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = location.path
        // Make sure a stray key in the app's environment doesn't override the subscription login.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var continuation: AsyncStream<ClaudeEvent>.Continuation!
        let stream = AsyncStream<ClaudeEvent> { continuation = $0 }
        let session = ClaudeSession(process: process, events: stream)
        let cont = continuation!

        try FileManager.default.createDirectory(at: request.cwd, withIntermediateDirectories: true)
        try process.run()

        // Send the prompt on stdin, then close it.
        let promptData = Data(request.prompt.utf8)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: promptData)
            try? stdin.fileHandleForWriting.close()
        }

        // Collect stderr for error reporting.
        let errBox = DataBox()
        stderr.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errBox.append(d) }
        }

        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak session] in
                if let s = session, process.isRunning {
                    s.markTimedOut()
                    cont.yield(.processError("Timed out after \(Int(timeout / 60)) min"))
                    s.cancel()
                }
            }
        }

        // Read stdout on this session's own thread with plain read(2). Not FileHandle.bytes: every AsyncBytes
        // in the app shares one actor that does blocking reads, so a quiet claude (thinking, or a background
        // server holding its pipe open) stalled every other session's reading. A stalled pipe fills up, and
        // the CLI drops whatever it still has buffered when it exits, so a turn with big tool results
        // (screenshots) lost its last events and ended as "claude exited with status 0".
        let reader = Thread {
            var sawResult = false
            func handle(_ bytes: ArraySlice<UInt8>) {
                for event in ClaudeEventParser.parse(line: String(decoding: bytes, as: UTF8.self)) {
                    if case .result = event { sawResult = true }
                    cont.yield(event)
                }
            }
            // Split on "\n" bytes only. (Line readers that also break on U+2028/U+2029 would cut events in
            // half: those can appear unescaped inside the CLI's JSON.)
            let fd = stdout.fileHandleForReading.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            var buffer: [UInt8] = []
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    cont.yield(.processError("Reading output failed: \(String(cString: strerror(errno)))"))
                    break
                }
                var start = 0
                while let nl = chunk[start..<n].firstIndex(of: 0x0A) {
                    if buffer.isEmpty {
                        handle(chunk[start..<nl])
                    } else {
                        buffer.append(contentsOf: chunk[start..<nl])
                        handle(buffer[...])
                        buffer.removeAll(keepingCapacity: true)
                    }
                    start = nl + 1
                }
                buffer.append(contentsOf: chunk[start..<n])
            }
            if !buffer.isEmpty { handle(buffer[...]) }
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            errBox.append(stderr.fileHandleForReading.readDataToEndOfFile())
            if !sawResult {
                let err = errBox.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if session.timedOut {
                    // already reported
                } else if session.wasCancelled {
                    cont.yield(.processError("Stopped."))
                } else {
                    let msg = err.isEmpty ? "claude exited with status \(process.terminationStatus)" : err
                    cont.yield(.processError(msg))
                }
            }
            cont.finish()
        }
        reader.name = "claude stdout"
        reader.start()
        return session
    }
}

/// Thread-safe byte accumulator.
final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Who `claude` is signed in as (`claude auth status --json`).
public struct ClaudeAuth: Equatable, Sendable {
    public var loggedIn: Bool
    /// "claude.ai" for a subscription; anything else (an API key, a cloud provider) is billed per use.
    public var method: String
    /// "max", "pro", …
    public var plan: String?

    public var usesSubscription: Bool { method == "claude.ai" }

    public static func parse(_ json: String) -> ClaudeAuth? {
        guard let start = json.firstIndex(of: "{"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(json[start...].utf8))) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        return ClaudeAuth(loggedIn: loggedIn, method: obj["authMethod"] as? String ?? "unknown",
                          plan: obj["subscriptionType"] as? String)
    }

    /// Runs `claude auth status`. Call off the main thread.
    public static func check(_ location: ClaudeLocation) -> ClaudeAuth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: location.executable)
        p.arguments = ["auth", "status", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = location.path
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}
