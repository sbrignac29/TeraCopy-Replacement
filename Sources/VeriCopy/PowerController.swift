import Foundation

/// The power effects the queue can trigger. Kept behind a protocol with an inert default
/// for two reasons: `QueueViewModel` compiles in the headless queue test without the
/// concrete IOKit/AppKit implementation, and — critically — the test suite can exercise
/// the full end-of-run state machine without ever actually sleeping the test machine.
///
/// Every method must be safe to call more than once, and none may throw: a power
/// operation failing can never be allowed to affect a transfer's result.
@MainActor
protocol PowerController: AnyObject {
    /// Hold "don't idle-sleep the system". Display sleep stays allowed. Idempotent.
    func beginKeepAwake(reason: String)
    /// Drop the hold. Idempotent — called from several exit paths.
    func endKeepAwake()
    /// Wake the display / reset the idle timer so a countdown panel is actually visible.
    func declareUserActivity()
    /// Sleep the Mac. Only ever called when a countdown elapses.
    func sleepSystem()
    /// Quit the app. Only ever called when a countdown elapses.
    func quitApp()
}

/// Does nothing. The default on `QueueViewModel`, mirroring how `notificationChannels`
/// defaults to empty so the headless test has no side effects.
@MainActor
final class InertPowerController: PowerController {
    func beginKeepAwake(reason: String) {}
    func endKeepAwake() {}
    func declareUserActivity() {}
    func sleepSystem() {}
    func quitApp() {}
}
