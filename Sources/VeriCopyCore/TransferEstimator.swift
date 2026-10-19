import Foundation

/// Predicts how much longer a job will take.
///
/// A pure bytes-per-second model cannot describe a real ingest. A 32 KiB sidecar costs roughly
/// the same wall-clock time as a 4 KiB one — on ExFAT about 10 ms either way — because almost
/// all of it is directory and allocation-table work that has nothing to do with the byte count.
/// So a job that alternates between 512 MiB camera masters and thousands of small sidecars makes
/// a byte-rate estimate lurch: the rate collapses toward zero on the sidecars and the estimate
/// explodes, then recovers on the next master.
///
/// This models each file as a streaming cost plus a fixed cost:
///
///     t ≈ bytes / B + F
///
/// and separately for the copy and verify phases — reading back from the destination has its own
/// throughput and its own per-file cost. Remaining work is not estimated at all: `SourceScanner`
/// has already enumerated every file, so the byte and file counts left in each phase are known
/// exactly.
///
/// `B` and `F` are *not* fitted together. A joint regression lets one bleed into the other, and
/// on a mixed job it does, badly: a few hundred sidecars are enough to push every master out of
/// its memory, so `B` is read off timing noise and the next master is costed at a few MiB/s;
/// after a run of masters the reverse happens, `F` is read off the jitter in multi-second
/// timings, and a thousand sidecars are costed at most of a second each. So each is learned from
/// the files that can actually speak to it:
///
/// - `F` from small files — the average of what each cost beyond streaming its bytes.
/// - `B` from large files — bytes moved over time spent beyond the fixed cost. That is a ratio of
///   sums, not a regression slope, so it is weighted by bytes: the same way the remaining work
///   it will be applied to is weighted.
///
/// Each side forgets only when its own kind of file arrives. Ten thousand sidecars therefore
/// never erase what the masters taught about throughput, and a run of masters never erases the
/// per-file cost. Evidence about throughput ages with the time it took to gather rather than the
/// number of files, since drives drift over minutes, not over file counts.
///
/// Three more things keep it honest:
///
/// - **Outliers are trimmed, regime changes are not.** One file that stalls must not move the
///   estimate, but a drive that really has become three times slower must. Residuals that keep
///   landing well outside the noise on the same side widen the trim and speed up forgetting.
/// - **A file still in flight testifies.** Throughput is learned from a file as it runs, not
///   only when it finishes, so a 40 GiB master does not leave the estimate blind for minutes and
///   then correct it in one step.
/// - **Read-back that is hidden does not cost time.** When verification runs underneath the next
///   file's copy only the part the job had to wait for counts; see `recordOverlappedVerify`.
///
/// Storage is a handful of running sums per phase, so this is O(1) in memory and takes no
/// allocation on the hot path.
public struct TransferEstimator: Sendable {

    public enum Phase: Sendable { case copy, verify }

    /// How far a file that is still being copied or read back has got, and how long that took.
    /// `seconds` must exclude any time the job spent paused.
    public struct InFlight: Sendable {
        public var bytes: Int64
        public var seconds: TimeInterval

        public init(bytes: Int64, seconds: TimeInterval) {
            self.bytes = bytes
            self.seconds = seconds
        }
    }

    /// Prior for a freshly-created estimator: a mid-range external drive.
    public static let defaultBytesPerSecond: Double = 150 * 1024 * 1024
    public static let defaultSecondsPerFile: Double = 0.008

    private static let mib = 1_048_576.0

    // MARK: Tuning

    /// A file at least this big is streaming-dominated: it teaches `B`. Smaller ones teach `F`.
    /// The same line the engine draws between its cheap small-file path and its large-file one.
    private static let largeFileMiB = 1.0

    /// Timing noise of any single operation, and the extra proportional noise of a long one. They
    /// set how far an observation may stray from its prediction before it counts as unusual.
    private static let noiseFloor = 0.003
    private static let noiseFraction = 0.12

    /// Observations further than this many noise widths from the prediction are trimmed back.
    private static let trimWidths = 4.0
    /// Residuals beyond this many noise widths, repeatedly on the same side, are a regime change.
    private static let shiftWidths = 2.5

