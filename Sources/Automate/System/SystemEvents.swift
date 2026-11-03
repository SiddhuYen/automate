import AppKit
import ServiceManagement
import AutomateCore

/// Watches for the Mac waking up and the screen unlocking.
@MainActor
final class SystemEvents {
    static let shared = SystemEvents()
    private var tokens: [NSObjectProtocol] = []

    func start(onWake: @escaping @MainActor () -> Void, onUnlock: @escaping @MainActor () -> Void) {
        guard tokens.isEmpty else { return }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        })
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onUnlock() }
        })
    }
}

/// "Open at login" via the system's login items.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}

/// Whether you seem to be away from the Mac (idle for 5+ minutes), for "text me when I'm away".
enum UserPresence {
    static var isAway: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle > 5 * 60
    }
}

/// Preferences. A copy run with AUTOMATE_DATA_DIR (development) keeps its own, so it can't change the real app's
/// settings, Telegram pairing or approval numbers.
enum AppDefaults {
    nonisolated(unsafe) static let shared: UserDefaults = {
        guard let dir = ProcessInfo.processInfo.environment["AUTOMATE_DATA_DIR"], !dir.isEmpty else { return .standard }
        let suite = "automate-dev-" + ProjectMemory.fileName(name: "data", path: dir).replacingOccurrences(of: ".md", with: "")
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}
