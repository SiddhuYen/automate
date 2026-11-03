import Foundation
import UserNotifications

/// macOS notifications, with Approve / Skip buttons on loop runs that need you.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    enum Action: String {
        case open = "AUTOMATE_OPEN"
        case approve = "AUTOMATE_APPROVE"
        case skip = "AUTOMATE_SKIP"
        /// Typed reply: a message to the thread, or a note with an approval.
        case reply = "AUTOMATE_REPLY"
    }

    static let approvalCategory = "AUTOMATE_APPROVAL"
    static let infoCategory = "AUTOMATE_INFO"
    static let threadCategory = "AUTOMATE_THREAD"

    /// Called on the main actor with (action, runId or threadId, typed text for .reply).
    var handler: (@MainActor (Action, String, String) -> Void)?

    /// Notifications need a real .app bundle (build with scripts/build-app.sh, not `swift run`).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: Action.approve.rawValue, title: "Approve", options: [])
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: "Skip", options: [.destructive])
        let open = UNNotificationAction(identifier: Action.open.rawValue, title: "Open", options: [.foreground])
        let approveWithNote = UNTextInputNotificationAction(identifier: Action.reply.rawValue, title: "Approve with Note…",
                                                            options: [], textInputButtonTitle: "Approve",
                                                            textInputPlaceholder: "e.g. only the first two")
        let reply = UNTextInputNotificationAction(identifier: Action.reply.rawValue, title: "Reply…", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Claude")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, approveWithNote, skip, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.threadCategory, actions: [reply, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.infoCategory, actions: [reply, open],
                                   intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, targetId: String, needsApproval: Bool, isThread: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        content.sound = .default
        content.categoryIdentifier = needsApproval ? Self.approvalCategory : isThread ? Self.threadCategory : Self.infoCategory
        content.threadIdentifier = targetId
        content.userInfo = ["target": targetId]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// "On", "Off", "Not asked yet", or why it can't be known.
    func statusText() async -> String {
        guard available else { return "Needs the built app (not swift run)" }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return settings.alertSetting == .enabled ? "On" : "On, but banners are off"
        case .denied: return "Off. Loops can't reach you"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    // Show banners even when Automate is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = response.notification.request.content.userInfo["target"] as? String ?? ""
        let action: Action
        switch response.actionIdentifier {
        case Action.approve.rawValue: action = .approve
        case Action.skip.rawValue: action = .skip
        case Action.reply.rawValue: action = .reply
        default: action = .open
        }
        let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(action, target, typed) }
            completionHandler()
        }
    }
}