    /// How long evidence about throughput stays fresh, in seconds of transfer time.
    private static let throughputFreshness: TimeInterval = 120
    /// What each small file leaves of the evidence about per-file cost.
    private static let smallFileKeep = 0.99

    /// Weight of the prior, as the size of a file it is worth (large side) or a number of files
    /// (small side). Light for the generic prior; heavier for one measured on this destination.
    private static let priorMiB = 32.0
    private static let priorFiles = 2.0
    private static let restoredPriorMiB = 512.0
    private static let restoredPriorFiles = 20.0

    /// A running file is not allowed to testify before this long, and when it does the trim on
    /// its evidence is only this much looser: a single slow file must not be mistaken for a new
    /// regime.
    private static let minInFlightSeconds: TimeInterval = 1
    private static let inFlightTrimFactor = 2.0

    /// A part of the remaining work this large a share of the estimate must have been seen at
    /// work before the estimate counts as grounded.
    private static let groundedShare = 0.25

    /// How long evidence about overlap stays fresh, and how much read-back "none of it is hidden"
    /// is worth as a starting assumption. Large files count in seconds of read-back and forget by
    /// the second; small ones count in files — a few sidecars' worth, since a sidecar's read-back
    /// is milliseconds and a prior measured in seconds would outweigh hundreds of them.
    private static let overlapFreshness: TimeInterval = 120
    private static let overlapPriorSeconds = 5.0
    private static let overlapPriorFileSeconds = 0.05

    // MARK: State

    /// Where a phase's estimate starts from, and fades from as its own evidence arrives.
    private struct Prior: Sendable {
        var secondsPerMiB: Double
        var secondsPerFile: Double
        var restored: Bool

        var mib: Double {
            restored ? TransferEstimator.restoredPriorMiB : TransferEstimator.priorMiB
        }
        var files: Double {
            restored ? TransferEstimator.restoredPriorFiles : TransferEstimator.priorFiles
        }
    }

    /// One phase's evidence.
    private struct Fit: Sendable {
        /// Residuals landing on the same side, in a row, for one class of file.
        struct Run: Sendable {
            var sign = 0
            var length = 0
        }

        // Large files: decayed MiB moved, decayed seconds beyond the fixed cost, and how much of
        // the prior is left.
        var largeMiB = 0.0, largeSeconds = 0.0, largePrior = 1.0
        // Small files: decayed count, decayed seconds beyond streaming, and the prior left.
        var smallCount = 0.0, smallSeconds = 0.0, smallPrior = 1.0
        var largeRun = Run(), smallRun = Run()
        var observations = 0

        func secondsPerMiB(_ prior: Prior) -> Double {
            let weight = prior.mib * largePrior
            let denominator = largeMiB + weight
            guard denominator > 0 else { return prior.secondsPerMiB }
            return (largeSeconds + weight * prior.secondsPerMiB) / denominator
        }

        func secondsPerFile(_ prior: Prior) -> Double {
            let weight = prior.files * smallPrior
            let denominator = smallCount + weight
            guard denominator > 0 else { return prior.secondsPerFile }
            return (smallSeconds + weight * prior.secondsPerFile) / denominator
        }

