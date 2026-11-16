import Combine
import SwiftUI
import VeriCopyCore

// MARK: - Queue-wide state for the menus and toolbar

/// Queue facts that live on the jobs rather than the queue, republished in one place: whether
/// any job is ready, and whether the job the queue is working on is running or paused. The
/// queue does not republish its jobs' changes, so without this the Start Queue button and the
/// Queue menu could show a stale state. Independent of window focus, unlike focused values.
@MainActor
final class QueueStatusMonitor: ObservableObject {
    static let shared = QueueStatusMonitor()

    @Published private(set) var hasReadyJobs = false
    /// `.running` or `.paused` while the queue works on a job; nil otherwise.
    @Published private(set) var runningJobState: JobState?

    private let queue = QueueViewModel.shared
    private var jobWatchers = Set<AnyCancellable>()
    private var currentJobWatcher: AnyCancellable?
    private var queueWatchers = Set<AnyCancellable>()

    private init() {
        // `@Published` sends before it stores, so recomputing from the queue waits a turn.
        queue.$jobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.watch(jobs) }
            .store(in: &queueWatchers)
        queue.$currentJob
            .sink { [weak self] job in self?.watchCurrent(job) }
            .store(in: &queueWatchers)
    }

    private func watch(_ jobs: [TransferJob]) {
        jobWatchers = []
        for job in jobs {
            Publishers.Merge3(job.$state.map { _ in () },
                              job.$destination.map { _ in () },
                              job.$scansInFlight.map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshReadiness() }
                .store(in: &jobWatchers)
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        let ready = queue.hasReadyJobs
        if ready != hasReadyJobs { hasReadyJobs = ready }
    }

    private func watchCurrent(_ job: TransferJob?) {
        guard let job else {
            currentJobWatcher = nil
            runningJobState = nil
            return
        }
        // `$state` hands over the new value, so it can be used as it arrives.
        currentJobWatcher = job.$state.sink { [weak self] state in
            let active = state == .running || state == .paused
            self?.runningJobState = active ? state : nil
        }
    }
}

// MARK: - What the menus know about the window

/// The facts about the selected job that the menus need, published by the job detail view.
/// A value snapshot rather than the job itself: a job changes many times a second while it
/// copies, and the menus only need to change when one of these facts does.
struct SelectedJobFacts: Equatable {
    let id: UUID
    let state: JobState
    let mode: TransferMode
    let isReady: Bool
    let isScanning: Bool
    let hasItems: Bool
    let canExportChecksums: Bool
    let isHeldBack: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool

    @MainActor
    init(job: TransferJob, queue: QueueViewModel) {
        id = job.id
        state = job.state
        mode = job.mode
        isReady = job.isReady
        isScanning = job.scansInFlight > 0
        hasItems = !job.items.isEmpty
        // Scans the file list, so only worth asking once the job has finished.
        canExportChecksums = job.state == .finished && job.canExportChecksums
        isHeldBack = queue.isHeldBack(job)
        canMoveUp = queue.canMoveQueuedJob(job, by: -1)
        canMoveDown = queue.canMoveQueuedJob(job, by: 1)
    }

    /// The job can be run on its own right now.
    func canStartAlone(queueActive: Bool) -> Bool {
        state == .draft && isReady && !isHeldBack && !queueActive
    }

    /// A held-back job that can join the run that is going.
    var canAddToQueue: Bool {
        isHeldBack && (isReady || isScanning)
    }
}

private struct SelectedJobFactsKey: FocusedValueKey {
    typealias Value = SelectedJobFacts
}

extension FocusedValues {
    var selectedJobFacts: SelectedJobFacts? {
        get { self[SelectedJobFactsKey.self] }
        set { self[SelectedJobFactsKey.self] = newValue }
    }
}

// MARK: - Shared titles

extension TransferMode {
    /// Runs this one job now. Not "Copy" alone, which is Edit ▸ Copy in the menu bar.
    var startTitle: String {
        switch self {
        case .copy: return "Copy Now"
        case .move: return "Move Now"
        case .verify: return "Verify Now"
        }
    }

    var startSymbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .verify: return "checkmark.shield"
        }
    }
}

extension CompletionAction {
    /// Title-style capitalization for menu items.
    var menuTitle: String {
        switch self {
        case .nothing: return "Do Nothing"
        case .sleep: return "Sleep the Mac"
        case .quit: return "Quit VeriCopy"
        }
    }

    /// The toolbar menu's own label, which shows what is armed.
    var toolbarTitle: String {
        switch self {
        case .nothing: return "When Done"
        case .sleep: return "Then Sleep"
        case .quit: return "Then Quit"
        }
    }

