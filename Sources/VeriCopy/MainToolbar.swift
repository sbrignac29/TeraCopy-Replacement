import SwiftUI
import VeriCopyCore

// The main window's toolbar items. Each one observes exactly what it shows, so a job
// becoming ready or a run pausing updates its button without re-rendering the window.

/// Start Queue, or Stop Queue while a run is going.
struct QueueRunButton: View {
    @ObservedObject var queue: QueueViewModel
    /// Readiness belongs to the jobs, which the queue does not republish.
    @ObservedObject private var status = QueueStatusMonitor.shared

    var body: some View {
        if queue.queueActive {
            Button {
                queue.stopQueue()
            } label: {
                Label("Stop Queue", systemImage: "stop.fill")
            }
            .help("Cancel the current job and skip the rest of the queue")
        } else {
            Button {
                queue.startQueue()
            } label: {
                Label("Start Queue", systemImage: "play.fill")
            }
            .disabled(!status.hasReadyJobs)
            .help(status.hasReadyJobs
                  ? "Run every ready job, top to bottom"
                  : "No job is ready — each job needs files and a destination")
        }
    }
}

/// Pause or Resume for the job the queue is running, which may not be the selected one.
struct PauseResumeButton: View {
    @ObservedObject var job: TransferJob
    @ObservedObject var queue: QueueViewModel

    var body: some View {
        if job.state == .paused {
            Button {
                queue.resumeCurrent()
            } label: {
                // Start Queue shows Stop while a run goes, so this play symbol stands alone.
                Label("Resume Current Job", systemImage: "play.fill")
            }
            .help("Resume “\(job.name)”")
        } else {
            Button {
                queue.pauseCurrent()
            } label: {
                Label("Pause Current Job", systemImage: "pause.fill")
            }
            .help("Pause “\(job.name)”")
        }
    }
}

/// What happens once the queue finishes. One choice for the whole queue, shared with
/// Settings ▸ Energy and Queue ▸ When Queue Finishes. Its label says what is armed.
struct CompletionMenu: View {
    @AppStorage(PowerCoordinator.Key.completionAction) private var completionRaw = CompletionAction.nothing.rawValue

    var body: some View {
        let action = CompletionAction(rawValue: completionRaw) ?? .nothing
        Menu {
            Picker("When Queue Finishes", selection: $completionRaw) {
                ForEach(CompletionAction.allCases) { option in
                    Text(option.menuTitle).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(action.toolbarTitle, systemImage: action.symbolName)
                .labelStyle(.titleAndIcon)
        }
        .help("What happens when the queue finishes. Skipped if anything failed or you stopped the queue.")
    }
}

/// The selected job's main action: run it now, add it to the run that is going, or run it
/// again. Nothing while it runs; Pause and Cancel cover that.
struct JobToolbarAction: View {
    @ObservedObject var job: TransferJob
    @ObservedObject var queue: QueueViewModel

    var body: some View {
        switch job.state {
        case .draft:
            if queue.isHeldBack(job) {
                Button {
                    queue.addToQueue(job)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!job.isReady && job.scansInFlight == 0)
                .help(job.readinessNote ?? "Run this job in the current run, in list order")
            } else {
                Button {
                    queue.startQueue(startingWith: job, only: true)
                } label: {
                    Label(job.mode.startTitle, systemImage: job.mode.startSymbol)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!job.isReady || queue.queueActive)
                .help(job.readinessNote ?? (queue.queueActive
                      ? "Already queued: it runs once the jobs above it finish. Drag to reorder."
                      : "Run only this job now"))
            }
        case .running, .paused:
            EmptyView()
        case .finished:
            Button {
                queue.runAgain(job)
            } label: {
                Label("Run Again", systemImage: "arrow.counterclockwise")
            }
            .labelStyle(.titleAndIcon)
            .disabled(queue.queueActive)
        }
    }
}

/// File list or statistics for the selected job.
struct ViewModePicker: View {
    @AppStorage("detailViewMode") private var viewModeRaw = DetailViewMode.files.rawValue

    var body: some View {
        Picker("View", selection: $viewModeRaw) {
            // Named for VoiceOver; without a label it reads the symbol's own name
            // ("Xy Axis With A Trend Line").
            Image(systemName: "list.bullet")
                .accessibilityLabel("File List")
                .help("File list")
                .tag(DetailViewMode.files.rawValue)
            Image(systemName: "chart.xyaxis.line")
                .accessibilityLabel("Statistics")
                .help("Counters and speed graph")
                .tag(DetailViewMode.stats.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch between the file list and the live statistics view")
    }
}