        /// Folds in one observation. With `transient` the caller is working on a throwaway copy
        /// for a file that has not finished, so trimming is tighter and no run is kept.
        mutating func add(miB: Double, seconds: TimeInterval, prior: Prior, transient: Bool) {
            let perMiB = secondsPerMiB(prior)
            let perFile = secondsPerFile(prior)
            let expected = perMiB * miB + perFile
            let noise = hypot(TransferEstimator.noiseFloor, TransferEstimator.noiseFraction * expected)
            let large = miB >= TransferEstimator.largeFileMiB
            let residual = seconds - expected

            // Nothing is trimmed until this class has seen a file of its own: the prior is a
            // starting guess, not evidence worth protecting, and an estimate that is wrong by
            // several times over should be corrected by the first file that shows it.
            var limit = TransferEstimator.trimWidths * noise
            var streak = 0
            if (large ? largeMiB : smallCount) <= 0 {
                limit = .infinity
            } else if transient {
                limit *= TransferEstimator.inFlightTrimFactor
            } else {
                var run = large ? largeRun : smallRun
                if abs(residual) > TransferEstimator.shiftWidths * noise {
                    let sign = residual > 0 ? 1 : -1
                    run.length = sign == run.sign ? run.length + 1 : 1
                    run.sign = sign
                } else {
                    run = Run()
                }
                if large { largeRun = run } else { smallRun = run }
                streak = run.length
                limit *= pow(2.0, Double(min(max(run.length - 1, 0), 4)))
            }
            let trimmed = max(expected + min(max(residual, -limit), limit), 0)

            // A shift in progress means the old evidence is wrong, so let it go faster.
            let forgetting = Double(1 + max(streak - 1, 0))
            if large {
                let keep = exp(-trimmed * forgetting / TransferEstimator.throughputFreshness)
                largeMiB = largeMiB * keep + miB
                largeSeconds = largeSeconds * keep + max(trimmed - perFile, 0.1 * trimmed)
                largePrior *= keep
            } else {
                let keep = pow(TransferEstimator.smallFileKeep, forgetting)
                smallCount = smallCount * keep + 1
                smallSeconds = smallSeconds * keep + max(trimmed - perMiB * miB, 0)
                smallPrior *= keep
            }
        }
    }

    /// How much of the read-back the job really waited for, for one class of file.
    private struct Overlap: Sendable {
        var exposedSeconds = 0.0
        var readBackSeconds = 0.0

        /// 1 means none of it was hidden. That is where it starts, and where `prior` pulls it
        /// back to; it moves as evidence arrives.
        func fraction(prior: Double) -> Double {
            min(1, (exposedSeconds + prior) / (readBackSeconds + prior))
        }

        mutating func add(readBack: TimeInterval, exposed: TimeInterval, keep: Double) {
            exposedSeconds = exposedSeconds * keep + min(max(exposed, 0), readBack)
            readBackSeconds = readBackSeconds * keep + readBack
        }
    }

    private var copyFit = Fit()
    private var verifyFit = Fit()
    private let copyPrior: Prior
    /// How the verify phase compares with the copy phase, so that until it has evidence of its
    /// own it follows what the copy phase has learned instead of staying at a generic guess.
    private let verifyRatios: (perMiB: Double, perFile: Double)
    private var streamingOverlap = Overlap()
    private var fixedOverlap = Overlap()

    public init(bytesPerSecond: Double = TransferEstimator.defaultBytesPerSecond,
                secondsPerFile: Double = TransferEstimator.defaultSecondsPerFile) {
        let rate = bytesPerSecond.isFinite && bytesPerSecond > 0 ? bytesPerSecond : Self.defaultBytesPerSecond
        let fixed = secondsPerFile.isFinite && secondsPerFile >= 0 ? secondsPerFile : Self.defaultSecondsPerFile
        copyPrior = Prior(secondsPerMiB: Self.mib / rate, secondsPerFile: fixed, restored: false)
        // Read-back is normally quicker than the write it verifies, and cheaper per file.
        verifyRatios = (perMiB: 1 / 1.3, perFile: 0.5)
    }

    /// How many real files have been folded in. The UI uses this to decide when an estimate is
    /// worth showing at all.
    public var observationCount: Int { copyFit.observations + verifyFit.observations }

    // MARK: Learning

    /// Records one completed file. `seconds` is the wall-clock time that file's phase took,
    /// excluding any time spent paused.
    public mutating func record(phase: Phase, bytes: Int64, seconds: TimeInterval) {
        // A zero or negative duration carries no information and would skew the intercept.
        guard seconds > 0, seconds.isFinite, bytes >= 0 else { return }
        let miB = Double(bytes) / Self.mib
        switch phase {
        case .copy:
            copyFit.add(miB: miB, seconds: seconds, prior: copyPrior, transient: false)
            copyFit.observations += 1
        case .verify:
            verifyFit.add(miB: miB, seconds: seconds, prior: verifyPrior(), transient: false)
            verifyFit.observations += 1
        }
    }

