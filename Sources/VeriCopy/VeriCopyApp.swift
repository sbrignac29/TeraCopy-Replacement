import AppKit
import SwiftUI
import UserNotifications

@main
struct VeriCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = QueueViewModel.shared

    var body: some Scene {
        WindowGroup("VeriCopy") {
            ContentView()
                .environmentObject(queue)
        }
        .defaultSize(width: 1100, height: 620)
        // Clamp the window's minimum size to the content's min frame so the fixed header and
        // footer (Copy button, etc.) can never be clipped by shrinking the window too far.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Job") {
                    QueueViewModel.shared.newJob()
                }
                .keyboardShortcut("n")

                Button("Add Files or Folders…") {
                    QueueViewModel.shared.selectedJob?.promptAddSources()
                }
                .keyboardShortcut("o")
                .disabled(!(QueueViewModel.shared.selectedJob?.isEditable ?? false))
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarPanel(queue: queue)
        } label: {
            MenuBarIcon(queue: queue)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCoordinator.shared.start()
        PowerCoordinator.shared.start()
        // Loads settings only — the FTP server never auto-starts.
        FTPCoordinator.shared.start()
        // The local API does start here: it is loopback-only and allowlist-gated, and a
        // dashboard that needed a button press after every launch would not be usable.
        APICoordinator.shared.start()
    }

    /// Always drop the keep-awake assertion and close the listening socket on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        FTPCoordinator.shared.shutdown()
        APICoordinator.shared.shutdown()
        PowerCoordinator.shared.shutdown()
    }

    /// Show completion banners even when VeriCopy is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Normally quitting with the last window is right — but the countdown panel can be the
    /// only window on screen. Without this guard, cancelling the countdown would close that
    /// panel and immediately quit the app, which is exactly what the user just declined.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        QueueViewModel.shared.pendingCompletion == nil
    }

    /// Guard against accidentally quitting while the queue is running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = QueueViewModel.shared
        guard queue.queueActive else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "The queue is still running"
        alert.informativeText = "Quitting now will stop the current job and skip the rest of the queue. Files already verified are safe; the file currently copying will be cleaned up."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Queue")
        alert.addButton(withTitle: "Quit Anyway")

        if alert.runModal() == .alertSecondButtonReturn {
            queue.stopQueue()
            return .terminateNow
        }
        return .terminateCancel
    }
}
