import Foundation
import VeriCopyCore

// The wire contract for the local HTTP API.
//
// These types are deliberately SEPARATE from the engine's own types (`FileItem`,
// `TransferSummary`, `JobState`). The dashboard that consumes them is written in Java, so
// nothing checks at compile time that both ends agree — the only thing holding the contract
// together is API.md and these structs. Encoding the engine types directly would make every
// internal rename a silent, runtime break in another codebase. Changing a field here is a
// deliberate act; renaming a field in `FileItem` should not be.

// MARK: - Requests

struct CreateJobRequest: Decodable {
    let source: String
    let destination: String
    /// "copy" (the default when absent) or "move". Optional so a caller written against the
    /// copy-only version of this API keeps working unchanged, and keeps copying.
    let mode: String?
}

// MARK: - Responses

struct CreateJobResponse: Encodable {
    let jobId: String
}

struct HealthResponse: Encodable {
    let ok: Bool
    let version: String
    let queueActive: Bool
}

struct FailedFileDTO: Encodable {
    /// Path relative to the destination root.
    let path: String
    /// Why it failed — a checksum mismatch, an unreadable source, and so on.
    let message: String
}

/// One job, in full. This is what the dashboard polls.
struct JobStatusResponse: Encodable {
    let jobId: String
    let name: String
    /// "api" for jobs this API created, "ui" for jobs the user built in the window.
    let origin: String
    /// "copy", "move" or "verify" — what this job is doing.
    let mode: String
    /// queued | copying | verifying | verified | failed | cancelled
    let status: String
    let sources: [String]
    let destination: String?
    /// 0.0 – 1.0, spanning copy *and* the verification read-back.
    let progress: Double
    let bytesCopied: Int64
    let bytesTotal: Int64
    let filesTotal: Int
    let filesCopied: Int
    let filesVerified: Int
    let filesFailed: Int
    /// Files that finished successfully but were never checksum-compared. For a same-volume
    /// move these are instant renames — no data was rewritten, so there is nothing a
    /// checksum could tell you. For a copy they are files transferred with verification off.
    /// Non-zero here is what makes a finished job `completed_unverified` rather than
    /// `verified`.
    let filesUnverified: Int
    let startedAt: Date?
    let finishedAt: Date?
    let secondsRemaining: Int?
    /// Set when the job could not start at all (no free space, unreadable destination).
    let fatalError: String?
    let failedFiles: [FailedFileDTO]
}

struct JobListResponse: Encodable {
    let jobs: [JobStatusResponse]
}

/// Every non-2xx response has this shape, so the Java side can bind all of them to one
/// class and branch on a stable `error` code rather than parsing prose.
struct APIErrorResponse: Encodable {
    let error: String
    let message: String
}

// MARK: - Status mapping

/// The states the API reports, derived from VeriCopy's internals.
///
/// The engine has no job-level "verified" flag — by design, one bad file is isolated and
/// counted rather than aborting the run (see `TransferEngine`). So the verdict is derived:
/// a job is verified only when nothing failed, nothing was cancelled, and a read-back pass
/// actually ran.
///
/// `completedUnverified` is the honest answer to a case the six requested states don't
/// cover: a run that succeeded but where at least one file was never checksum-compared, so
/// "every file's checksum matched" is not a claim that can be made. Calling that "verified"
/// would be a lie and calling it "failed" would be a different one.
///
/// Two things reach it. A copy run with verification off (only possible for jobs built in
/// the window — API copies always verify). And a **same-volume move**, which the engine
/// performs as a rename: no bytes are rewritten, so there is no copy for a checksum to
/// check. That second case is reachable over the API, so the dashboard will see it whenever
/// it moves something within one drive.
enum APIJobStatus: String {
    case queued, copying, verifying, verified, failed, cancelled
    case completedUnverified = "completed_unverified"

    @MainActor
    static func of(_ job: TransferJob, tally: TransferJob.APITally? = nil) -> APIJobStatus {
        let tally = tally ?? job.apiTally
        switch job.state {
        case .draft:
            return .queued
        case .running, .paused:
            // `isVerificationPhase` is only set for the end-of-job pass that the "At end"
            // policy runs. API jobs verify per file, so the job-level flag never fires for
            // them and asking it alone would report "copying" for the whole run. The files
            // themselves know: any one of them reading back means the job is verifying.
            return (job.isVerificationPhase || tally.verifying > 0) ? .verifying : .copying
        case .finished:
            guard let summary = job.summary else { return .failed }
            if summary.cancelled { return .cancelled }
            if summary.fatalError != nil || summary.failed > 0 { return .failed }
            // Read from the files themselves rather than from the job's verification
            // setting: a move can skip the read-back per file (a rename) even though the
            // policy asked for it, and only the per-file verdicts know that happened.
            return tally.unverified > 0 ? .completedUnverified : .verified
        }
    }
}