    /// Records a read-back that ran underneath another file's copy. `seconds` is how long the
    /// read-back itself took; `exposedSeconds` is how much of that the job then had to wait for
    /// because the copy had already finished. The read-back is learned at its own pace, and the
    /// fraction that is exposed is learned separately for small and large files: a sidecar's
    /// read-back hides almost entirely under the next copy, a master's usually does not.
    public mutating func recordOverlappedVerify(bytes: Int64, seconds: TimeInterval,
                                                exposedSeconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite, bytes >= 0 else { return }
        record(phase: .verify, bytes: bytes, seconds: seconds)
        let exposed = exposedSeconds.isFinite ? exposedSeconds : seconds
        if Double(bytes) / Self.mib >= Self.largeFileMiB {
            streamingOverlap.add(readBack: seconds, exposed: exposed,
                                 keep: exp(-seconds / Self.overlapFreshness))
        } else {
            fixedOverlap.add(readBack: seconds, exposed: exposed, keep: Self.smallFileKeep)
        }
    }

    // MARK: Reading

    /// Current fitted throughput for a phase, in bytes per second. For display and diagnostics.
    public func bytesPerSecond(_ phase: Phase) -> Double {
        let perMiB = rates(phase).perMiB
        return perMiB > 0 ? Self.mib / perMiB : .infinity
    }

    /// Fitted fixed cost per file for a phase, in seconds.
    public func secondsPerFile(_ phase: Phase) -> Double {
        rates(phase).perFile
    }

    /// Seconds remaining for the whole job. Every input is known exactly from the scan.
    ///
    /// `copyInFlight` and `verifyInFlight` describe the file being copied or read back right
    /// now, if any. They are folded into this one answer and not remembered: the file's own
    /// record arrives when it finishes.
    public func secondsRemaining(copyBytes: Int64, copyFiles: Int,
                                 verifyBytes: Int64, verifyFiles: Int,
                                 copyInFlight: InFlight? = nil,
                                 verifyInFlight: InFlight? = nil) -> TimeInterval {
        forecast(copyBytes: copyBytes, copyFiles: copyFiles,
                 verifyBytes: verifyBytes, verifyFiles: verifyFiles,
                 copyInFlight: copyInFlight, verifyInFlight: verifyInFlight).seconds
    }

    /// An estimate, and whether it is yet worth showing.
    public struct Forecast: Sendable {
        public var seconds: TimeInterval
        /// False while a part of the estimate that carries real weight rests on the prior alone —
        /// a job that has copied nothing but sidecars so far has no idea how fast its masters go,
        /// and an estimate dominated by them will be revised by large factors the moment the first
        /// one is seen. That revision is the lurch worth not showing. Always true for an
        /// estimator calibrated on this destination by an earlier job.
        public var isGrounded: Bool
    }

    /// `secondsRemaining`, together with whether the answer rests on anything the job has seen.
    public func forecast(copyBytes: Int64, copyFiles: Int,
                         verifyBytes: Int64, verifyFiles: Int,
                         copyInFlight: InFlight? = nil,
                         verifyInFlight: InFlight? = nil) -> Forecast {
        let copyNow = provisional(copyFit, prior: copyPrior, evidence: copyInFlight)
        let copy = (perMiB: copyNow.secondsPerMiB(copyPrior), perFile: copyNow.secondsPerFile(copyPrior))
        let prior = verifyPrior(following: copy)
        let verifyNow = provisional(verifyFit, prior: prior, evidence: verifyInFlight)
        let verify = (perMiB: verifyNow.secondsPerMiB(prior), perFile: verifyNow.secondsPerFile(prior))

        // What each kind of remaining work will cost. Only the part of the read-back that was not
        // hidden under another file's copy costs time.
        let streamingExposed = streamingOverlap.fraction(prior: Self.overlapPriorSeconds)
        let fixedExposed = fixedOverlap.fraction(prior: Self.overlapPriorFileSeconds)
        let copyStreaming = Double(max(copyBytes, 0)) / Self.mib * copy.perMiB
        let copyFixed = Double(max(copyFiles, 0)) * copy.perFile
        let verifyStreaming = streamingExposed * Double(max(verifyBytes, 0)) / Self.mib * verify.perMiB
        let verifyFixed = fixedExposed * Double(max(verifyFiles, 0)) * verify.perFile
        let total = copyStreaming + copyFixed + verifyStreaming + verifyFixed

        // Grounded when every part that carries real weight has been seen at work. The read-back
        // may borrow from the copy phase, which it follows until it has evidence of its own.
        let weighty = Self.groundedShare * total
        let seenStreaming = copyNow.largeMiB > 0 || copyStreaming < weighty
        let seenFixed = copyNow.smallCount > 0 || copyFixed < weighty
        let readBackStreamingSeen = verifyNow.largeMiB > 0 || copyNow.largeMiB > 0
        let readBackFixedSeen = verifyNow.smallCount > 0 || copyNow.smallCount > 0
        let seenReadBackStreaming = readBackStreamingSeen || verifyStreaming < weighty
        let seenReadBackFixed = readBackFixedSeen || verifyFixed < weighty
        let allSeen = seenStreaming && seenFixed && seenReadBackStreaming && seenReadBackFixed
        let grounded = copyPrior.restored || total <= 0 || allSeen

        return Forecast(seconds: total.isFinite ? max(total, 0) : 0, isGrounded: grounded)
    }

