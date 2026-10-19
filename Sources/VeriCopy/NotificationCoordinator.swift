import Foundation
import VeriCopyCore

/// Bridges the app's persisted notification preferences (`@AppStorage` → `UserDefaults`)
/// to the `QueueViewModel` and the concrete channels. Keeps everything in sync as the user
/// edits Settings, and exposes the two "send a test" actions.
@MainActor
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    // UserDefaults keys, shared with SettingsView's @AppStorage.
    enum Key {
        static let desktopEnabled = "notifyDesktopEnabled"
        static let trigger = "notifyTrigger"
        static let onlyOnFailure = "notifyOnlyOnFailure"
        static let smsEnabled = "notifySMSEnabled"
        static let smsRecipient = "notifySMSRecipient"
    }

    private let local = LocalNotificationChannel()
    private lazy var imessage = IMessageChannel(onError: { reason in
        Task { @MainActor in QueueViewModel.shared.alertMessage = reason }
    })
    private var observer: NSObjectProtocol?

    /// Called once at launch: install channels, request desktop permission, sync settings.
    func start() {
        QueueViewModel.shared.notificationChannels = [local, imessage]
        LocalNotificationChannel.requestAuthorizationIfNeeded()
        sync()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in NotificationCoordinator.shared.sync() }
        }
    }

    /// Pull the latest preferences into the queue view model and the iMessage channel.
    func sync() {
        let d = UserDefaults.standard
        var s = NotificationSettings()
        s.desktopEnabled = d.object(forKey: Key.desktopEnabled) as? Bool ?? true
        if let raw = d.string(forKey: Key.trigger), let t = NotificationTrigger(rawValue: raw) {
            s.trigger = t
        }
        s.onlyOnFailure = d.bool(forKey: Key.onlyOnFailure)
        s.smsEnabled = d.bool(forKey: Key.smsEnabled)
        s.smsRecipient = d.string(forKey: Key.smsRecipient) ?? ""

        QueueViewModel.shared.notificationSettings = s
        imessage.recipient = s.smsRecipient
    }

    // MARK: - Test actions (Settings buttons)

    func sendTestDesktop() async {
        LocalNotificationChannel.requestAuthorizationIfNeeded()
        let content = NotificationContent(
            title: "VeriCopy test",
            body: "Desktop notifications are working. You'll get one of these when a copy finishes.",
            shortText: "VeriCopy test",
            isFailure: false
        )
        await local.deliver(content)
    }

    /// Returns nil on success, or a failure reason.
    func sendTestSMS(to recipient: String) async -> String? {
        await IMessageChannel.sendTest(to: recipient)
    }
}
