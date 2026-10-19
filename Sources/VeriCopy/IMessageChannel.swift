import Foundation
import VeriCopyCore

/// Sends a short text through the user's Messages app by driving it with AppleScript
/// (Apple Events). No account or stored credential — it uses whatever iMessage account
/// Messages is already signed into. Best-effort and fully isolated: all work runs off the
/// main actor, nothing is thrown, and a failure is reported at most once per session so a
/// misconfigured Messages setup can't spam alerts or affect a transfer.
final class IMessageChannel: NotificationChannel {
    let kind: NotificationChannelKind = .sms

    private let lock = NSLock()
    private var _recipient = ""
    private var reportedError = false

    /// Called (on the main actor) with a human-readable reason the first time a send fails.
    private let onError: @Sendable (String) -> Void

    init(onError: @escaping @Sendable (String) -> Void) {
        self.onError = onError
    }

    /// Phone number or Apple ID handle to text. Set from the main actor whenever settings change.
    var recipient: String {
        get { lock.withLock { _recipient } }
        set { lock.withLock { _recipient = newValue } }
    }

    func deliver(_ content: NotificationContent) async {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }

        // nil == success; a non-nil string is the failure reason.
        if let reason = await Self.send(message: content.shortText, to: to) {
            let shouldReport = lock.withLock { () -> Bool in
                if reportedError { return false }
                reportedError = true
                return true
            }
            if shouldReport {
                onError("Couldn't send the iMessage notification: \(reason)\n\nCheck the recipient in "
                        + "Settings and that Messages is signed in. You may also need to allow VeriCopy to "
                        + "control Messages in System Settings ▸ Privacy & Security ▸ Automation.")
            }
        } else {
            lock.withLock { reportedError = false }
        }
    }

    /// Fire a one-off test message; returns nil on success or a failure reason (used by the
    /// Settings button, which also surfaces the first Automation-permission prompt).
    static func sendTest(to recipient: String) async -> String? {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return "No recipient set." }
        return await send(message: "VeriCopy test message ✅ — notifications are working.", to: to)
    }

    // MARK: - AppleScript delivery

    /// Returns nil on success, or a human-readable failure reason.
    private static func send(message: String, to recipient: String) async -> String? {
        await withCheckedContinuation { continuation in
            // Off the main actor: a slow or hung Apple Event can never block the UI or the engine.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runScript(message: message, recipient: recipient))
            }
        }
    }

    private static func runScript(message: String, recipient: String) -> String? {
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escape(recipient))" of targetService
            send "\(escape(message))" to targetBuddy
        end tell
        """
        guard let apple = NSAppleScript(source: script) else {
            return "Could not build the Messages script."
        }
        var errorInfo: NSDictionary?
        apple.executeAndReturnError(&errorInfo)
        if let errorInfo, let reason = errorInfo[NSAppleScript.errorMessage] as? String {
            return reason
        }
        return nil
    }

    /// Escapes a string for embedding inside an AppleScript double-quoted literal.
    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
