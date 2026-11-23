import SwiftUI
import VeriCopyCore

// The main window's toolbar items. Each one observes exactly what it shows, so a job
// becoming ready or a run pausing updates its button without re-rendering the window.

/// The queue's transport controls as one fixed group: a single play/pause button that follows
/// the run (Start Queue when idle, Pause while a job copies, Resume when it is paused) and
/// Stop Queue. Both are always present and grey out when they do not apply, so nothing in the
/// toolbar shifts when a run starts or ends. Cancel Current Job is in the Queue menu (⌘.).
struct QueueTransportControls: View {
    @ObservedObject var queue: QueueViewModel
    /// Readiness and the running job's state belong to the jobs, which the queue does not
    /// republish.
    @ObservedObject private var status = QueueStatusMonitor.shared

    var body: some View {
        ControlGroup {
            switch status.runningJobState {
            case .running:
                Button {
                    queue.pauseCurrent()
                } label: {
                    Label("Pause Current Job", systemImage: "pause.fill")
                }
                .help(jobHelp("Pause"))
            case .paused:
                Button {
                    queue.resumeCurrent()
                } label: {
                    Label("Resume Current Job", systemImage: "play.fill")
                }
                .help(jobHelp("Resume"))
            default:
                // Between jobs a run is still going, so there is nothing to start or pause.
                Button {
                    queue.startQueue()
                } label: {
                    Label("Start Queue", systemImage: "play.fill")
                }
                .disabled(queue.queueActive || !status.hasReadyJobs)
                .help(status.hasReadyJobs || queue.queueActive
                      ? "Start Queue: run every ready job, top to bottom"
                      : "Start Queue: no job is ready yet. Each job needs files and a destination.")
            }

            Button {
                queue.stopQueue()
            } label: {
                Label("Stop Queue", systemImage: "xmark")
            }
            .disabled(!queue.queueActive)
            .help(queue.queueActive
                  ? "Stop Queue: cancel the current job and skip the rest of the queue"
                  : "Stop Queue: the queue is not running")
        }
        .labelStyle(.iconOnly)
    }

    private func jobHelp(_ verb: String) -> String {
        guard let job = queue.currentJob, status.runningJobState != nil else {
            return "\(verb) Current Job: nothing is running"
        }
        return "\(verb) “\(job.name)”"
    }
}

/// What happens once the queue finishes. One choice for the whole queue, shared with
/// Settings ▸ Energy and Queue ▸ When Queue Finishes. Icon only: the symbol changes and takes
/// the accent color when something is armed, so a glance still tells you.
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
                .labelStyle(.iconOnly)
                .foregroundStyle(action == .nothing ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        }
        .menuIndicator(.hidden)
        .help(action == .nothing
              ? "When the queue finishes: do nothing. Click to sleep the Mac or quit VeriCopy afterwards."
              : "When the queue finishes: \(action.helpPhrase). Skipped if anything failed or you stopped the queue.")
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