    var symbolName: String {
        switch self {
        case .nothing: return "flag.checkered"
        case .sleep: return "moon.zzz"
        case .quit: return "power"
        }
    }
}

// MARK: - Menu bar

/// Every command in the window, in the menu bar. The toolbar shows the frequent ones; this is
/// where all of them live, with their keyboard shortcuts.
struct VeriCopyCommands: Commands {
    @ObservedObject var queue: QueueViewModel
    @ObservedObject private var status = QueueStatusMonitor.shared
    @FocusedValue(\.selectedJobFacts) private var facts
    @AppStorage("detailViewMode") private var viewModeRaw = DetailViewMode.files.rawValue
    @AppStorage("autoScrollEnabled") private var autoScroll = true
    @AppStorage(PowerCoordinator.Key.completionAction) private var completionRaw = CompletionAction.nothing.rawValue

    /// The selected job itself, looked up when a command runs.
    private var selected: TransferJob? {
        guard let facts else { return nil }
        return queue.jobs.first { $0.id == facts.id }
    }

    private var isDraft: Bool { facts?.state == .draft }

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Job") { queue.newJob() }
                .keyboardShortcut("n")
            Button("Add Files or Folders…") { selected?.promptAddSources() }
                .keyboardShortcut("o")
                .disabled(!isDraft)
            Button("Choose Destination…") { selected?.promptChooseDestination() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!isDraft)
        }

        // After, not replacing: on macOS the save group also holds Close and Close All.
        CommandGroup(after: .saveItem) {
            Button("Save Checksums…") { selected?.exportChecksums() }
                .keyboardShortcut("s")
                .disabled(!(facts?.canExportChecksums ?? false))
        }

        CommandGroup(after: .sidebar) {
            Toggle("File List", isOn: viewModeBinding(.files))
                .keyboardShortcut("1")
            Toggle("Statistics", isOn: viewModeBinding(.stats))
                .keyboardShortcut("2")
            Toggle("Auto-Scroll to Current File", isOn: $autoScroll)
            Divider()
        }

        CommandMenu("Queue") {
            Button("Start Queue") { queue.startQueue() }
                .keyboardShortcut("r")
                .disabled(queue.queueActive || !status.hasReadyJobs)
            Button("Stop Queue") { queue.stopQueue() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!queue.queueActive)

            Divider()

            if status.runningJobState == .paused {
                Button("Resume Current Job") { queue.resumeCurrent() }
            } else {
                Button("Pause Current Job") { queue.pauseCurrent() }
                    .disabled(status.runningJobState != .running)
            }
            Button("Cancel Current Job") { queue.cancelCurrentJob() }
                .keyboardShortcut(".")
                .disabled(status.runningJobState == nil)

            Divider()

            Picker("When Queue Finishes", selection: $completionRaw) {
                ForEach(CompletionAction.allCases) { action in
                    Text(action.menuTitle).tag(action.rawValue)
                }
            }

            Divider()

            Button("Clear Finished Jobs") { queue.removeFinishedJobs() }
                .disabled(!queue.hasFinishedJobs || queue.queueActive)
        }

        CommandMenu("Job") {
            Button(facts?.mode.startTitle ?? "Copy Now") {
                if let job = selected { queue.startQueue(startingWith: job, only: true) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!(facts?.canStartAlone(queueActive: queue.queueActive) ?? false))

            Button("Add to Queue") {
                if let job = selected { queue.addToQueue(job) }
            }
            .disabled(!(facts?.canAddToQueue ?? false))

            Button("Run Again") {
                if let job = selected { queue.runAgain(job) }
            }
            .disabled(facts?.state != .finished || queue.queueActive)

            Divider()

            Button("Rename") {
                if let job = selected { queue.renamingJobID = job.id }
            }
            .disabled(facts == nil)
            Button("Move Up in Queue") {
                if let job = selected { queue.moveQueuedJob(job, by: -1) }
            }
            .disabled(!(facts?.canMoveUp ?? false))
            Button("Move Down in Queue") {
                if let job = selected { queue.moveQueuedJob(job, by: 1) }
            }
            .disabled(!(facts?.canMoveDown ?? false))

            Divider()

            Button("Clear File List") { selected?.clearItems() }
                .disabled(!isDraft || !(facts?.hasItems ?? false))
            Button("Remove Job") {
                if let job = selected { queue.removeJob(job) }
            }
            .disabled(facts == nil || facts?.state == .running || facts?.state == .paused)
        }
    }

    private func viewModeBinding(_ mode: DetailViewMode) -> Binding<Bool> {
        Binding(
            get: { viewModeRaw == mode.rawValue },
            set: { if $0 { viewModeRaw = mode.rawValue } }
        )
    }
}
