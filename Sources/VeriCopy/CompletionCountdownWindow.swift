import AppKit
import SwiftUI
import VeriCopyCore

/// The floating countdown shown before VeriCopy sleeps the Mac or quits.
///
/// Deliberately an `NSPanel` rather than a SwiftUI `.alert` or a notification:
/// - The app can be running with **no windows at all** (close the main window mid-queue and
///   choose "Continue Queue", or run purely from the menu-bar item) — a `.alert` attached to
///   `ContentView` could never present in that state.
/// - A `UNUserNotification` can be silently suppressed by Focus/Do Not Disturb, or by the
///   user having denied notification permission. You cannot hang a 30-second irreversible
///   action on a surface that might not appear.
@MainActor
final class CompletionCountdownWindow {
    private var panel: NSPanel?

    func show(queue: QueueViewModel) {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "VeriCopy"
        panel.level = .floating                       // above other apps
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The panel lives outside the SwiftUI scene tree, so the environment object injected
        // in VeriCopyApp isn't inherited — pass it explicitly.
        panel.contentView = NSHostingView(rootView: CompletionCountdownView().environmentObject(queue))
        panel.center()
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct CompletionCountdownView: View {
    @EnvironmentObject var queue: QueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pending = queue.pendingCompletion {
                HStack(spacing: 10) {
                    Image(systemName: pending.action == .quit ? "power" : "moon.zzz.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.headline)
                            .font(.headline)
                            .monospacedDigit()
                        Text("Transfer complete · \(pending.detail)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: pending.fraction)
                    .progressViewStyle(.linear)

                if let drive = pending.removableVolumeName {
                    Label("Wait until the Mac is asleep before disconnecting “\(drive)”.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack {
                    Button("Cancel") { queue.cancelPendingCompletion() }
                        .keyboardShortcut(.cancelAction) // Esc aborts
                    Spacer()
                    Button(pending.action == .quit ? "Quit Now" : "Sleep Now") {
                        queue.performPendingCompletionNow()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Transient: the countdown finished or was cancelled while the panel closes.
                Text("Finishing up…").foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 380, height: 210, alignment: .topLeading)
    }
}
