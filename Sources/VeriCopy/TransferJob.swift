import AppKit
import SwiftUI
import VeriCopyCore

enum JobState: Equatable {
    case draft      // being configured; editable
    case running
    case paused
    case finished   // summary + per-file results retained
}

/// One copy/move/verify task in the queue: its own sources, destination,
/// settings, file list, live progress, and — once finished — its results.
@MainActor
final class TransferJob: ObservableObject, Identifiable {
    let id = UUID()

    @Published var name: String
    @Published var mode: TransferMode = .copy
    @Published var algorithm: HashAlgorithm = .sha256 {
        didSet { if persistsSettings { UserDefaults.standard.set(algorithm.rawValue, forKey: "hashAlgorithm") } }
    }
    @Published var verification: VerificationPolicy = .perFile {
        didSet { if persistsSettings { UserDefaults.standard.set(verification.rawValue, forKey: "verificationPolicy") } }
    }
    /// What happens once the whole queue finishes. Sticky across jobs and launches, and
    /// shared with the Settings default — same key, same pattern as `verification` above.
    @Published var completionAction: CompletionAction = .nothing {
        didSet { if persistsSettings { UserDefaults.standard.set(completionAction.rawValue, forKey: "powerCompletionAction") } }
    }
    /// Whether changing this job's settings also updates the app-wide defaults.
    ///
    /// True for jobs the user builds in the window — picking SHA-512 there should stick for
    /// next time. False for jobs created over the API, which set their own mode and
    /// verification policy and must not quietly rewrite the user's preferences (or inherit
    /// "Sleep the Mac when done" and put the machine to sleep behind a dashboard request).
    var persistsSettings = true
    @Published var destination: URL?
    /// The file list.
    ///
    /// Deliberately NOT `@Published`. A `@Published` array hands its old value to
    /// subscribers on every mutation, which forces a copy-on-write of the whole array —
    /// measured at ~0.5 ms per element write with 20,000 items. The engine reports roughly
    /// six updates per file, so on a big job of small files that alone made the transfer
    /// O(n²) and collapsed throughput to a few KB/s.
    ///
    /// Instead the storage is plain (element writes are O(1)) and the UI is refreshed by a
    /// coalesced `objectWillChange` at `uiRefreshInterval`. Use `updateItem(_:at:)` for
    /// per-file updates; assigning to `items[i]` directly would reintroduce a full copy.
    var items: [FileItem] = [] {
        didSet {
            guard !suppressCountRebuild else { return }
            rebuildStatusCounts()
            notifyUISoon()
        }
    }
    @Published var state: JobState = .draft
    @Published var totalBytes: Int64 = 0
    @Published var progressDone: Int64 = 0
    @Published var progressTotal: Int64 = 0
    /// Copy + verification bytes, which is what the bar and the estimate run on.
    @Published var workDone: Int64 = 0
    @Published var workTotal: Int64 = 0
    @Published var isVerificationPhase = false
    @Published var speedBytesPerSecond: Double = 0
    /// Smoothed, rounded time remaining. Nil while the estimate is still warming up.
    @Published var etaText: String?
    @Published var summary: TransferSummary?
    @Published var scansInFlight = 0
    /// The file most recently touched by the engine — what auto-scroll follows.
    @Published var currentItemID: UUID?

    /// When the engine actually began and finished this job. Not used by the UI, which shows
    /// elapsed time from the summary; the API reports them as ISO-8601 timestamps.
    var startedAt: Date?
    var finishedAt: Date?
    /// True for jobs created over the local API rather than built in the window.
    var createdViaAPI = false
    /// The same smoothed countdown as `etaText`, but to the second instead of rounded for
    /// display, for the API. Nil while the estimate is still warming up.
    private(set) var secondsRemaining: Int?

    // Stats view: read/write throughput series and live values.
    @Published var speedHistory: [SpeedSample] = []
    @Published var readSpeedNow: Double = 0   // bytes/sec
    @Published var writeSpeedNow: Double = 0  // bytes/sec
    private(set) var readBytesTotal: Int64 = 0
    private(set) var writeBytesTotal: Int64 = 0

