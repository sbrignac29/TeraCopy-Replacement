import Foundation

/// What kind of job to run.
public enum TransferMode: String, CaseIterable, Identifiable, Sendable {
    case copy = "Copy"
    case move = "Move"
    case verify = "Verify"

    public var id: String { rawValue }
}

/// Per-file lifecycle state.
public enum ItemStatus: Equatable, Sendable {
    case pending
    case copying
    case verifying
    case copied          // data written; verification deferred to the end-of-job pass
    case done            // copied and checksum-verified
    case doneNoVerify    // completed without a data verification pass (same-volume move, symlink, verify off)
    case skipped
    case failed
}

/// When (or whether) copied data is read back and checksum-compared.
public enum VerificationPolicy: String, CaseIterable, Identifiable, Sendable {
    case perFile   // verify each file immediately after it is copied
    case afterAll  // copy everything first, then run one verification pass
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .perFile: return "Each file"
        case .afterAll: return "At end"
        case .off: return "Never"
        }
    }
}

/// A single file (or symlink) in the transfer queue.
public struct FileItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    /// Path relative to the destination root (includes the top-level folder name for folder sources).
    public let relativePath: String
    public let size: Int64
    public let isSymlink: Bool

    public var status: ItemStatus = .pending
    public var bytesCopied: Int64 = 0
    /// Hex checksum of the source data, computed during copy (or during verify mode).
    public var checksum: String?
    /// Human-readable note: error text, "Already exists", "Moved (same volume)", etc.
    public var message: String?
    /// Set when a keep-both conflict resolution renamed the file at the destination.
    public var destinationName: String?

    public init(sourceURL: URL, relativePath: String, size: Int64, isSymlink: Bool) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.size = size
        self.isSymlink = isSymlink
    }

    public var fileName: String { (relativePath as NSString).lastPathComponent }
}

/// Result of scanning source URLs into a flat work list.
public struct TransferPlan: Sendable {
    public var items: [FileItem] = []
    /// Relative directory paths to create at the destination, shallow → deep.
    public var directories: [String] = []
    /// Source directory URLs paired with their relative destination paths (for metadata copy + move cleanup).
    public var directorySources: [(source: URL, relative: String)] = []
    public var totalBytes: Int64 = 0
    /// Non-fatal problems encountered while scanning (unreadable subdirectories, etc.).
    public var scanErrors: [String] = []

    public init() {}
}

/// How to handle a file that already exists at the destination.
public enum ConflictChoice: Sendable {
    case overwrite
    case skip
    case keepBoth
}

public struct ConflictResolution: Sendable {
    public var choice: ConflictChoice
    public var applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

/// Final report for a finished (or cancelled/aborted) job.
public struct TransferSummary: Sendable {
    public var succeeded: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    public var bytesCopied: Int64 = 0
    public var elapsed: TimeInterval = 0
    public var cancelled: Bool = false
    /// Set when the job could not start at all (e.g. not enough free space).
    public var fatalError: String?
    /// What the time estimator learned about this destination, to seed the next job onto it.
    public var estimatorSnapshot: TransferEstimator.Snapshot?

    public init() {}
}

/// A whole-job progress reading.
///
/// Two different totals, because they answer two different questions. `work` counts everything
/// the job has to move — copy bytes plus the verification read-back that follows them — and is
/// what the progress bar and the time estimate run on, so neither one restarts when the job
/// changes phase. `data` counts bytes that have actually landed at the destination, which is
/// what a person means by "how much has copied".
public struct TransferProgress: Sendable {
    /// Copy + verification bytes completed.
    public var workDone: Int64 = 0
    /// Copy + verification bytes the job will do in total.
    public var workTotal: Int64 = 0
    /// Bytes written to the destination so far.
    public var dataCopied: Int64 = 0
    /// Bytes the job will write to the destination in total.
    public var dataTotal: Int64 = 0
    /// Estimated seconds left for the whole job, or nil while the estimate is still warming up.
    public var secondsRemaining: TimeInterval?
    /// True while the engine is reading data back to verify it.
    public var isVerifying: Bool = false

    public init() {}

    public var fraction: Double {
        guard workTotal > 0 else { return 0 }
        return min(1, max(0, Double(workDone) / Double(workTotal)))
    }
}

/// Receives engine progress. All methods are async so the UI can live on the main actor.
///
/// Progress callbacks are delivered from a pump task at roughly 15 Hz, not from the copy loop —
/// a slow delegate slows the display, never the transfer.
public protocol TransferEngineDelegate: AnyObject {
    func engineDidUpdate(item: FileItem, at index: Int) async
    func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async
    func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution
    /// Called once when the deferred (end-of-job) verification pass begins. Purely a label:
    /// `TransferProgress` spans both phases, so nothing about the bar or the estimate resets.
    func engineDidBeginVerificationPhase(fileCount: Int, totalBytes: Int64) async
    /// Whole-job progress, including the time estimate.
    func engineDidUpdateProgress(_ progress: TransferProgress) async
}

public extension TransferEngineDelegate {
    func engineDidBeginVerificationPhase(fileCount: Int, totalBytes: Int64) async {}

    /// Keeps delegates written against the original byte-counting callback working unchanged.
    func engineDidUpdateProgress(_ progress: TransferProgress) async {
        await engineDidUpdateOverall(bytesDone: progress.dataCopied, totalBytes: progress.dataTotal)
    }
}

public enum TransferError: LocalizedError {
    case cancelled
    case cannotCreateFile(String)
    case checksumMismatch(expected: String, actual: String)
    case destinationMissing

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Cancelled"
        case .cannotCreateFile(let path):
            return "Could not create file at \(path)"
        case .checksumMismatch(let expected, let actual):
            return "Verification failed — source \(expected.prefix(12))…, destination \(actual.prefix(12))…"
        case .destinationMissing:
            return "Missing in destination"
        }
    }
}
