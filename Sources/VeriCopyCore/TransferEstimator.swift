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
/// and fits `B` (bytes per second) and `F` (seconds per file) together by weighted least squares
/// over completed files, separately for the copy and verify phases — reading back from the
/// destination has its own throughput and its own per-file cost. Remaining work is not estimated
/// at all: `SourceScanner` has already enumerated every file, so the byte and file counts left in
/// each phase are known exactly.
///
/// Storage is five running sums per phase, so this is O(1) in memory and takes no allocation on
/// the hot path.
public struct TransferEstimator: Sendable {

    public enum Phase: Sendable { case copy, verify }

    /// Prior for a freshly-created estimator: a mid-range external drive.
    public static let defaultBytesPerSecond: Double = 150 * 1024 * 1024
    public static let defaultSecondsPerFile: Double = 0.008

    /// Weight retained per observation. At 0.97 the most recent ~30 files carry about half the
    /// total weight, which tracks a change of file size regime without chasing a single outlier.
    private static let decay = 0.97

    /// Weight given to the seed observations. Deliberately light: two or three real files should
    /// already outvote the prior, but the prior must still hold the fit together at file one.
    private static let seedWeight = 0.35

    /// Weighted sums for one phase's fit of `seconds = bytes · invB + F`.
    private struct Fit: Sendable {
        var w = 0.0, wx = 0.0, wxx = 0.0, wy = 0.0, wxy = 0.0
        var count = 0

        mutating func add(bytes: Double, seconds: Double, weight: Double) {
            let d = TransferEstimator.decay
            w *= d; wx *= d; wxx *= d; wy *= d; wxy *= d
            w += weight
            wx += weight * bytes
            wxx += weight * bytes * bytes
            wy += weight * seconds
            wxy += weight * bytes * seconds
        }

        mutating func seed(bytesPerSecond: Double, secondsPerFile: Double) {
            // Two points on the prior line pin both coefficients exactly.
            let big = 64.0 * 1024 * 1024
            add(bytes: 0, seconds: secondsPerFile, weight: TransferEstimator.seedWeight)
            add(bytes: big, seconds: big / bytesPerSecond + secondsPerFile,
                weight: TransferEstimator.seedWeight)
            count = 0 // seeds are not observations
        }

        /// Solves the 2×2 normal equations. Returns (secondsPerByte, secondsPerFile).
        var coefficients: (perByte: Double, perFile: Double) {
            let determinant = wxx * w - wx * wx
            guard determinant.magnitude > 1e-6, w > 0 else {
                return (1 / TransferEstimator.defaultBytesPerSecond,
                        TransferEstimator.defaultSecondsPerFile)
            }
            let perByte = (wxy * w - wx * wy) / determinant
            let perFile = (wxx * wy - wx * wxy) / determinant
            // A short run of same-sized files can make the fit lean negative on one term.
            // Both costs are physically non-negative, so clamp rather than predict time travel.
            return (max(perByte, 0), max(perFile, 0))
        }
    }

    private var copyFit = Fit()
    private var verifyFit = Fit()

    public init(bytesPerSecond: Double = TransferEstimator.defaultBytesPerSecond,
                secondsPerFile: Double = TransferEstimator.defaultSecondsPerFile) {
        copyFit.seed(bytesPerSecond: bytesPerSecond, secondsPerFile: secondsPerFile)
        // Read-back is normally quicker than the write it verifies, and cheaper per file.
        verifyFit.seed(bytesPerSecond: bytesPerSecond * 1.3, secondsPerFile: secondsPerFile * 0.5)
    }

    /// How many real files have been folded in. The UI uses this to decide when an estimate is
    /// worth showing at all.
    public var observationCount: Int { copyFit.count + verifyFit.count }

    /// Records one completed file. `seconds` is the wall-clock time that file's phase took.
    public mutating func record(phase: Phase, bytes: Int64, seconds: TimeInterval) {
        // A zero or negative duration carries no information and would skew the intercept.
        guard seconds > 0, seconds.isFinite, bytes >= 0 else { return }
        switch phase {
        case .copy:
            copyFit.add(bytes: Double(bytes), seconds: seconds, weight: 1)
            copyFit.count += 1
        case .verify:
            verifyFit.add(bytes: Double(bytes), seconds: seconds, weight: 1)
            verifyFit.count += 1
        }
    }

    /// Current fitted throughput for a phase, in bytes per second. For display and diagnostics.
    public func bytesPerSecond(_ phase: Phase) -> Double {
        let perByte = (phase == .copy ? copyFit : verifyFit).coefficients.perByte
        return perByte > 0 ? 1 / perByte : .infinity
    }

    /// Fitted fixed cost per file for a phase, in seconds.
    public func secondsPerFile(_ phase: Phase) -> Double {
        (phase == .copy ? copyFit : verifyFit).coefficients.perFile
    }

    /// Seconds remaining for the whole job. Every input is known exactly from the scan.
    public func secondsRemaining(copyBytes: Int64, copyFiles: Int,
                                 verifyBytes: Int64, verifyFiles: Int) -> TimeInterval {
        let copy = copyFit.coefficients
        let verify = verifyFit.coefficients
        let total = Double(max(copyBytes, 0)) * copy.perByte
            + Double(max(copyFiles, 0)) * copy.perFile
            + Double(max(verifyBytes, 0)) * verify.perByte
            + Double(max(verifyFiles, 0)) * verify.perFile
        return total.isFinite ? max(total, 0) : 0
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
        copyFit.seed(bytesPerSecond: sane(snapshot.copyBytesPerSecond, Self.defaultBytesPerSecond),
                     secondsPerFile: sane(snapshot.copySecondsPerFile, Self.defaultSecondsPerFile))
        verifyFit.seed(bytesPerSecond: sane(snapshot.verifyBytesPerSecond, Self.defaultBytesPerSecond * 1.3),
                       secondsPerFile: sane(snapshot.verifySecondsPerFile, Self.defaultSecondsPerFile * 0.5))
    }
}
