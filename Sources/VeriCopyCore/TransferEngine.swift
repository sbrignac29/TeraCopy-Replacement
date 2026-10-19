import Foundation
import Darwin

/// Executes a transfer plan: chunked copy with streaming checksum, an independent
/// read-back verification pass (bypassing the disk cache), move and verify-only modes,
/// pause/resume/cancel, and per-file error isolation — one bad file never aborts the job.
public final class TransferEngine {

    private static let chunkSize = 8 << 20 // 8 MiB

    /// Dedicated queue for blocking POSIX file I/O (read/write/fsync). Swift's structured-
    /// concurrency cooperative thread pool is sized to the number of cores and is shared with
    /// every other async task in the app, including @MainActor UI updates — it must never be
    /// blocked by a synchronous syscall, or unrelated work (including our own progress
    /// callbacks) can stall waiting for a thread the pool can't grow to provide. Routing every
    /// read()/write()/fsync() through a GCD queue (whose pool grows on demand, unlike Swift's
    /// fixed one) keeps the double-buffered pipeline genuinely concurrent and keeps the app
    /// responsive while a transfer runs.
    private static let ioQueue = DispatchQueue(label: "com.vericopy.io", qos: .userInitiated, attributes: .concurrent)

    /// Bytes written between forced flushes of a large file. Without this, macOS can buffer
    /// a large backlog of writes in the page cache and only pay for it all at once near the
    /// end of a big copy — surfacing as a throughput cliff partway through. Flushing
    /// periodically keeps throughput (and the live speed reading) representative of real
    /// disk performance throughout the transfer instead of a burst of "free" memory-speed
    /// writes followed by a stall.
    private static let flushInterval: Int64 = 256 << 20 // 256 MiB

    /// Files below this get the cheap path: no preallocation, right-sized buffers.
    private static let smallFileThreshold = 1 << 20 // 1 MiB
    private static let minBufferSize = 64 << 10     // 64 KiB

    /// Don't show a time estimate before this much of the job has gone by. An estimate drawn
    /// from the first instant of a transfer is worse than no estimate at all.
    private static let estimateGraceSeconds: TimeInterval = 3
    private static let estimateGraceFiles = 8
    private static let estimateGraceFraction = 0.02

    /// Buffer big enough for the file, capped at `chunkSize`. A whole XMP sidecar fits in
    /// the minimum, so copying one no longer allocates megabytes.
    private static func bufferSize(for expectedSize: Int64) -> Int {
        guard expectedSize > 0 else { return minBufferSize }
        if expectedSize >= Int64(chunkSize) { return chunkSize }
        return max(minBufferSize, Int(expectedSize))
    }

    private let lock = NSLock()
    private var pausedFlag = false
    private var cancelledFlag = false

    /// Test hook: pretend source and destination are on different volumes so
    /// move mode exercises the copy+verify+delete path.
    private let forceCrossVolume: Bool

    /// Reports free bytes on the volume containing a URL, or nil if unknown. Injectable for tests.
    private let capacityProvider: (URL) -> Int64?

    /// How much per-file metadata to carry to the destination.
    private let metadataPolicy: MetadataPolicy

    /// What a previous job onto this destination learned about its speed, if anything.
    private let estimatorSeed: TransferEstimator.Snapshot?

    /// Whether to read a file back while the next one is being copied. nil decides from the
    /// destination: worth doing on flash, actively harmful on a single spinning disk, where it
    /// makes the head alternate between the region being written and the region being read.
    /// Measured on an ExFAT USB disk, concurrent access to one drive cost roughly two thirds of
    /// its throughput, so the fallback when the device won't identify itself is "don't".
    private let overlapVerification: Bool?

    public init(forceCrossVolume: Bool = false,
                capacityProvider: ((URL) -> Int64?)? = nil,
                metadataPolicy: MetadataPolicy = .native,
                estimatorSeed: TransferEstimator.Snapshot? = nil,
                overlapVerification: Bool? = nil) {
        self.forceCrossVolume = forceCrossVolume
        self.capacityProvider = capacityProvider ?? Self.systemAvailableCapacity
        self.metadataPolicy = metadataPolicy
        self.estimatorSeed = estimatorSeed
        self.overlapVerification = overlapVerification
    }

    /// Free space on the volume holding `url`. `volumeAvailableCapacityForImportantUsage`
    /// is APFS-only and reports 0 on ExFAT/FAT32/NTFS/network volumes, so it is only
    /// trusted when positive; otherwise fall back to the standard capacity key, then statfs.
    /// Returns nil when no API can report a value — callers must not refuse the job on nil.
    public static func systemAvailableCapacity(at url: URL) -> Int64? {
        if let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let basic = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity, basic > 0 {
            return Int64(basic)
        }
        if let free = ((try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize]
                       as? NSNumber)?.int64Value, free > 0 {
            return free
        }
        return nil
    }

    // MARK: - Control

    public func pause() { lock.withLock { pausedFlag = true } }
    public func resume() { lock.withLock { pausedFlag = false } }
    public func cancel() { lock.withLock { cancelledFlag = true; pausedFlag = false } }

    public var isPaused: Bool { lock.withLock { pausedFlag } }
    public var isCancelled: Bool { lock.withLock { cancelledFlag } }