    var sourceRoots = Set<URL>()
    var directories: [String] = []
    var directorySources: [(source: URL, relative: String)] = []
    var engine: TransferEngine?
    var speedSamples: [(time: Date, bytes: Int64)] = []

    struct SpeedSample: Identifiable {
        let id = UUID()
        let time: Date
        let readBps: Double
        let writeBps: Double
    }

    /// Which kind of streaming I/O an in-flight item is doing.
    private enum IOKind: Equatable {
        case copy    // reading the source AND writing the destination
        case verify  // reading the destination (or source, in verify mode) back
    }

    /// Baseline for the phase currently streaming: last seen byte count + the item's size,
    /// so the un-reported tail of a completed phase can be credited on transition.
    private var ioBaseline: (itemID: UUID, kind: IOKind, bytes: Int64, size: Int64)?
    private var lastIOSample: (time: Date, read: Int64, write: Int64)?
    // Exponentially-weighted moving averages so the graph and live values read smoothly
    // instead of tracking every 0.5 s throughput spike (especially with many small files).
    private var emaRead: Double = 0
    private var emaWrite: Double = 0
    private var hasEMA = false

    init(number: Int) {
        name = "Job \(number)"
        if let raw = UserDefaults.standard.string(forKey: "hashAlgorithm"),
           let saved = HashAlgorithm(rawValue: raw) {
            algorithm = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "verificationPolicy"),
           let saved = VerificationPolicy(rawValue: raw) {
            verification = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "powerCompletionAction"),
           let saved = CompletionAction(rawValue: raw) {
            completionAction = saved
        }
    }

    var isEditable: Bool { state == .draft }
    var isActive: Bool { state == .running || state == .paused }

    // MARK: - Live status counts (stats view)

    struct StatusCounts {
        var copied = 0     // data landed at the destination (.copied, .done, .doneNoVerify)
        var verified = 0   // read back and checksum-matched (.done)
        var failed = 0
        var waiting = 0    // .pending
        var skipped = 0
        var active = 0     // currently copying/verifying
        var total = 0
    }

    /// Live counts, maintained incrementally.
    ///
    /// Previously a full scan of `items` — O(n) — and it is read from the stats view body
    /// on every render, so on a large job it was a second quadratic term. Now it is a
    /// stored value updated by delta as statuses change, so reading it is O(1).
    private(set) var statusCounts = StatusCounts()

    /// Applies one item's status transition to the running totals.
    private func applyCountDelta(from old: ItemStatus?, to new: ItemStatus?) {
        func adjust(_ status: ItemStatus, _ delta: Int) {
            switch status {
            case .pending: statusCounts.waiting += delta
            case .copying: statusCounts.active += delta
            case .verifying:
                // Data is already on disk — keep it counted as copied so the number doesn't
                // drop while the read-back runs; it's just also currently active.
                statusCounts.copied += delta
                statusCounts.active += delta
            case .copied: statusCounts.copied += delta
            case .done:
                statusCounts.copied += delta
                statusCounts.verified += delta
            case .doneNoVerify: statusCounts.copied += delta
            case .skipped: statusCounts.skipped += delta
            case .failed: statusCounts.failed += delta
            }
        }
        if let old { adjust(old, -1) }
        if let new { adjust(new, +1) }
    }

    /// Files that completed without their data ever being checksum-compared.
    ///
    /// Symlinks are excluded: a symlink carries a target path, not content, so there is
    /// nothing for a read-back to compare and its absence says nothing about integrity.
    /// What this does catch is a same-volume move (a rename — no bytes rewritten) and a
    /// copy run with verification off. The API reports it, and uses it to decide whether a
    /// finished job can honestly be called "verified".
    var unverifiedFileCount: Int { apiTally.unverified }

    /// Both per-file figures the API needs, in a single pass over `items`.
    struct APITally {
        var unverified = 0   // finished, but never checksum-compared
        var verifying = 0    // reading back right now
    }

