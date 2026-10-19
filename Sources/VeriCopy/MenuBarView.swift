import SwiftUI
import VeriCopyCore

/// The small icon VeriCopy shows in the menu bar: a static icon when idle, an animated
/// progress ring while a job is running or paused. Clicking it drops down `MenuBarPanel`.
struct MenuBarIcon: View {
    @ObservedObject var queue: QueueViewModel
    @ObservedObject private var ftp = FTPCoordinator.shared

    var body: some View {
        if let job = queue.currentJob, job.isActive {
            ZStack {
                ProgressRing(fraction: job.progressFraction, paused: job.state == .paused)
                    .frame(width: 16, height: 16)
            }
        } else if ftp.isRunning {
            // A listening network socket should never be invisible.
            Image(systemName: "antenna.radiowaves.left.and.right")
        } else {
            Image(systemName: menuBarIdleSymbol)
        }
    }

    /// SF Symbol reflecting the most recent result, so a glance at the idle icon tells you
    /// whether the last run needs attention.
    private var menuBarIdleSymbol: String {
        if let job = queue.jobs.last(where: { $0.state == .finished }), let summary = job.summary {
            if summary.failed > 0 || summary.fatalError != nil { return "exclamationmark.arrow.triangle.2.circlepath" }
        }
        return "arrow.triangle.2.circlepath.circle"
    }
}

/// A minimal progress ring drawn directly (no third-party dependency), sized for the menu bar.
private struct ProgressRing: View {
    let fraction: Double
    let paused: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 2)
                .opacity(0.25)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(paused ? 0.5 : 1)
        }
    }
}

/// The dropdown content when the menu-bar icon is clicked: current job progress, speed,
/// quick pause/resume/cancel, and a summary of the last completed job when idle.
struct MenuBarPanel: View {
    @ObservedObject var queue: QueueViewModel
    @ObservedObject private var ftp = FTPCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = queue.currentJob, job.isActive {
                activeJobSection(job)
            } else if let job = queue.jobs.last(where: { $0.state == .finished }) {
                lastResultSection(job)
            } else {
                Text("No transfers yet")
                    .foregroundStyle(.secondary)
            }

            if ftp.isRunning {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Receiving photos").fontWeight(.medium)
                        Spacer()
                    }
                    Text("\(ftp.advertisedAddress ?? "—")  ·  port \(ftp.listeningPort)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ftp.connectedClient.map { "Camera connected (\($0))" }
                         ?? "\(ftp.receivedFiles.count) received · waiting…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop Receiving") { ftp.stopReceiving() }
                        .controlSize(.small)
                }
            }

            if queue.jobs.contains(where: \.isReady), queue.currentJob == nil {
                Divider()
                Button {
                    queue.startQueue()
                } label: {
                    Label("Start Queue", systemImage: "play.fill")
                }
            }

            Divider()

            Button("Open VeriCopy") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }

            Button("Quit VeriCopy") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private func activeJobSection(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if job.state == .paused {
                    Text("Paused").font(.caption).foregroundStyle(.orange)
                } else if job.isVerificationPhase {
                    Text("Verifying").font(.caption).foregroundStyle(.blue)
                }
            }

            ProgressView(value: job.progressFraction)
                .progressViewStyle(.linear)

            HStack {
                Text(progressText(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if job.state == .running, job.speedBytesPerSecond > 1 {
                    Text("\(byteText(Int64(job.speedBytesPerSecond)))/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                if job.state == .paused {
                    Button {
                        queue.resumeCurrent()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        queue.pauseCurrent()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }
                Button(role: .destructive) {
                    queue.cancelCurrentJob()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func lastResultSection(_ job: TransferJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                resultIcon(job.summary)
                Text(job.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            if let summary = job.summary {
                Text(resultText(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultIcon(_ summary: TransferSummary?) -> some View {
        let (symbol, color): (String, Color) = {
            guard let summary else { return ("checkmark.circle.fill", .green) }
            if summary.failed > 0 || summary.fatalError != nil { return ("exclamationmark.triangle.fill", .yellow) }
            if summary.cancelled { return ("minus.circle.fill", .secondary) }
            return ("checkmark.circle.fill", .green)
        }()
        return Image(systemName: symbol).foregroundStyle(color)
    }

    private func resultText(_ summary: TransferSummary) -> String {
        if let fatal = summary.fatalError { return fatal }
        var parts = ["\(summary.succeeded) completed"]
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled { parts.append("cancelled") }
        return parts.joined(separator: " · ")
    }

    private func progressText(_ job: TransferJob) -> String {
        "\(byteText(job.progressDone)) of \(byteText(job.progressTotal))"
    }
}