    /// The fit as it would stand if a running file ended right now.
    private func provisional(_ fit: Fit, prior: Prior, evidence: InFlight?) -> Fit {
        guard let evidence, evidence.bytes > 0, evidence.seconds.isFinite,
              evidence.seconds >= Self.minInFlightSeconds else { return fit }
        var trial = fit
        trial.add(miB: Double(evidence.bytes) / Self.mib, seconds: evidence.seconds,
                  prior: prior, transient: true)
        return trial
    }

    private func rates(_ phase: Phase) -> (perMiB: Double, perFile: Double) {
        let copy = (perMiB: copyFit.secondsPerMiB(copyPrior), perFile: copyFit.secondsPerFile(copyPrior))
        switch phase {
        case .copy:
            return copy
        case .verify:
            let prior = verifyPrior(following: copy)
            return (perMiB: verifyFit.secondsPerMiB(prior), perFile: verifyFit.secondsPerFile(prior))
        }
    }

    private func verifyPrior() -> Prior {
        verifyPrior(following: (perMiB: copyFit.secondsPerMiB(copyPrior),
                                perFile: copyFit.secondsPerFile(copyPrior)))
    }

    private func verifyPrior(following copy: (perMiB: Double, perFile: Double)) -> Prior {
        Prior(secondsPerMiB: copy.perMiB * verifyRatios.perMiB,
              secondsPerFile: copy.perFile * verifyRatios.perFile,
              restored: copyPrior.restored)
    }

    // MARK: - Carrying the fit between jobs

    /// A compact summary of what this estimator learned, to persist per destination volume so
    /// the next job onto the same drive starts calibrated instead of at the generic prior.
    public struct Snapshot: Codable, Sendable {
        public var copyBytesPerSecond: Double
        public var copySecondsPerFile: Double
        public var verifyBytesPerSecond: Double
        public var verifySecondsPerFile: Double
    }

    public var snapshot: Snapshot {
        Snapshot(copyBytesPerSecond: bytesPerSecond(.copy),
                 copySecondsPerFile: secondsPerFile(.copy),
                 verifyBytesPerSecond: bytesPerSecond(.verify),
                 verifySecondsPerFile: secondsPerFile(.verify))
    }

    /// Rebuilds an estimator seeded from a previous job on the same destination.
    public init(restoring snapshot: Snapshot) {
        func sane(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite && value > 0 ? value : fallback
        }
        let copyRate = sane(snapshot.copyBytesPerSecond, Self.defaultBytesPerSecond)
        let copyFixed = sane(snapshot.copySecondsPerFile, Self.defaultSecondsPerFile)
        let verifyRate = sane(snapshot.verifyBytesPerSecond, copyRate * 1.3)
        let verifyFixed = sane(snapshot.verifySecondsPerFile, copyFixed * 0.5)
        copyPrior = Prior(secondsPerMiB: Self.mib / copyRate, secondsPerFile: copyFixed, restored: true)
        verifyRatios = (perMiB: copyRate / verifyRate, perFile: verifyFixed / copyFixed)
    }
}
