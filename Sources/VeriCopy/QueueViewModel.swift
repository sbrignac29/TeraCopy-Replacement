import AppKit
import SwiftUI
import VeriCopyCore

/// Owns the job list and runs queued jobs one after another.
/// Exactly one job is ever running; engine delegate callbacks route to it.
@MainActor
final class QueueViewModel: ObservableObject, TransferEngineDelegate {

    static let shared = QueueViewModel()

    @Published var jobs: [TransferJob] = []
    @Published var selectedJobID: UUID?
    @Published var queueActive = false
    @Published var conflict: ConflictPrompt?
    @Published var alertMessage: String?

    private var jobCounter = 0
    /// The job currently executing. Published so surfaces like the menu-bar indicator can
    /// observe which job (and thus which job's live progress) to display.
    @Published private(set) var currentJob: TransferJob?
    private var stopRequested = false
    private var activityToken: NSObjectProtocol?

    // Completion notifications. Both default to inert so this type compiles and runs in the
    // headless queue test without the concrete channel classes; the app installs the real ones.
    var notificationChannels: [NotificationChannel] = []
    var notificationSettings = NotificationSettings()
    /// Summaries of jobs finished during the current queue run, for the end-of-queue rollup.
    private var completedThisRun: [TransferSummary] = []

    // Power management. Same inert-by-default convention: the headless test injects a
    // recorder, so it exercises the full end-of-run state machine without ever sleeping
    // the test machine.
    var powerController: PowerController = InertPowerController()
    var powerSettings = PowerSettings()
    /// Per-job completion actions for the jobs that actually ran this queue pass, in order.
    private var runActions: [CompletionAction] = []
    /// Summaries for everything the current run has executed, across any resumes. Cleared only
    /// by a fresh Start, so the end-of-run decision covers every job the user queued in that run.
    private var runSummaries: [TransferSummary] = []
    /// Drafts the current run leaves alone. Pressing one job's Copy button runs that job, not
    /// every other job the user had already set up, so those are held back. Anything set up
    /// after the run starts is not in here, so it joins the run. Reset by every fresh Start
    /// and kept across a resume, since a resume continues the same run.
    @Published private(set) var heldBackJobIDs: Set<UUID> = []
    /// The armed completion action, if any. Drives the floating countdown panel.
    @Published private(set) var pendingCompletion: PendingCompletion?
    private var completionTask: Task<Void, Never>?

    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let jobName: String
        let item: FileItem
        let existingURL: URL
        let continuation: CheckedContinuation<ConflictResolution, Never>
    }

    init() {
        newJob()
    }

    var selectedJob: TransferJob? {
        jobs.first { $0.id == selectedJobID }
    }

    var hasReadyJobs: Bool {
        jobs.contains { $0.isReady }
    }

    var hasFinishedJobs: Bool {
        jobs.contains { $0.state == .finished }
    }

    // MARK: - Job management

    @discardableResult
    func newJob(select: Bool = true) -> TransferJob {
        jobCounter += 1
        let job = TransferJob(number: jobCounter)
        jobs.append(job)
        if select { selectedJobID = job.id }
        return job
    }

    func removeJob(_ job: TransferJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { selectedJobID = jobs.last?.id }
    }

    func removeFinishedJobs() {
        let keepSelection = selectedJob?.state != .finished
        jobs.removeAll { $0.state == .finished }
        if !keepSelection { selectedJobID = jobs.last?.id }
    }

    // MARK: - Queue order

    /// The earliest list position a queued job may occupy: just below the last job that has
    /// started (running, paused or finished). Queued jobs never sit above a started job, so the
    /// list reads top to bottom in the order the queue will run.
    private var queueFloor: Int {
        (jobs.lastIndex { $0.state != .draft } ?? -1) + 1
    }

    /// Moves queued jobs. Uses SwiftUI's `onMove` convention: `destination` is the insertion
    /// point in the current list. Only queued (draft) jobs can move, and nothing can be dropped
    /// above a job that has started. Running and finished jobs keep their places, so a reorder
    /// is safe while another job is transferring.
    func moveQueuedJobs(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
              source.allSatisfy({ jobs.indices.contains($0) && jobs[$0].state == .draft }) else { return }
        jobs.move(fromOffsets: source, toOffset: max(destination, queueFloor))
    }

    /// Whether a queued job can move one place up (`-1`) or down (`+1`) among the queued jobs.
    func canMoveQueuedJob(_ job: TransferJob, by step: Int) -> Bool {
        queueMoveTarget(for: job, by: step) != nil
    }

    /// Moves a queued job one place up or down among the queued jobs. A no-op when it is
    /// already at the edge the queue allows.
    func moveQueuedJob(_ job: TransferJob, by step: Int) {
        guard let target = queueMoveTarget(for: job, by: step),
              let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs.move(fromOffsets: IndexSet(integer: index), toOffset: target)
    }

    /// The insertion point that moves `job` one queued place in `step`'s direction, or nil if
    /// the move would change nothing (no queued neighbour, or the started-job floor is in the way).
    private func queueMoveTarget(for job: TransferJob, by step: Int) -> Int? {
        guard job.state == .draft, let index = jobs.firstIndex(where: { $0.id == job.id }) else { return nil }
        let target: Int
        if step < 0 {
            guard let neighbour = jobs[..<index].lastIndex(where: { $0.state == .draft }) else { return nil }
            target = neighbour
        } else {
            guard let neighbour = jobs[(index + 1)...].firstIndex(where: { $0.state == .draft }) else { return nil }
            target = neighbour + 1
        }
        let clamped = max(target, queueFloor)
        // Inserting at `index` or `index + 1` leaves the list as it is.
        return (clamped == index || clamped == index + 1) ? nil : clamped
    }

    /// A draft with work set up: ready to go, or still scanning its folders on the way.
    private static func hasWorkSetUp(_ job: TransferJob) -> Bool {
        job.state == .draft && (job.isReady || job.scansInFlight > 0)
    }

    /// A job the current run still owes: work set up, and not held back from the run.
    private func owesWork(_ job: TransferJob) -> Bool {
        Self.hasWorkSetUp(job) && !heldBackJobIDs.contains(job.id)
    }

    private var hasPendingWork: Bool {
        jobs.contains(where: owesWork)
    }

    /// The job the run takes next: the first ready one in list order that is not held back.
    private var nextQueuedJob: TransferJob? {
        jobs.first { $0.isReady && !heldBackJobIDs.contains($0.id) }
    }

    /// Whether the running queue will take this job once the jobs above it finish.
    func isQueued(_ job: TransferJob) -> Bool {
        queueActive && job.isReady && !heldBackJobIDs.contains(job.id)
    }

    /// Whether a job set up before this run started was left out of it. Such a job can join
    /// with `addToQueue`.
    func isHeldBack(_ job: TransferJob) -> Bool {
        queueActive && job.state == .draft && heldBackJobIDs.contains(job.id)
    }

    /// Puts a held-back job into the running queue, at its place in the list.
    func addToQueue(_ job: TransferJob) {
        heldBackJobIDs.remove(job.id)
    }

    /// Where a queued job stands in line: 1 for the job that starts next. Nil if not queued.
    func queuePosition(of job: TransferJob) -> Int? {
        guard isQueued(job) else { return nil }
        let queued = jobs.filter(isQueued)
        return queued.firstIndex { $0 === job }.map { $0 + 1 }
    }

    /// Files dropped anywhere land in the selected draft job, or start a fresh one.
    func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let job = selectedJob, job.isEditable {
            job.addSources(urls)
        } else {
            newJob().addSources(urls)
        }
    }

    // MARK: - Queue execution

    /// Runs every ready job in list order. Pass a specific job (with `only: true`) to run that
    /// one: the other jobs already set up are held back, but a job set up while it runs still
    /// queues behind it.
    func startQueue(startingWith first: TransferJob? = nil, only: Bool = false) {
        guard !queueActive else { return }
        // A countdown from a previous run must never survive into a new one — otherwise a
        // stale "quit" could fire in the middle of this transfer.
        cancelPendingCompletion()
        stopRequested = false
        completedThisRun = []
        runSummaries = []
        runActions = []
        // A job posted to the local API is never held back: the API promises it starts as
        // soon as the queue reaches it.
        heldBackJobIDs = only
            ? Set(jobs.filter { $0 !== first && !$0.createdViaAPI && Self.hasWorkSetUp($0) }.map(\.id))
            : []
        launchRun(startingWith: first)
    }

    /// Raises `queueActive` and starts the run loop. Shared by a fresh Start and by a run that
    /// resumes because work joined while the previous pass was winding down. The resume path
    /// must not touch the run's accounting, which is why it does not live in `startQueue`.
    private func launchRun(startingWith first: TransferJob?) {
        queueActive = true
        // NOTE: `.userInitiated` already contains `idleSystemSleepDisabled`, so using it
        // here would silently keep the Mac awake even with the keep-awake setting off.
        // Use the "allowing idle system sleep" variant and let the IOPM assertion below be
        // the single, user-controlled authority. We still want beginActivity for what the
        // assertion does NOT provide: App Nap suppression (a long transfer with the window
        // hidden could otherwise be throttled) and sudden-termination suppression.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: PowerSettings.assertionName
        )
        reconcileKeepAwake()

        Task {
            if let first, first.isReady {
                await run(first)
            }
            await drainQueuedJobs()
            await endQueueRun()
        }
    }

    /// Runs queued jobs until none is left. The next job is looked up after each one finishes,
    /// so jobs added or reordered while one copies run in the order the list shows by then.
    /// A queued job still scanning its folders is about to become ready, so the run waits for
    /// it instead of ending early and stranding it.
    private func drainQueuedJobs() async {
        while !stopRequested {
            if let next = nextQueuedJob {
                await run(next)
            } else if hasPendingWork {
                try? await Task.sleep(nanoseconds: 100_000_000)
            } else {
                return
            }
        }
    }

    /// The single teardown point every queue exit path converges on — normal drain,
    /// Stop Queue, per-job cancel, and fatal errors all land here.
    private func endQueueRun() async {
        let wasStopped = stopRequested

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        currentJob = nil
        queueActive = false
        reconcileKeepAwake() // queue no longer active ⇒ drops the hold

        // Notifications first: `deliver` is awaited, so the banner is posted and any
        // iMessage has actually been handed to Messages before we could sleep or quit.
        await notifyQueueComplete()

        // Delivery suspends, and during that window the Start button is live and a job can be
        // added or finish scanning. Such a job must not be stranded, and the run is not over
        // while it waits, so the run resumes instead of arming a sleep or quit under it. A Start
        // pressed in that window already owns the teardown. Held-back jobs are not owed, so
        // they never keep a run going.
        guard !queueActive else { return }
        if !wasStopped && hasPendingWork {
            launchRun(startingWith: nil)
            return
        }

        armCompletion(summaries: runSummaries, actions: runActions, stopRequested: wasStopped)
    }

    /// Cancels one job by identity, whether it is running or still waiting in the queue.
    /// Returns false when there was nothing to cancel because the job already finished.
    @discardableResult
    func cancelJob(_ job: TransferJob) -> Bool {
        switch job.state {
        case .finished:
            return false
        case .running, .paused:
            guard currentJob === job else { return false }
            cancelCurrentJob()
            return true
        case .draft:
            // Never started. Mark it cancelled rather than removing it: `isReady` then skips
            // it, and the API can still report a terminal status for the id it handed out.
            var summary = TransferSummary()
            summary.cancelled = true
            job.summary = summary
            job.finishedAt = Date()
            job.state = .finished
            return true
        }
    }

    func runAgain(_ job: TransferJob) {
        guard job.state == .finished, !queueActive else { return }
        job.resetForRun()
        job.state = .draft
        startQueue(startingWith: job, only: true)
    }

    private func run(_ job: TransferJob) async {
        guard let destination = job.destination else { return }
        job.resetForRun()

        var plan = TransferPlan()
        plan.items = job.items
        plan.directories = job.directories
        plan.directorySources = job.directorySources
        plan.totalBytes = job.totalBytes

        let engine = TransferEngine(metadataPolicy: metadataPolicy,
                                    estimatorSeed: Self.estimatorSeed(for: destination))
        job.engine = engine
        job.state = .running
        job.speedSamples = []
        job.progressDone = 0
        job.progressTotal = job.totalBytes
        job.isVerificationPhase = false
        currentJob = job
        selectedJobID = job.id // follow the running job
        job.startedAt = Date()

        let summary = await engine.run(plan: plan, mode: job.mode, algorithm: job.algorithm,
                                       destinationRoot: destination, verification: job.verification,
                                       delegate: self)
        job.summary = summary
        job.finishedAt = Date()
        job.state = .finished
        job.engine = nil
        job.speedBytesPerSecond = 0
        job.isVerificationPhase = false
        job.currentItemID = nil
        job.settleSpeeds()
        job.flushUIRefresh() // show the final per-file results immediately
        if let fatal = summary.fatalError {
            alertMessage = "\(job.name): \(fatal)"
        }

        if let snapshot = summary.estimatorSnapshot, !summary.cancelled {
            Self.storeEstimatorSeed(snapshot, for: destination)
        }

        completedThisRun.append(summary)
        runSummaries.append(summary)
        runActions.append(job.completionAction)
        await notifyJobComplete(job, summary: summary)
    }

    // MARK: - Remembering how fast a destination is

    /// How much per-file metadata to carry. Shared across jobs; see `MetadataPolicy`.
    var metadataPolicy: MetadataPolicy {
        UserDefaults.standard.string(forKey: "metadataPolicy")
            .flatMap(MetadataPolicy.init(rawValue:)) ?? .native
    }

    /// A drive's measured speed is a property of the drive, not of one job, so it is kept per
    /// destination volume. The next ingest onto the same drive starts with a calibrated
    /// estimate instead of the generic prior.
    private static func estimatorKey(for destination: URL) -> String? {
        guard let id = try? destination.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier else { return nil }
        return "estimator.\(String(describing: id).hashValue)"
    }

    private static func estimatorSeed(for destination: URL) -> TransferEstimator.Snapshot? {
        guard let key = estimatorKey(for: destination),
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TransferEstimator.Snapshot.self, from: data)
    }

    private static func storeEstimatorSeed(_ snapshot: TransferEstimator.Snapshot, for destination: URL) {
        guard let key = estimatorKey(for: destination),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Keep awake / end-of-run action

    /// Brings the keep-awake hold in line with the current setting and queue state.
    /// Called on queue start, on teardown, and whenever Settings change — so toggling
    /// the preference mid-transfer takes effect immediately.
    func reconcileKeepAwake() {
        if powerSettings.shouldHoldAwake(queueActive: queueActive) {
            powerController.beginKeepAwake(reason: PowerSettings.assertionName)
        } else {
            powerController.endKeepAwake()
        }
    }

    private func armCompletion(summaries: [TransferSummary], actions: [CompletionAction], stopRequested: Bool) {
        let outcome = RunOutcome.summarize(summaries, stopRequested: stopRequested)
        switch powerSettings.decideCompletion(jobActions: actions, outcome: outcome) {
        case .doNothing:
            break
        case .blocked(_, .nothingRan), .blocked(_, .runWasCancelled):
            // Silent: the user pressed Stop/Cancel themselves, so they're already here.
            break
        case .blocked(let action, .runHadFailures):
            // Worth interrupting for — they walked away expecting this to happen.
            alertMessage = "VeriCopy didn't \(action.verbPhrase) — the run finished with errors."
        case .armCountdown(let action, let seconds):
            startCountdown(action: action, seconds: seconds, outcome: outcome, watchesForNewWork: true)
        }
    }

    /// `watchesForNewWork` is true for an end-of-run countdown: if work joins the queue while it
    /// runs, the countdown is cancelled and the queue carries on. The test countdown passes
    /// false, since it must never start a transfer.
    private func startCountdown(action: CompletionAction, seconds: Int, outcome: RunOutcome,
                                watchesForNewWork: Bool) {
        completionTask?.cancel()
        // The display is allowed to sleep during a transfer, so wake it — otherwise the
        // countdown would tick away on a dark screen with no chance to cancel.
        powerController.declareUserActivity()

        pendingCompletion = PendingCompletion(
            action: action,
            totalSeconds: seconds,
            secondsRemaining: seconds,
            detail: outcome.detailLine,
            removableVolumeName: removableDestinationName()
        )

        // Deadline-based rather than N× sleep(1s): a stalled main actor (e.g. the user has
        // a modal save panel open) can't stretch the window beyond the wall-clock deadline.
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        // Work already owed when the countdown is armed is not new. Only work that joins
        // afterwards cancels it. (Held-back drafts are never owed, so they cannot cancel it.)
        let knownWork = Set(jobs.filter(owesWork).map(\.id))
        completionTask = Task { [weak self] in
            while !Task.isCancelled {
                // The queue is not finished while new work waits in it. Sleeping now would strand
                // that work, so cancel the countdown and carry on with the queue instead.
                if watchesForNewWork, let self,
                   self.jobs.contains(where: { self.owesWork($0) && !knownWork.contains($0.id) }) {
                    self.cancelPendingCompletion()
                    self.launchRun(startingWith: nil)
                    return
                }
                let remaining = Int(ceil(deadline.timeIntervalSinceNow))
                guard remaining > 0 else { break }
                self?.pendingCompletion?.secondsRemaining = remaining
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingCompletion = nil
            self.completionTask = nil
            self.perform(action)
        }
    }

    private func perform(_ action: CompletionAction) {
        switch action {
        case .sleep: powerController.sleepSystem()
        case .quit: powerController.quitApp()
        case .nothing: break
        }
    }

    /// Name of the destination volume if it's removable — so the panel can warn the user
    /// not to unplug the drive until the Mac is actually asleep.
    private func removableDestinationName() -> String? {
        // The job that finished last, by time: the queue can be reordered, so list position
        // no longer says which job ran last.
        let lastFinished = jobs.filter { $0.state == .finished }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        guard let destination = lastFinished?.destination else { return nil }
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        guard let values = try? destination.resourceValues(forKeys: keys) else { return nil }
        let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
        return removable ? values.volumeName : nil
    }

    /// Cancel an armed action. Safe to call when nothing is pending.
    func cancelPendingCompletion() {
        completionTask?.cancel()
        completionTask = nil
        pendingCompletion = nil
    }

    /// Arms a harmless countdown so the user can confirm the panel actually reaches them
    /// before trusting it with an overnight transfer. Uses `.nothing`, so when it elapses
    /// the Mac does not sleep and the app does not quit.
    func startTestCountdown(seconds: Int = 10) {
        guard !queueActive else { return }
        var outcome = RunOutcome()
        outcome.jobCount = 0
        startCountdown(action: .nothing, seconds: seconds, outcome: outcome, watchesForNewWork: false)
    }

    /// Skip the remaining countdown and act immediately ("Sleep Now" on the panel).
    func performPendingCompletionNow() {
        guard let pending = pendingCompletion else { return }
        completionTask?.cancel()
        completionTask = nil
        pendingCompletion = nil
        perform(pending.action)
    }

    // MARK: - Completion notifications

    private func notifyJobComplete(_ job: TransferJob, summary: TransferSummary) async {
        let isFailure = summary.failed > 0 || summary.fatalError != nil
        let content = NotificationContent.forJob(name: job.name, destination: job.destination, summary: summary)

        var chosen: [NotificationChannel] = []
        if notificationSettings.shouldNotifyDesktop(isFailure: isFailure, phase: .job) {
            chosen += notificationChannels.filter { $0.kind == .desktop }
        }
        if notificationSettings.shouldNotifySMS(isFailure: isFailure, phase: .job) {
            chosen += notificationChannels.filter { $0.kind == .sms }
        }
        await deliver(content, to: chosen)
    }

    private func notifyQueueComplete() async {
        // A single-job run is already covered by the per-job notification; only roll up when
        // more than one job ran, or when the user asked for queue-only notifications.
        let summaries = completedThisRun
        completedThisRun = []
        guard summaries.count > 1 || notificationSettings.trigger == .queueComplete else { return }
        guard !summaries.isEmpty else { return }

        var combined = TransferSummary()
        for s in summaries {
            combined.succeeded += s.succeeded
            combined.skipped += s.skipped
            combined.failed += s.failed
            combined.bytesCopied += s.bytesCopied
            combined.elapsed += s.elapsed
            combined.cancelled = combined.cancelled || s.cancelled
        }
        let isFailure = combined.failed > 0
        let content = NotificationContent.forQueue(jobCount: summaries.count, combined: combined)

        var chosen: [NotificationChannel] = []
        if notificationSettings.shouldNotifyDesktop(isFailure: isFailure, phase: .queue) {
            chosen += notificationChannels.filter { $0.kind == .desktop }
        }
        if notificationSettings.shouldNotifySMS(isFailure: isFailure, phase: .queue) {
            chosen += notificationChannels.filter { $0.kind == .sms }
        }
        await deliver(content, to: chosen)
    }

    private func deliver(_ content: NotificationContent, to channels: [NotificationChannel]) async {
        for channel in channels {
            await channel.deliver(content)
        }
    }

    // MARK: - Controls for the running job

    func pauseCurrent() {
        guard let job = currentJob, job.state == .running else { return }
        job.engine?.pause()
        job.state = .paused
    }

    func resumeCurrent() {
        guard let job = currentJob, job.state == .paused else { return }
        job.engine?.resume()
        job.state = .running
    }

    /// Cancels the running job; the queue moves on to the next ready job.
    func cancelCurrentJob() {
        currentJob?.engine?.cancel()
        if let prompt = conflict {
            conflict = nil
            prompt.continuation.resume(returning: ConflictResolution(choice: .skip, applyToAll: true))
        }
    }

    /// Cancels the running job and stops processing further jobs.
    func stopQueue() {
        stopRequested = true
        cancelCurrentJob()
    }

    func answerConflict(_ choice: ConflictChoice, applyToAll: Bool) {
        guard let prompt = conflict else { return }
        conflict = nil
        prompt.continuation.resume(returning: ConflictResolution(choice: choice, applyToAll: applyToAll))
    }

    // MARK: - TransferEngineDelegate (routes to the running job)

    func engineDidUpdate(item: FileItem, at index: Int) async {
        guard let job = currentJob else { return }
        // O(1) update + coalesced UI refresh. Assigning to `job.items[index]` here would
        // copy the whole array on every call — the cause of the small-file slowdown.
        job.updateItem(item, at: index)
    }

    /// The call the pump actually makes: one hop onto the main actor for a whole delivery
    /// pass, however many files it covers. Taking these one at a time cost a display frame
    /// each, which is what made a 1,200-file job report "copying" for the best part of a
    /// minute after the bytes had landed.
    func engineDidUpdate(batch: [ItemUpdate]) async {
        currentJob?.applyUpdates(batch)
    }

    /// Unused: the engine reports through `engineDidUpdateProgress`. Kept because it is part
    /// of the delegate protocol and the headless harnesses still implement it.
    func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}

    func engineDidUpdateProgress(_ progress: TransferProgress) async {
        currentJob?.applyProgress(progress)
    }

    func engineDidBeginVerificationPhase(fileCount: Int, totalBytes: Int64) async {
        // Purely a label now. `TransferProgress` spans both phases, so neither the bar nor the
        // estimate resets here — the job is not starting over, it is entering its last stretch.
        currentJob?.isVerificationPhase = true
    }

    func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
        await withCheckedContinuation { continuation in
            conflict = ConflictPrompt(jobName: currentJob?.name ?? "",
                                      item: item, existingURL: existingURL,
                                      continuation: continuation)
        }
    }
}
