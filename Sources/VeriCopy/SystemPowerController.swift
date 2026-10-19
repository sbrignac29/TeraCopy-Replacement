import AppKit
import Foundation
import IOKit.pwr_mgt

/// The real power controller: an IOKit power assertion for keep-awake, and `pmset` for sleep.
///
/// Uses `kIOPMAssertionTypePreventUserIdleSystemSleep` only — deliberately NOT
/// `…PreventUserIdleDisplaySleep`. That makes this the equivalent of `caffeinate -i`:
/// the machine keeps working, but the screen is still free to turn off, which is what
/// you want for a long overnight transfer. It's also directly checkable:
///
///     pmset -g assertions | grep -i vericopy
///
/// should show exactly one `PreventUserIdleSystemSleep` line and no display-sleep line.
@MainActor
final class SystemPowerController: PowerController {

    private var assertionID: IOPMAssertionID = 0
    private var userActivityID: IOPMAssertionID = 0

    var isHoldingAwake: Bool { assertionID != 0 }

    func beginKeepAwake(reason: String) {
        guard assertionID == 0 else { return } // already held — keep it idempotent
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
        }
        // On failure we simply don't hold the assertion. A transfer must never be blocked
        // by power management, and `beginActivity` in QueueViewModel still applies.
    }

    func endKeepAwake() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    /// Wakes the display and resets the idle timer, so the countdown panel is visible.
    /// Needed precisely because we allow display sleep during the transfer.
    func declareUserActivity() {
        var newID = userActivityID
        let result = IOPMAssertionDeclareUserActivity(
            "VeriCopy transfer finished" as CFString,
            kIOPMUserActiveLocal,
            &newID
        )
        if result == kIOReturnSuccess {
            userActivityID = newID
        }
    }

    /// Sleeps the Mac via `pmset sleepnow`. Chosen over the AppleScript route because it
    /// requires no Apple Event and therefore triggers no automation permission prompt —
    /// which matters when the user has walked away and can't answer one.
    func sleepSystem() {
        endKeepAwake() // never sleep while still asserting keep-awake
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    Self.sleepViaAppleScriptFallback()
                }
            } catch {
                Self.sleepViaAppleScriptFallback()
            }
        }
    }

    /// Fallback only. This one *does* need a System Events automation grant — a separate
    /// TCC entry from the Messages one — so it's never the primary path.
    /// `nonisolated` because it runs on the background queue that invoked `pmset`.
    private nonisolated static func sleepViaAppleScriptFallback() {
        guard let script = NSAppleScript(source: "tell application \"System Events\" to sleep") else { return }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let reason = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            Task { @MainActor in
                QueueViewModel.shared.alertMessage =
                    "VeriCopy couldn't put the Mac to sleep: \(reason)\n\nYou may need to allow "
                    + "VeriCopy to control System Events in System Settings ▸ Privacy & Security ▸ Automation."
            }
        }
    }

    func quitApp() {
        endKeepAwake()
        NSApp.terminate(nil)
    }

    deinit {
        // Last-ditch release. IOKit also reclaims assertions when the process dies, so a
        // crash can't strand one system-wide — unlike a detached `caffeinate` subprocess.
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