    var apiTally: APITally {
        var tally = APITally()
        for item in items {
            if item.status == .doneNoVerify && !item.isSymlink { tally.unverified += 1 }
            if item.status == .verifying { tally.verifying += 1 }
        }
        return tally
    }

    /// Full recount — only for bulk changes (adding files, resetting), never per file.
    private func rebuildStatusCounts() {
        var counts = StatusCounts()
        for item in items {
            counts.total += 1
            switch item.status {
            case .pending: counts.waiting += 1
            case .copying: counts.active += 1
            case .verifying:
                counts.copied += 1
                counts.active += 1
            case .copied: counts.copied += 1
            case .done:
                counts.copied += 1
                counts.verified += 1
            case .doneNoVerify: counts.copied += 1
            case .skipped: counts.skipped += 1
            case .failed: counts.failed += 1
            }
        }
        statusCounts = counts
    }

    /// Folds one item's new state into the model: O(1) element write, O(1) count delta, and
    /// the throughput accounting the stats view reads.
    ///
    /// Deliberately does *not* touch `currentItemID` or ask for a refresh. Those are once-per-
    /// delivery concerns, not once-per-file ones, and `currentItemID` is `@Published` — so
    /// setting it here would put an un-coalesced `objectWillChange` on a path that runs
    /// thousands of times per job. The two entry points below do each exactly once.
    ///
    /// Returns false for an index outside `items`, so a caller can tell nothing was applied.
    @discardableResult
    private func applyItem(_ item: FileItem, at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        let previous = items[index].status
        // Bypass the `items` didSet (which would trigger a full recount) — the delta below
        // keeps the totals correct in O(1).
        withoutCountRebuild {
            items[index] = item
        }
        applyCountDelta(from: previous, to: item.status)
        recordItemActivity(item)
        return true
    }

    /// The engine's per-file update path: one item, then a coalesced UI refresh.
    func updateItem(_ item: FileItem, at index: Int) {
        guard applyItem(item, at: index) else { return }
        currentItemID = item.id
        notifyUISoon()
    }

    /// A whole delivery pass at once. This is the hot path for a job of many small files.
    ///
    /// The engine's pump hands over everything it has accumulated in one call, and the point
    /// of taking it in one call is that this method runs once per pass rather than once per
    /// file: one hop onto the main actor, one `currentItemID` publish, one refresh request.
    /// Delivering the same updates one at a time cost a display frame apiece — 16 ms, for
    /// 0.056 ms of actual work — because the main queue drains between awaits and lets the
    /// run loop get in front of the next one.
    ///
    /// Items are applied in order, so the per-file statuses, the counts and the read/write
    /// series all see exactly the sequence they saw before.
    func applyUpdates(_ updates: [ItemUpdate]) {
        var lastTouched: UUID?
        for update in updates {
            if applyItem(update.item, at: update.index) {
                lastTouched = update.item.id
            }
        }
        // The most recently touched file — what auto-scroll follows and the row highlight
        // marks. Intermediate values within one pass were never on screen for a frame.
        guard let lastTouched else { return }
        currentItemID = lastTouched
        notifyUISoon()
    }

    private var suppressCountRebuild = false
    private func withoutCountRebuild(_ body: () -> Void) {
        suppressCountRebuild = true
        body()
        suppressCountRebuild = false
    }

    // MARK: - Coalesced UI refresh

    /// ~15 Hz. Fast enough to look live, slow enough that a thousand small files don't
    /// each trigger a full SwiftUI diff of the file list.
    private static let uiRefreshInterval: TimeInterval = 1.0 / 15.0
    private var lastUIRefresh = Date.distantPast
    private var uiRefreshPending = false

