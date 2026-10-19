import Foundation
import VeriCopyCore

/// A destination for a completion notification (desktop banner, iMessage, …).
/// Deliveries are best-effort: an implementation must never throw and must never block
/// the caller for long — a failure to notify can never affect a transfer.
protocol NotificationChannel: AnyObject {
    /// Stable identifier so a channel can be enabled/disabled or replaced.
    var kind: NotificationChannelKind { get }
    func deliver(_ content: NotificationContent) async
}

enum NotificationChannelKind: Equatable {
    case desktop
    case sms
}