    /// Blocks (async) while paused; throws once cancelled.
    private func checkpoint() async throws {
        while true {
            let (paused, cancelled) = lock.withLock { (pausedFlag, cancelledFlag) }
            if cancelled { throw TransferError.cancelled }
            if !paused { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Cheap filesystem probes
    //
    // `FileManager.attributesOfItem` builds an NSDictionary and resolves owner and group
    // *names*, which on an ExFAT volume measured 231 µs — to answer questions `lstat`
    // answers in about 1 µs. None of these paths ever needed the dictionary.

    @inline(__always)
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    @inline(__always)
    private static func size(ofDescriptor fd: Int32) -> Int64? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return Int64(info.st_size)
    }

    // MARK: - Main entry point

    public func run(plan: TransferPlan,
                    mode: TransferMode,
                    algorithm: HashAlgorithm,
                    destinationRoot: URL,
                    verification: VerificationPolicy = .perFile,
                    delegate: TransferEngineDelegate) async -> TransferSummary {
        // Progress leaves the copy loop through this pump, never by awaiting the delegate
        // directly — see ProgressPump for why.
        let pump = ProgressPump(delegate: delegate)
        pump.start()
        let summary = await execute(plan: plan, mode: mode, algorithm: algorithm,
                                    destinationRoot: destinationRoot, verification: verification,
                                    delegate: delegate, pump: pump)
        await pump.shutdown()
        return summary
    }

    // swiftlint:disable:next function_body_length
    private func execute(plan: TransferPlan,
                         mode: TransferMode,
                         algorithm: HashAlgorithm,
                         destinationRoot: URL,
                         verification: VerificationPolicy,
                         delegate: TransferEngineDelegate,
                         pump: ProgressPump) async -> TransferSummary {
        let fm = FileManager.default
        let start = Date()
        var summary = TransferSummary()
        var items = plan.items
        var stickyChoice: ConflictChoice?

        let capabilities = VolumeCapabilities.probe(at: destinationRoot)
        let carriesExtendedMetadata = metadataPolicy.carriesExtendedMetadata(to: capabilities)
        // Read file N back while file N+1 copies. The two touch different devices for their
        // reads, but both touch the destination — so this only pays where that destination can
        // service a mixed queue. See `overlapVerification`.
        let pipelineVerification = (overlapVerification ?? (capabilities.solidState == true))
            && verification == .perFile && mode != .verify
        var estimator = estimatorSeed.map(TransferEstimator.init(restoring:)) ?? TransferEstimator()

        // Items whose verification is deferred to the end-of-job pass.
        struct DeferredEntry {
            let index: Int
            let destination: URL
            let deleteSourceAfterVerify: Bool
        }
        var deferred: [DeferredEntry] = []

        // ── Work ledger ────────────────────────────────────────────────────
        // Progress runs on *work* — copy bytes plus the verification read-back that follows
        // them — so the bar and the estimate span the whole job and never restart when the
        // phase changes. `data` tracks bytes landed at the destination, for the "x of y" text.
        let verifies = verification != .off
        var plannedCopy = [Int64](repeating: 0, count: items.count)
        var plannedVerify = [Int64](repeating: 0, count: items.count)
        var copyWorkTotal: Int64 = 0, verifyWorkTotal: Int64 = 0
        var copyFilesTotal = 0, verifyFilesTotal = 0
        var bytesNeeded: Int64 = 0

        for index in items.indices {
            let item = items[index]
            if !item.isSymlink {
                if mode == .verify {
                    plannedVerify[index] = item.size
                } else if mode == .copy || forceCrossVolume || !sameVolume(item.sourceURL, destinationRoot) {
                    // Anything else is a same-volume move: a rename, so no data is streamed
                    // and there is nothing to read back.
                    bytesNeeded += item.size
                    plannedCopy[index] = item.size
                    if verifies { plannedVerify[index] = item.size }
                }
            }
            if plannedCopy[index] > 0 { copyWorkTotal += plannedCopy[index]; copyFilesTotal += 1 }
            if plannedVerify[index] > 0 { verifyWorkTotal += plannedVerify[index]; verifyFilesTotal += 1 }
        }

        var copySettled: Int64 = 0, verifySettled: Int64 = 0
        var copyFilesDone = 0, verifyFilesDone = 0
        var copyInFlight: Int64 = 0
        var dataSettled: Int64 = 0
        var inVerificationPhase = false
        // Read-back bytes of the file currently being verified. A locked box rather than a
        // plain local because a pipelined verification reports from its own task while this
        // loop is still copying the next file.
        let verifyInFlight = ByteCounter()

        func publish() {
            let verifying = verifyInFlight.bytes
            var progress = TransferProgress()
            progress.workTotal = copyWorkTotal + verifyWorkTotal
            progress.workDone = min(copySettled + copyInFlight + verifySettled + verifying,
                                    progress.workTotal)
            progress.dataTotal = plan.totalBytes
            progress.dataCopied = min(dataSettled + copyInFlight, plan.totalBytes)
            progress.isVerifying = inVerificationPhase || verifying > 0

            let elapsed = Date().timeIntervalSince(start)
            let warm = estimator.observationCount >= Self.estimateGraceFiles
                || (progress.workTotal > 0
                    && Double(progress.workDone) / Double(progress.workTotal) >= Self.estimateGraceFraction)
            if warm, elapsed >= Self.estimateGraceSeconds {
                progress.secondsRemaining = estimator.secondsRemaining(
                    copyBytes: copyWorkTotal - copySettled - copyInFlight,
                    copyFiles: copyFilesTotal - copyFilesDone,
                    verifyBytes: verifyWorkTotal - verifySettled - verifying,
                    verifyFiles: verifyFilesTotal - verifyFilesDone)
            }
            pump.record(progress: progress)
        }

        /// Credits the copy half of an item: its bytes are on the destination.
        func creditCopy(_ index: Int) {
            if plannedCopy[index] > 0 { copySettled += plannedCopy[index]; copyFilesDone += 1 }
            dataSettled += items[index].size
            copyInFlight = 0
            publish()
        }

        /// Credits the read-back half. Separate from the copy half because with pipelining the
        /// two halves of one file are credited at different points, around another file's copy.
        func creditVerify(_ index: Int) {
            if plannedVerify[index] > 0 { verifySettled += plannedVerify[index]; verifyFilesDone += 1 }
            verifyInFlight.set(0)
            publish()
        }

        /// Credits an item's whole planned work, whatever its outcome, so the bar always
        /// reaches the end — a skipped or failed file still removes work from the job.
        func settle(_ index: Int) {
            creditCopy(index)
            creditVerify(index)
        }

        publish()

        // Pre-flight: enough free space for the data we will actually write?
        if mode != .verify {
            if bytesNeeded > 0,
               let capacity = capacityProvider(destinationRoot),
               capacity < bytesNeeded {
                let needed = ByteCountFormatter.string(fromByteCount: bytesNeeded, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
                summary.fatalError = "Not enough free space on the destination volume: \(needed) needed, \(free) available."
                return summary
            }

            for relative in plan.directories {
                let dir = destinationRoot.appendingPathComponent(relative)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    summary.fatalError = "Could not create folder \(relative): \(error.localizedDescription)"
                    return summary
                }
            }
        }

        // ── Pipelined verification ─────────────────────────────────────────
        var pending: PipelinedVerification?

        /// Starts reading a freshly-copied file back, and returns immediately so the caller can
        /// get on with the next file's copy.
        func launchVerification(_ index: Int, destination: URL, deleteSource: Bool) -> PipelinedVerification? {
            guard let expected = items[index].checksum else { return nil }
            var snapshot = items[index]
            snapshot.status = .verifying
            snapshot.bytesCopied = 0
            items[index] = snapshot
            pump.record(item: snapshot, at: index)
            verifyInFlight.set(0)

            let counter = verifyInFlight
            let task = Task { [weak self] () throws -> String in
                guard let self else { throw TransferError.cancelled }
                var live = snapshot
                return try await self.hashFile(destination, algorithm: algorithm, bypassCache: true) { bytes in
                    counter.set(bytes)
                    live.bytesCopied = bytes
                    pump.record(item: live, at: index)
                }
            }
            return PipelinedVerification(index: index, size: items[index].size,
                                         expectedHash: expected,
                                         deleteSourceAfterVerify: deleteSource,
                                         began: Date(), task: task)
        }

        /// Collects a read-back that has been running underneath the last copy, and settles the
        /// file's verdict.
        func collectVerification(_ entry: PipelinedVerification) async {
            var item = items[entry.index]
            do {
                let actual = try await entry.task.value
                guard actual == entry.expectedHash else {
                    throw TransferError.checksumMismatch(expected: entry.expectedHash, actual: actual)
                }
                item.status = .done
                item.message = "\(algorithm.rawValue) verified"
                item.bytesCopied = item.size
                if entry.deleteSourceAfterVerify {
                    try FileManager.default.removeItem(at: item.sourceURL)
                }
                estimator.record(phase: .verify, bytes: entry.size,
                                 seconds: Date().timeIntervalSince(entry.began))
                summary.succeeded += 1
            } catch where Self.isCancellation(error) {
                item.status = .doneNoVerify
                item.message = "Copied (not verified — cancelled)"
                item.bytesCopied = item.size
                summary.succeeded += 1
            } catch {
                item.status = .failed
                item.message = error.localizedDescription
                item.bytesCopied = item.size
                summary.failed += 1
            }
            items[entry.index] = item
            pump.record(item: item, at: entry.index)
            creditVerify(entry.index)
        }

        // Per-file loop. Errors are contained to the file; cancellation breaks out.
        itemLoop: for index in items.indices {
            if isCancelled { break }

            var destination = destinationRoot.appendingPathComponent(items[index].relativePath)

            do {
                switch mode {
                case .verify:
                    let began = Date()
                    try await verifyItem(&items[index], destination: destination, algorithm: algorithm,
                                         index: index, pump: pump,
                                         onProgress: { bytes in
                                             verifyInFlight.set(bytes)
                                             publish()
                                         })
                    estimator.record(phase: .verify, bytes: items[index].size,
                                     seconds: Date().timeIntervalSince(began))
                    // verifyItem sets the final status (.done/.doneNoVerify, or .failed for a
                    // symlink-target mismatch it handles without throwing). Push that final state
                    // to the UI and update the tallies — otherwise good files stay stuck showing
                    // "Verifying…" and the overall progress never completes.
                    if items[index].status == .failed {
                        summary.failed += 1
                    } else {
                        summary.succeeded += 1
                    }
                    pump.record(item: items[index], at: index)
                    settle(index)

                case .copy, .move:
                    // Conflict handling (lstat-style existence check so broken symlinks count too).
                    var overwriting = false
                    if Self.exists(destination.path) {
                        let resolution: ConflictResolution
                        if let sticky = stickyChoice {
                            resolution = ConflictResolution(choice: sticky, applyToAll: true)
                        } else {
                            // The prompt is modal to the user — make sure everything already
                            // observed is on screen before it appears.
                            await pump.flush()
                            resolution = await delegate.engineResolveConflict(item: items[index], existingURL: destination)
                        }
                        if resolution.applyToAll { stickyChoice = resolution.choice }

                        switch resolution.choice {
                        case .skip:
                            items[index].status = .skipped
                            items[index].message = "Already exists in destination"
                            summary.skipped += 1
                            pump.record(item: items[index], at: index)
                            settle(index)
                            continue itemLoop
                        case .keepBoth:
                            destination = Self.availableURL(for: destination)
                            items[index].destinationName = destination.lastPathComponent
                        case .overwrite:
                            overwriting = true
                        }
                    }

                    var verdictPending = false
                    if items[index].isSymlink {
                        try copySymlink(items[index].sourceURL, to: destination,
                                        overwriting: overwriting, removeSource: mode == .move)
                        items[index].status = .doneNoVerify
                        items[index].message = mode == .move ? "Symlink moved" : "Symlink copied"
                    } else if mode == .move && !forceCrossVolume && sameVolume(items[index].sourceURL, destinationRoot) {
                        if overwriting { try fm.removeItem(at: destination) }
                        try fm.moveItem(at: items[index].sourceURL, to: destination)
                        items[index].status = .doneNoVerify
                        items[index].message = "Moved on same volume (rename, no data rewritten)"
                        items[index].bytesCopied = items[index].size
                    } else {
                        // While this copy runs, the previous file is being read back — so the
                        // copy itself must not also verify. `copyAndVerify` is told to defer.
                        let copyPolicy = pipelineVerification ? .afterAll : verification
                        let timings = try await copyAndVerify(
                            &items[index], destination: destination,
                            overwriting: overwriting, algorithm: algorithm,
                            policy: copyPolicy, index: index, pump: pump,
                            carriesExtendedMetadata: carriesExtendedMetadata,
                            onCopyProgress: { bytes in
                                copyInFlight = bytes
                                publish()
                            },
                            onVerifyProgress: { bytes in
                                copyInFlight = plannedCopy[index]
                                verifyInFlight.set(bytes)
                                publish()
                            })
                        estimator.record(phase: .copy, bytes: items[index].size,
                                         seconds: timings.copySeconds)
                        if let verifySeconds = timings.verifySeconds {
                            estimator.record(phase: .verify, bytes: items[index].size,
                                             seconds: verifySeconds)
                        }

                        if pipelineVerification {
                            // The previous file's read-back ran underneath the copy above;
                            // take its verdict now, then start this file's.
                            if let entry = pending {
                                pending = nil
                                await collectVerification(entry)
                            }
                            creditCopy(index)
                            summary.bytesCopied += items[index].size
                            pending = launchVerification(index, destination: destination,
                                                         deleteSource: mode == .move)
                            if pending == nil {
                                // No checksum to compare against — nothing to verify.
                                items[index].status = .doneNoVerify
                                items[index].message = "Copied (no checksum captured)"
                                summary.succeeded += 1
                                pump.record(item: items[index], at: index)
                                creditVerify(index)
                            }
                            continue itemLoop
                        }

                        if verification == .afterAll {
                            // Verdict (and, for moves, source deletion) waits for the verification pass.
                            deferred.append(DeferredEntry(index: index, destination: destination,
                                                          deleteSourceAfterVerify: mode == .move))
                            verdictPending = true
                        } else if mode == .move {
                            // Source is deleted only after the copy completed (and verified, per policy).
                            try fm.removeItem(at: items[index].sourceURL)
                        }
                    }

                    if !verdictPending { summary.succeeded += 1 }
                    summary.bytesCopied += items[index].size
                    pump.record(item: items[index], at: index)
                    if verification == .afterAll && plannedVerify[index] > 0 {
                        // Only the copy half is finished; the read-back is still owed.
                        creditCopy(index)
                    } else {
                        settle(index)
                    }
                }
            } catch is CancellationError {
                markCancelled(&items[index]); pump.record(item: items[index], at: index); settle(index); break
            } catch TransferError.cancelled {
                markCancelled(&items[index]); pump.record(item: items[index], at: index); settle(index); break
            } catch {
                items[index].status = .failed
                items[index].message = error.localizedDescription
                summary.failed += 1
                pump.record(item: items[index], at: index)
                settle(index)
            }
        }

        // Whatever ended the loop — completion, cancellation, or a fatal error on the last
        // file — a read-back may still be running underneath it.
        if let entry = pending {
            pending = nil
            await collectVerification(entry)
        }

        func settleUnverifiedAfterCancel() {
            for entry in deferred where items[entry.index].status == .copied || items[entry.index].status == .verifying {
                items[entry.index].status = .doneNoVerify
                items[entry.index].message = "Copied (not verified — cancelled)"
                items[entry.index].bytesCopied = items[entry.index].size
                summary.succeeded += 1
                pump.record(item: items[entry.index], at: entry.index)
            }
        }

        if isCancelled {
            summary.cancelled = true
            for index in items.indices where items[index].status == .pending {
                markCancelled(&items[index])
                pump.record(item: items[index], at: index)
            }
            settleUnverifiedAfterCancel()
        } else if !deferred.isEmpty {
            // ── Phase 2: end-of-job verification pass ──────────────────────────
            // Every copied file is read back from the destination disk and compared
            // against the checksum captured while copying. For moves, the source is
            // deleted only here, after its copy proves clean.
            inVerificationPhase = true
            let verifyTotal = deferred.reduce(Int64(0)) { $0 + items[$1.index].size }
            await pump.flush()
            await delegate.engineDidBeginVerificationPhase(fileCount: deferred.count, totalBytes: verifyTotal)

            verifyLoop: for entry in deferred {
                var item = items[entry.index]
                item.status = .verifying
                item.bytesCopied = 0
                items[entry.index] = item
                pump.record(item: item, at: entry.index)

                let began = Date()
                do {
                    let destinationHex = try await hashFile(entry.destination, algorithm: algorithm,
                                                            bypassCache: true) { bytes in
                        item.bytesCopied = bytes
                        items[entry.index] = item
                        pump.record(item: item, at: entry.index)
                        verifyInFlight.set(bytes)
                        publish()
                    }
                    item.bytesCopied = item.size
                    guard destinationHex == item.checksum else {
                        throw TransferError.checksumMismatch(expected: item.checksum ?? "?", actual: destinationHex)
                    }
                    item.status = .done
                    item.message = "\(algorithm.rawValue) verified"
                    if entry.deleteSourceAfterVerify {
                        try fm.removeItem(at: item.sourceURL)
                    }
                    estimator.record(phase: .verify, bytes: item.size,
                                     seconds: Date().timeIntervalSince(began))
                    summary.succeeded += 1
                } catch where Self.isCancellation(error) {
                    summary.cancelled = true
                    items[entry.index] = item
                    settleUnverifiedAfterCancel()
                    break verifyLoop
                } catch {
                    item.status = .failed
                    item.message = error.localizedDescription
                    item.bytesCopied = item.size
                    summary.failed += 1
                }

                items[entry.index] = item
                pump.record(item: item, at: entry.index)
                verifySettled += plannedVerify[entry.index]
                if plannedVerify[entry.index] > 0 { verifyFilesDone += 1 }
                verifyInFlight.set(0)
                publish()
            }
            inVerificationPhase = false
        }

        // Copy folder metadata (dates, permissions, xattrs) deepest-first so parents are stamped last,
        // then — for moves — remove source folders that are now empty.
        if mode != .verify && !summary.cancelled {
            let byDepth = plan.directorySources.sorted {
                $0.relative.components(separatedBy: "/").count > $1.relative.components(separatedBy: "/").count
            }
            for entry in byDepth {
                let destDir = destinationRoot.appendingPathComponent(entry.relative)
                copyMetadata(from: entry.source, to: destDir, extended: carriesExtendedMetadata)
            }
            if mode == .move {
                for entry in byDepth {
                    removeDirectoryIfEmpty(entry.source)
                }
            }
        }

        summary.elapsed = Date().timeIntervalSince(start)
        summary.estimatorSnapshot = estimator.snapshot
        copyInFlight = 0
        verifyInFlight.set(0)
        copySettled = copyWorkTotal
        verifySettled = verifyWorkTotal
        dataSettled = plan.totalBytes
        publish()
        await pump.flush()
        return summary
    }

    private func markCancelled(_ item: inout FileItem) {
        item.status = .skipped
        item.message = "Cancelled"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TransferError.cancelled = error { return true }
        return false
    }

    // MARK: - Copy + verify

    /// How long each phase of one file took, so the caller can fold it into the estimator.
    /// Returned rather than recorded here: the progress closures read the estimator to publish
    /// an ETA, and holding it `inout` across this call would overlap that read.
    struct PhaseTimings {
        var copySeconds: TimeInterval = 0
        var verifySeconds: TimeInterval?
    }

    private func copyAndVerify(_ item: inout FileItem,
                               destination: URL,
                               overwriting: Bool,
                               algorithm: HashAlgorithm,
                               policy: VerificationPolicy,
                               index: Int,
                               pump: ProgressPump,
                               carriesExtendedMetadata: Bool,
                               onCopyProgress: (Int64) -> Void,
                               onVerifyProgress: (Int64) -> Void) async throws -> PhaseTimings {
        let fm = FileManager.default
        item.status = .copying
        pump.record(item: item, at: index)

        // Write into a hidden partial file, then rename into place. The final path
        // never holds a half-written file, even if the app dies mid-copy.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).vcpart")
        try? fm.removeItem(at: partial)

        let copyBegan = Date()
        let sourceHex: String
        do {
            sourceHex = try await copyChunked(from: item.sourceURL, to: partial,
                                              expectedSize: item.size, algorithm: algorithm,
                                              stampMetadataOnDescriptor: !carriesExtendedMetadata,
                                              flushBeforeReadBack: policy != .off) { bytes in
                item.bytesCopied = bytes
                pump.record(item: item, at: index)
                onCopyProgress(bytes)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        // On a volume that stores xattrs and ACLs itself, carry them. On one that does not,
        // `copyChunked` already stamped permissions and timestamps onto the open descriptor —
        // going through copyfile here would make macOS write an AppleDouble "._" twin for
        // every file, which measured 5.5 ms each on ExFAT against 0.4 ms for the stamp.
        if carriesExtendedMetadata {
            copyMetadata(from: item.sourceURL, to: partial, extended: true)
        }

        do {
            if overwriting, Self.exists(destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        var timings = PhaseTimings(copySeconds: Date().timeIntervalSince(copyBegan))

        item.bytesCopied = item.size
        item.checksum = sourceHex

        switch policy {
        case .off:
            item.status = .doneNoVerify
            item.message = "Copied (verification off)"
            return timings
        case .afterAll:
            item.status = .copied
            item.message = "Copied — verification queued"
            return timings
        case .perFile:
            break
        }

        item.status = .verifying
        item.bytesCopied = 0
        pump.record(item: item, at: index)

        // Independent read-back with the unified buffer cache bypassed, so we verify
        // what actually landed on disk rather than what the cache remembers.
        let verifyBegan = Date()
        let destinationHex = try await hashFile(destination, algorithm: algorithm, bypassCache: true) { bytes in
            item.bytesCopied = bytes
            pump.record(item: item, at: index)
            onVerifyProgress(bytes)
        }
        timings.verifySeconds = Date().timeIntervalSince(verifyBegan)
        item.bytesCopied = item.size
        guard destinationHex == sourceHex else {
            throw TransferError.checksumMismatch(expected: sourceHex, actual: destinationHex)
        }

        item.status = .done
        item.message = "\(algorithm.rawValue) verified"
        return timings
    }

    /// Pipelined copy: while chunk N is being hashed and written, chunk N+1 is already
    /// being read on a child task into a second buffer. Two reusable page-aligned buffers,
    /// zero per-chunk allocations. Throws only after the in-flight read-ahead has landed,
    /// so a buffer is never freed while a read into it is still running.
    private func copyChunked(from source: URL,
                             to destination: URL,
                             expectedSize: Int64,
                             algorithm: HashAlgorithm,
                             stampMetadataOnDescriptor: Bool,
                             flushBeforeReadBack: Bool,
                             onProgress: (Int64) -> Void) async throws -> String {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw TransferError.cannotCreateFile(destination.path)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        _ = fcntl(input.fileDescriptor, F_RDAHEAD, 1)
        // Preallocation only pays off for files big enough to fragment; on a folder of
        // small sidecars it's a wasted fcntl per file.
        let isLargeFile = expectedSize >= Int64(Self.smallFileThreshold)
        if isLargeFile {
            Self.preallocate(output.fileDescriptor, size: expectedSize)
        }

        // Write straight through to the device rather than through the unified buffer cache.
        //
        // Two reasons, and the second is the important one. A 1.5 TB copy that goes through the
        // cache evicts everything else the machine had resident. And a file that is still in the
        // cache when the verification pass reads it back is verified against memory, not against
        // the platter — F_NOCACHE on the *read* side cannot fix that, because it only stops that
        // descriptor from filling the cache; it does not evict pages the write already put there.
        // Bypassing on the way in is what makes the read-back a real check of what landed.
        //
        // Costs about 10% of write throughput (measured 174.5 vs 195 MB/s on ExFAT over USB).
        // Left off below the threshold: sidecars are cheap to re-read, and forcing every 4 KB
        // file to the device would be a poor trade on a folder of tens of thousands of them.
        let bypassWriteCache = isLargeFile
        if bypassWriteCache {
            _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)
        }

        let inFD = input.fileDescriptor
        let outFD = output.fileDescriptor
        let hasher = algorithm.makeHasher()
        // Size the buffers to the file. Always allocating two 8 MiB blocks meant a 4 KB XMP
        // sidecar cost 16 MiB of page-aligned allocation to copy (and another 16 MiB to
        // verify) — pure overhead repeated tens of thousands of times on a photo ingest.
        let bufferSize = Self.bufferSize(for: expectedSize)
        var front = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16384)
        var back = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16384)
        defer { front.deallocate(); back.deallocate() }

        var total: Int64 = 0
        var sinceLastFlush: Int64 = 0
        var frontLength = try (await Self.readFull(inFD, into: front)).get()

        while frontLength > 0 {
            try await checkpoint()
            let readTarget = back
            async let pendingRead = Self.readFull(inFD, into: readTarget)
            // Hash and write the same chunk at the same time. Neither mutates the buffer, so
            // they can share it; previously the hash ran to completion before the write was
            // even issued, making the per-chunk cost read ∥ (hash + write) instead of
            // read ∥ hash ∥ write. Worth a few percent against a 195 MB/s USB disk and 30-40%
            // when both ends are fast local volumes.
            let hashTarget = front
            let hashLength = frontLength
            async let pendingHash: Void = Self.hashChunk(hasher, hashTarget, count: hashLength)

            let writeError = await Self.writeFull(outFD, from: front, count: frontLength)
            if writeError == nil {
                total += Int64(frontLength)
                sinceLastFlush += Int64(frontLength)
                onProgress(total)
            }

            // Land both children before any throw, so a buffer is never freed while a read or
            // a hash is still running in it.
            await pendingHash
            let readResult = await pendingRead
            if let writeError { throw writeError }

            // Periodic flush exists only to stop the OS write-behind cache from ballooning and
            // dumping the whole backlog at once near the end of a big copy. With F_NOCACHE there
            // is no backlog to dump, and the flush would be pure cost — on a drive doing internal
            // rewrites (SMR) an fsync can block for seconds, thousands of times over a large job.
            if !bypassWriteCache, sinceLastFlush >= Self.flushInterval {
                await Self.flush(outFD)
                sinceLastFlush = 0
            }

            swap(&front, &back)
            frontLength = try readResult.get()
        }

        // Stamp after the final write — writing bumps the modification time — and before the
        // flush, so the metadata lands with the data.
        if stampMetadataOnDescriptor {
            Self.stampBasicMetadata(from: inFD, onto: outFD)
        }

        // The flush exists so the verification pass reads the platter rather than a
        // write-behind buffer. With no verification to come it buys nothing, and on ExFAT it
        // is the single most expensive thing in a small-file copy — measured at roughly 9 ms
        // per file against 3.7 ms for the whole write. Let the OS write out on its own
        // schedule then, which is what cp and Finder do.
        if flushBeforeReadBack {
            try? output.synchronize()
        }
        return hasher.finalizedHex()
    }

    /// Pipelined hash: chunk N+1 is read while chunk N is hashed.
    private func hashFile(_ url: URL,
                          algorithm: HashAlgorithm,
                          bypassCache: Bool,
                          onProgress: (Int64) -> Void = { _ in }) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fd = handle.fileDescriptor
        // F_NOCACHE keeps this read from filling the page cache; F_RDAHEAD still lets the
        // kernel prefetch ahead of us. They are not alternatives — the read-back wants both.
        if bypassCache { _ = fcntl(fd, F_NOCACHE, 1) }
        _ = fcntl(fd, F_RDAHEAD, 1)

        let hasher = algorithm.makeHasher()
        // Right-size to the file, as in copyChunked — the verification pass would otherwise
        // allocate 16 MiB to read back a 4 KB sidecar. `fstat` on the descriptor we already
        // hold, rather than a path lookup that rebuilds the whole attribute dictionary.
        let fileSize = Self.size(ofDescriptor: fd)
        let bufferSize = Self.bufferSize(for: fileSize ?? Int64(Self.chunkSize))
        var front = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16384)
        var back = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16384)
        defer { front.deallocate(); back.deallocate() }

        var total: Int64 = 0
        var frontLength = try (await Self.readFull(fd, into: front)).get()

        while frontLength > 0 {
            try await checkpoint()
            let readTarget = back
            async let pendingRead = Self.readFull(fd, into: readTarget)
            let hashTarget = front
            let hashLength = frontLength
            async let pendingHash: Void = Self.hashChunk(hasher, hashTarget, count: hashLength)

            total += Int64(frontLength)
            onProgress(total)

            await pendingHash
            let readResult = await pendingRead
            swap(&front, &back)
            frontLength = try readResult.get()
        }
        return hasher.finalizedHex()
    }

