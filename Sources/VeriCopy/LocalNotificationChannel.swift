import Foundation
import UserNotifications
import VeriCopyCore

/// Posts a macOS banner + sound via UserNotifications. Best-effort: if the user hasn't
/// granted permission, or the notification daemon rejects it, the failure is swallowed —
/// a missed banner must never surface as an error or affect a transfer.
final class LocalNotificationChannel: NotificationChannel {
    let kind: NotificationChannelKind = .desktop

    func deliver(_ content: NotificationContent) async {
        let center = UNUserNotificationCenter.current()

        // Only post if we're actually allowed to; never trigger a prompt from here.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        note.sound = content.isFailure ? .defaultCritical : .default
        note.interruptionLevel = content.isFailure ? .timeSensitive : .active

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            // Swallow — a missed banner is never worth disrupting anything.
        }
    }

    // MARK: - Authorization helpers (called by the app at launch / from Settings)

    /// Requests permission if the user hasn't decided yet. Safe to call repeatedly.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