    /// Requests a UI refresh, at most `uiRefreshInterval` apart. A trailing refresh is
    /// always scheduled so the final state is never left stale on screen.
    private func notifyUISoon() {
        let now = Date()
        if now.timeIntervalSince(lastUIRefresh) >= Self.uiRefreshInterval {
            lastUIRefresh = now
            objectWillChange.send()
            return
        }
        guard !uiRefreshPending else { return }
        uiRefreshPending = true
        let delay = Self.uiRefreshInterval - now.timeIntervalSince(lastUIRefresh)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self else { return }
            self.uiRefreshPending = false
            self.lastUIRefresh = Date()
            self.objectWillChange.send()
        }
    }

    /// Forces an immediate refresh — used at job boundaries so the final result is shown
    /// without waiting for the next coalescing window.
    func flushUIRefresh() {
        lastUIRefresh = Date()
        objectWillChange.send()
    }

    // MARK: - Read/write throughput tracking (stats view)

    /// Derives read/write byte counters from per-item engine updates. The engine streams one
    /// item, one phase at a time: `.copying` progress means the source is being read AND the
    /// destination written; `.verifying` progress is a pure read-back. A phase's final bytes may
    /// never be reported directly (updates are throttled), so on a phase/item transition the
    /// remainder up to the item's size is credited; a terminal update on the same item credits
    /// exactly the bytes it reports (correct for failures/cancellations mid-file).
    func recordItemActivity(_ item: FileItem) {
        let kind: IOKind?
        switch item.status {
        case .copying: kind = .copy
        case .verifying: kind = .verify
        default: kind = nil
        }

        if let base = ioBaseline {
            if item.id == base.itemID, kind == base.kind {
                accumulate(base.kind, item.bytesCopied - base.bytes)
                ioBaseline?.bytes = item.bytesCopied
            } else if item.id == base.itemID, kind == nil {
                // Terminal update for the streaming item: credit exactly what it reports.
                accumulate(base.kind, item.bytesCopied - base.bytes)
                ioBaseline = nil
                // The item stopped streaming — nothing "current" for the live speed to track
                // until the next one starts. Reseed rather than let the rate decay to zero
                // over several seconds while idle.
                resetSmoothing()
            } else {
                // Switched phase (copy→verify) or item: the previous phase completed fully —
                // credit its tail, then start the NEW phase's rate from scratch. Without this,
                // the EMA keeps averaging in the old phase's (now-irrelevant) rate, which is
                // exactly why a short verify pass could show a speed that never catches up to
                // reality before the phase already ends — it's still crawling from the
                // preceding copy phase's number, or decaying a stale write-rate toward zero
                // long after writing actually stopped.
                accumulate(base.kind, base.size - base.bytes)
                resetSmoothing()
                if let kind {
                    ioBaseline = (item.id, kind, item.bytesCopied, item.size)
                    accumulate(kind, item.bytesCopied)
                } else {
                    ioBaseline = nil
                }
            }
        } else if let kind {
            ioBaseline = (item.id, kind, item.bytesCopied, item.size)
            accumulate(kind, item.bytesCopied)
        }

        sampleSpeedsIfDue()
    }

    /// Drops the current throughput sample/EMA state so the next measurement starts fresh
    /// instead of slowly converging from (or decaying toward zero from) a stale rate that
    /// belonged to a different file or a different phase of the same file.
    private func resetSmoothing() {
        lastIOSample = nil
        hasEMA = false
    }

    private func accumulate(_ kind: IOKind, _ delta: Int64) {
        guard delta > 0 else { return }
        readBytesTotal += delta          // both phases read
        if kind == .copy {
            writeBytesTotal += delta     // only the copy phase writes
        }
    }

    private func sampleSpeedsIfDue() {
        let now = Date()
        guard let last = lastIOSample else {
            lastIOSample = (now, readBytesTotal, writeBytesTotal)
            return
        }
        let dt = now.timeIntervalSince(last.time)
        guard dt >= 0.5 else { return }
        let instRead = Double(readBytesTotal - last.read) / dt
        let instWrite = Double(writeBytesTotal - last.write) / dt

        let alpha = 0.3 // lower = smoother, more lag
        if hasEMA {
            emaRead += alpha * (instRead - emaRead)
            emaWrite += alpha * (instWrite - emaWrite)
        } else {
            emaRead = instRead
            emaWrite = instWrite
            hasEMA = true
        }

        speedHistory.append(SpeedSample(time: now, readBps: emaRead, writeBps: emaWrite))
        if speedHistory.count > 240 { // ~2 minutes of history
            speedHistory.removeFirst(speedHistory.count - 240)
        }
        readSpeedNow = emaRead
        writeSpeedNow = emaWrite
        lastIOSample = (now, readBytesTotal, writeBytesTotal)
    }

    /// Called when the job stops running so the live numbers don't freeze on a stale value.
    func settleSpeeds() {
        readSpeedNow = 0
        writeSpeedNow = 0
        ioBaseline = nil
        lastIOSample = nil
        hasEMA = false
    }

    /// Ready to be picked up by the queue.
    var isReady: Bool {
        state == .draft && !items.isEmpty && destination != nil && scansInFlight == 0
    }

    var readinessNote: String? {
        if items.isEmpty && scansInFlight == 0 { return "Add files or folders first" }
        if destination == nil { return "Choose a destination folder" }
        if scansInFlight > 0 { return "Still scanning added folders…" }
        return nil
    }

    var progressFraction: Double {
        // Work fraction spans copy *and* verification, so the bar does not restart when the
        // end-of-job verification pass begins.
        if workTotal > 0 {
            return min(1, max(0, Double(workDone) / Double(workTotal)))
        }
        guard !items.isEmpty else { return 0 }
        let settled = items.filter { $0.status != .pending && $0.status != .copying && $0.status != .verifying }
        return Double(settled.count) / Double(items.count)
    }

    // MARK: - Time remaining
    //
    // The engine supplies a raw estimate roughly fifteen times a second from a fitted cost
    // model. Everything here is presentation: a raw number redrawn at 15 Hz is unreadable
    // however good the model is. `ETASmoother` holds the predicted finish time steady and
    // turns it into a countdown.

    private var etaSmoother = ETASmoother()

    /// Applies one progress reading from the engine.
    func applyProgress(_ progress: TransferProgress) {
        progressDone = progress.dataCopied
        progressTotal = progress.dataTotal
        workDone = progress.workDone
        workTotal = progress.workTotal
        isVerificationPhase = progress.isVerifying
        sampleOverallSpeed(workDone: progress.workDone)
        updateETA(raw: progress.secondsRemaining)
    }

    /// Job-wide throughput, measured over a fixed window of work bytes. Progress now arrives
    /// on a steady cadence, so the window is a real duration rather than however long it took
    /// whatever was being copied to produce the last few callbacks.
    private func sampleOverallSpeed(workDone: Int64) {
        let now = Date()
        speedSamples.append((now, workDone))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 3 }
        guard let first = speedSamples.first, now.timeIntervalSince(first.time) >= 1 else { return }
        let dt = now.timeIntervalSince(first.time)
        speedBytesPerSecond = max(0, Double(workDone - first.bytes) / dt)
    }

    private func updateETA(raw: TimeInterval?) {
        guard isActive else {
            resetETA()
            return
        }
        etaSmoother.update(raw: raw)
        // The API reports the same countdown the window shows, to the second. It used to get the
        // raw model output, which moves whenever the model learns something — a dashboard
        // polling every few seconds saw that as the job lurching.
        secondsRemaining = etaSmoother.seconds.map { Int($0.rounded()) }
        if etaSmoother.text != etaText { etaText = etaSmoother.text }
    }


    var canExportChecksums: Bool {
        items.contains { $0.checksum != nil && $0.status != .failed }
    }

    // MARK: - Building the file list

    func promptAddSources() {
        guard isEditable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders for \(name)"
        if panel.runModal() == .OK {
            addSources(panel.urls)
        }
    }

    func promptChooseDestination() {
        guard isEditable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the destination folder for \(name)"
        if panel.runModal() == .OK, let url = panel.urls.first {
            destination = url.standardizedFileURL
        }
    }

    func addSources(_ urls: [URL]) {
        guard isEditable else { return }
        let fresh = urls.map(\.standardizedFileURL).filter { !sourceRoots.contains($0) }
        guard !fresh.isEmpty else { return }
        sourceRoots.formUnion(fresh)
        scansInFlight += 1

        Task.detached(priority: .userInitiated) {
            let plan = SourceScanner.scan(sources: fresh)
            await MainActor.run {
                self.merge(plan)
                self.scansInFlight -= 1
            }
        }
    }

    private func merge(_ plan: TransferPlan) {
        items.append(contentsOf: plan.items)
        totalBytes += plan.totalBytes
        let knownDirs = Set(directories)
        for dir in plan.directories where !knownDirs.contains(dir) {
            directories.append(dir)
        }
        let knownSources = Set(directorySources.map(\.relative))
        for entry in plan.directorySources where !knownSources.contains(entry.relative) {
            directorySources.append(entry)
        }
        if !plan.scanErrors.isEmpty {
            QueueViewModel.shared.alertMessage = "\(name): some items could not be scanned:\n"
                + plan.scanErrors.prefix(8).joined(separator: "\n")
        }
    }

    func clearItems() {
        guard isEditable else { return }
        items = []
        sourceRoots = []
        directories = []
        directorySources = []
        totalBytes = 0
        progressDone = 0
        progressTotal = 0
        workDone = 0
        workTotal = 0
        summary = nil
        resetETA()
        resetIOTracking()
    }

    /// Re-arm for a (re-)run: statuses back to pending, progress zeroed.
    func resetForRun() {
        // Mutate under the rebuild guard so this is one pass, not one recount per element.
        withoutCountRebuild {
            for index in items.indices {
                items[index].status = .pending
                items[index].bytesCopied = 0
                items[index].checksum = nil
                items[index].message = nil
                items[index].destinationName = nil
            }
        }
        rebuildStatusCounts()
        flushUIRefresh()
        summary = nil
        progressDone = 0
        progressTotal = totalBytes
        workDone = 0
        workTotal = 0
        isVerificationPhase = false
        speedBytesPerSecond = 0
        speedSamples = []
        currentItemID = nil
        resetETA()
        resetIOTracking()
    }

    /// Drops the estimate so a re-run doesn't inherit the previous run's countdown.
    private func resetETA() {
        etaSmoother.reset()
        if etaText != nil { etaText = nil }
        secondsRemaining = nil
    }

    private func resetIOTracking() {
        speedHistory = []
        readSpeedNow = 0
        writeSpeedNow = 0
        readBytesTotal = 0
        writeBytesTotal = 0
        ioBaseline = nil
        lastIOSample = nil
        emaRead = 0
        emaWrite = 0
        hasEMA = false
    }

    func exportChecksums() {
        let manifest = ChecksumManifest.build(from: items, algorithm: algorithm)
        guard manifest.includedCount > 0 else {
            if manifest.excludedFailedCount > 0 {
                QueueViewModel.shared.alertMessage = "Nothing to save — all "
                    + "\(manifest.excludedFailedCount) hashed file(s) failed verification, "
                    + "so none can be listed as good."
            }
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "checksums.\(algorithm.manifestExtension)"
        panel.title = "Save Checksum Manifest"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try manifest.text.write(to: url, atomically: true, encoding: .utf8)
            if manifest.excludedFailedCount > 0 || manifest.unverifiedCount > 0 {
                var notes: [String] = ["Saved \(manifest.includedCount) checksum(s) to \(url.lastPathComponent)."]
                if manifest.excludedFailedCount > 0 {
                    notes.append("⚠️ \(manifest.excludedFailedCount) file(s) that FAILED verification were "
                        + "left out — their destination copy does not match the source, so they were not "
                        + "recorded as good.")
                }
                if manifest.unverifiedCount > 0 {
                    notes.append("\(manifest.unverifiedCount) file(s) were copied with verification off; "
                        + "their hashes come from the source and the destination was not read back.")
                }
                QueueViewModel.shared.alertMessage = notes.joined(separator: "\n\n")
            }
        } catch {
            QueueViewModel.shared.alertMessage = "Could not save manifest: \(error.localizedDescription)"
        }
    }
}