    // MARK: - Raw I/O primitives

    /// Wraps a raw buffer pointer so it can cross the `@Sendable` boundary into `ioQueue`'s
    /// closure. Safe here: each read/write call owns its buffer exclusively for the call's
    /// duration — the two chunks in flight during pipelining are always distinct allocations,
    /// never aliased, so there is no real data race for the compiler to have caught.
    private struct UnsafeBufferBox: @unchecked Sendable {
        let buffer: UnsafeMutableRawBufferPointer
    }

    /// Reads until the buffer is full or EOF. The blocking syscall runs on `ioQueue`, never
    /// on Swift's cooperative pool. Never throws so it can run as a read-ahead child task
    /// whose failure is surfaced only when awaited.
    private static func readFull(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) async -> Result<Int, Error> {
        let box = UnsafeBufferBox(buffer: buffer)
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                let buffer = box.buffer
                var offset = 0
                while offset < buffer.count {
                    let n = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n == 0 { break }
                    if n < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(returning: .failure(Self.posixError("Reading", errno)))
                        return
                    }
                    offset += n
                }
                continuation.resume(returning: .success(offset))
            }
        }
    }

    /// Writes the full buffer. The blocking syscall runs on `ioQueue`, never on Swift's
    /// cooperative pool — see `readFull`.
    private static func writeFull(_ fd: Int32, from buffer: UnsafeMutableRawBufferPointer, count: Int) async -> Error? {
        let box = UnsafeBufferBox(buffer: buffer)
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                let buffer = box.buffer
                var offset = 0
                while offset < count {
                    let n = write(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(returning: Self.posixError("Writing", errno))
                        return
                    }
                    offset += n
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// A byte count written by one task and read by another. Used for the read-back progress
    /// of a pipelined verification, which runs while the copy loop is on the next file.
    final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int64 = 0
        var bytes: Int64 { lock.withLock { count } }
        func set(_ value: Int64) { lock.withLock { count = value } }
    }

    /// One file's read-back running alongside the next file's copy.
    private struct PipelinedVerification {
        let index: Int
        let size: Int64
        let expectedHash: String
        let deleteSourceAfterVerify: Bool
        let began: Date
        let task: Task<String, Error>
    }

    /// Carries a hasher into `ioQueue`'s closure. Safe: exactly one hash runs at a time — the
    /// caller awaits each chunk's hash before starting the next — so the hasher is never
    /// touched concurrently, only from a different thread than the one that made it.
    private struct HasherBox: @unchecked Sendable {
        let hasher: StreamingHasher
    }

    /// Hashes one chunk off the cooperative pool, so it can run alongside the write of the
    /// same buffer instead of in front of it.
    private static func hashChunk(_ hasher: StreamingHasher,
                                  _ buffer: UnsafeMutableRawBufferPointer,
                                  count: Int) async {
        let hasherBox = HasherBox(hasher: hasher)
        let bufferBox = UnsafeBufferBox(buffer: buffer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                hasherBox.hasher.update(buffer: UnsafeRawBufferPointer(
                    start: bufferBox.buffer.baseAddress, count: count))
                continuation.resume()
            }
        }
    }

    /// Cheap durability flush (not the heavier F_FULLFSYNC used once at the end of a copy) —
    /// just enough to keep the OS write-behind cache from ballooning during a large write.
    private static func flush(_ fd: Int32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                _ = fsync(fd)
                continuation.resume()
            }
        }
    }

    private static func posixError(_ verb: String, _ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(verb) failed: \(String(cString: strerror(code)))"])
    }

    /// Best-effort contiguous preallocation of the destination — reduces fragmentation and
    /// allocation-table churn, which matters on ExFAT/FAT32. Ignored where unsupported.
    private static func preallocate(_ fd: Int32, size: Int64) {
        guard size > 0 else { return }
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG),
                             fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0,
                             fst_length: off_t(size),
                             fst_bytesalloc: 0)
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(fd, F_PREALLOCATE, &store)
        }
    }

    // MARK: - Verify-only mode

    private func verifyItem(_ item: inout FileItem,
                            destination: URL,
                            algorithm: HashAlgorithm,
                            index: Int,
                            pump: ProgressPump,
                            onProgress: (Int64) -> Void) async throws {
        let fm = FileManager.default
        guard Self.exists(destination.path) else {
            throw TransferError.destinationMissing
        }

        if item.isSymlink {
            let sourceTarget = try fm.destinationOfSymbolicLink(atPath: item.sourceURL.path)
            let destTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path)
            guard destTarget == sourceTarget else {
                item.message = "Symlink targets differ"
                item.status = .failed
                return
            }
            item.status = .doneNoVerify
            item.message = "Symlink target matches"
            return
        }

        item.status = .verifying
        pump.record(item: item, at: index)

        var localItem = item
        let sourceHex = try await hashFile(item.sourceURL, algorithm: algorithm, bypassCache: false) { bytes in
            localItem.bytesCopied = bytes
            pump.record(item: localItem, at: index)
            onProgress(bytes)
        }
        let destinationHex = try await hashFile(destination, algorithm: algorithm, bypassCache: true)

        item.checksum = sourceHex
        item.bytesCopied = item.size
        guard sourceHex == destinationHex else {
            throw TransferError.checksumMismatch(expected: sourceHex, actual: destinationHex)
        }
        item.status = .done
        item.message = "\(algorithm.rawValue) match"
    }

    // MARK: - Helpers

    private func copySymlink(_ source: URL, to destination: URL, overwriting: Bool, removeSource: Bool) throws {
        let fm = FileManager.default
        let target = try fm.destinationOfSymbolicLink(atPath: source.path)
        if overwriting {
            try? fm.removeItem(at: destination)
        }
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        if removeSource {
            try fm.removeItem(at: source)
        }
    }

    /// Copies permissions, timestamps and — when `extended` — extended attributes and ACLs,
    /// without touching file data. Used for directories, and for files on volumes that carry
    /// extended metadata natively; everything else is stamped on the open descriptor instead.
    private func copyMetadata(from source: URL, to destination: URL, extended: Bool) {
        // COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR
        let flags = copyfile_flags_t(extended ? ((1 << 0) | (1 << 1) | (1 << 2)) : (1 << 1))
        if copyfile(source.path, destination.path, nil, flags) != 0 {
            // Fallback: at least preserve dates and permissions.
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: source.path) {
                var preserved: [FileAttributeKey: Any] = [:]
                for key: FileAttributeKey in [.creationDate, .modificationDate, .posixPermissions] {
                    if let value = attrs[key] { preserved[key] = value }
                }
                try? fm.setAttributes(preserved, ofItemAtPath: destination.path)
            }
        }
    }

    /// Carries permissions and all three timestamps straight between open descriptors.
    /// Measured at roughly 15× the speed of the `copyfile` path on an ExFAT destination,
    /// and it never creates an AppleDouble side file.
    private static func stampBasicMetadata(from source: Int32, onto destination: Int32) {
        var info = stat()
        guard fstat(source, &info) == 0 else { return }

        // Creation time needs setattrlist; futimens only carries access and modification.
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = info.st_birthtimespec
        _ = fsetattrlist(destination, &request, &created, MemoryLayout<timespec>.size, 0)

        var times = [info.st_atimespec, info.st_mtimespec]
        _ = futimens(destination, &times)
        _ = fchmod(destination, info.st_mode & 0o7777)
    }

    private func removeDirectoryIfEmpty(_ url: URL) {
        let fm = FileManager.default
        guard var contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        if contents == [".DS_Store"] {
            try? fm.removeItem(at: url.appendingPathComponent(".DS_Store"))
            contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        }
        if contents.isEmpty {
            try? fm.removeItem(at: url)
        }
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return va.isEqual(vb)
    }

    /// Finds a non-conflicting sibling name: "file 2.txt", "file 3.txt", …
    public static func availableURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !exists(candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
