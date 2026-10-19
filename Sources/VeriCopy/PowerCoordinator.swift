import Combine
import Foundation
import VeriCopyCore

/// Bridges the app's persisted power preferences (`@AppStorage` → `UserDefaults`) to the
/// `QueueViewModel`, installs the real `SystemPowerController`, and owns the countdown
/// panel. Same shape as `NotificationCoordinator`.
@MainActor
final class PowerCoordinator {
    static let shared = PowerCoordinator()

    // UserDefaults keys, shared with SettingsView's @AppStorage.
    enum Key {
        static let keepAwakeEnabled = "powerKeepAwakeEnabled"
        /// Deliberately the same key TransferJob uses for its per-job sticky default, so the
        /// Settings default and a new job's initial choice stay in agreement.
        static let completionAction = "powerCompletionAction"
        static let countdownSeconds = "powerCountdownSeconds"
        static let skipAfterFailures = "powerSkipAfterFailures"
    }

    private let controller = SystemPowerController()
    private let countdownWindow = CompletionCountdownWindow()
    private var observer: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    var isHoldingAwake: Bool { controller.isHoldingAwake }

    /// Called once at launch: install the real controller, sync settings, and start
    /// showing/hiding the countdown panel as a completion is armed or cancelled.
    func start() {
        QueueViewModel.shared.powerController = controller
        sync()

        QueueViewModel.shared.$pendingCompletion
            .removeDuplicates { ($0 == nil) == ($1 == nil) } // only care about nil ⇄ non-nil
            .sink { [weak self] pending in
                guard let self else { return }
                if pending != nil {
                    self.countdownWindow.show(queue: QueueViewModel.shared)
                } else {
                    self.countdownWindow.close()
                }
            }
            .store(in: &cancellables)

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PowerCoordinator.shared.sync() }
        }
    }

    /// Pull the latest preferences into the queue view model, then bring the keep-awake
    /// hold in line — so toggling the setting mid-transfer takes effect immediately.
    func sync() {
        let d = UserDefaults.standard
        var s = PowerSettings()
        // `bool(forKey:)` returns false for an unset key, so use the object form for
        // settings that default to ON.
        s.keepAwakeEnabled = d.object(forKey: Key.keepAwakeEnabled) as? Bool ?? true
        s.skipAfterFailures = d.object(forKey: Key.skipAfterFailures) as? Bool ?? true
        if let raw = d.string(forKey: Key.completionAction), let a = CompletionAction(rawValue: raw) {
            s.defaultCompletionAction = a
        }
        let seconds = d.integer(forKey: Key.countdownSeconds) // 0 when unset
        s.countdownSeconds = seconds > 0 ? seconds : 30

        QueueViewModel.shared.powerSettings = s
        QueueViewModel.shared.reconcileKeepAwake()
    }

    /// Release the keep-awake hold on app termination.
    func shutdown() {
        controller.endKeepAwake()
    }

    /// Settings button: prove the countdown panel actually reaches the user before they
    /// trust it with an overnight transfer. Harmless — it performs no action when it ends.
    func showTestCountdown() {
        QueueViewModel.shared.startTestCountdown(seconds: 10)
    }
}
