import Foundation

/// What VeriCopy does once the whole queue has finished.
public enum CompletionAction: String, CaseIterable, Identifiable, Sendable {
    case nothing
    case sleep
    case quit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nothing: return "Do nothing"
        case .sleep: return "Sleep the Mac"
        case .quit: return "Quit VeriCopy"
        }
    }

    /// Used in the "VeriCopy didn't …" explanation when an action is blocked.
    public var verbPhrase: String {
        switch self {
        case .nothing: return "do anything"
        case .sleep: return "put the Mac to sleep"
        case .quit: return "quit"
        }
    }
}

/// One queue run reduced to just what the end-of-run policy needs to decide.
public struct RunOutcome: Sendable, Equatable {
    public var jobCount: Int
    /// Any job reported failed files or a fatal error.
    public var anyFailures: Bool
    /// Any job's engine reported it was cancelled (per-job Cancel).
    public var anyCancelled: Bool
    /// The user pressed Stop Queue.
    public var stopRequested: Bool
    public var filesSucceeded: Int
    public var bytesCopied: Int64

    public init(jobCount: Int = 0,
                anyFailures: Bool = false,
                anyCancelled: Bool = false,
                stopRequested: Bool = false,
                filesSucceeded: Int = 0,
                bytesCopied: Int64 = 0) {
        self.jobCount = jobCount
        self.anyFailures = anyFailures
        self.anyCancelled = anyCancelled
        self.stopRequested = stopRequested
        self.filesSucceeded = filesSucceeded
        self.bytesCopied = bytesCopied
    }

    public static func summarize(_ summaries: [TransferSummary], stopRequested: Bool) -> RunOutcome {
        RunOutcome(
            jobCount: summaries.count,
            anyFailures: summaries.contains { $0.failed > 0 || $0.fatalError != nil },
            anyCancelled: summaries.contains { $0.cancelled },
            stopRequested: stopRequested,
            filesSucceeded: summaries.reduce(0) { $0 + $1.succeeded },
            bytesCopied: summaries.reduce(Int64(0)) { $0 + $1.bytesCopied }
        )
    }

    /// One-line description of the run, shown on the countdown panel.
    public var detailLine: String {
        let jobs = jobCount == 1 ? "1 job" : "\(jobCount) jobs"
        let files = filesSucceeded == 1 ? "1 file" : "\(filesSucceeded) files"
        let size = ByteCountFormatter.string(fromByteCount: bytesCopied, countStyle: .file)
        return "\(jobs) · \(files) · \(size)"
    }
}

/// Why a completion action did not run.
public enum BlockReason: String, Sendable, Equatable {
    case runHadFailures
    case runWasCancelled
    case nothingRan
}

public enum CompletionDecision: Sendable, Equatable {
    /// The user never asked for anything to happen.
    case doNothing
    /// They did, but the run's outcome makes it unsafe/unhelpful.
    case blocked(CompletionAction, BlockReason)
    /// Start the cancelable countdown, then perform the action.
    case armCountdown(CompletionAction, seconds: Int)
}

/// Power preferences. A plain value type so the app can sync it from `@AppStorage`
/// and the test suite can construct it directly — same shape as `NotificationSettings`.
public struct PowerSettings: Sendable, Equatable {
    public var keepAwakeEnabled: Bool
    public var defaultCompletionAction: CompletionAction
    public var countdownSeconds: Int
    /// Never run the completion action if any file failed.
    public var skipAfterFailures: Bool

    public init(keepAwakeEnabled: Bool = true,
                defaultCompletionAction: CompletionAction = .nothing,
                countdownSeconds: Int = 30,
                skipAfterFailures: Bool = true) {
        self.keepAwakeEnabled = keepAwakeEnabled
        self.defaultCompletionAction = defaultCompletionAction
        self.countdownSeconds = countdownSeconds
        self.skipAfterFailures = skipAfterFailures
    }

    /// The name the keep-awake assertion registers under — visible in `pmset -g assertions`.
    public static let assertionName = "VeriCopy queue in progress"

    /// Should the keep-awake hold be active right now?
    public func shouldHoldAwake(queueActive: Bool) -> Bool {
        keepAwakeEnabled && queueActive
    }

    /// Which action wins when several jobs ran: the last job that actually ran.
    /// An empty list falls back to the Settings default.
    public func resolveAction(jobActions: [CompletionAction]) -> CompletionAction {
        jobActions.last ?? defaultCompletionAction
    }

    /// The end-of-run decision. Order of the checks is deliberate:
    ///
    /// 1. `.nothing` first — a run the user never armed should never produce a
    ///    "didn't sleep because…" explanation.
    /// 2. Nothing ran at all (e.g. the only job wasn't ready) — no basis to act.
    /// 3. Cancelled — the user pressed Stop or Cancel, so they are at the machine.
    ///    A deliberate intervention should never be followed by sleeping/quitting.
    /// 4. Failures — leave the screen up so the failure is actually seen.
    public func decideCompletion(jobActions: [CompletionAction], outcome: RunOutcome) -> CompletionDecision {
        let action = resolveAction(jobActions: jobActions)
        guard action != .nothing else { return .doNothing }
        if outcome.jobCount == 0 { return .blocked(action, .nothingRan) }
        if outcome.stopRequested || outcome.anyCancelled { return .blocked(action, .runWasCancelled) }
        if skipAfterFailures && outcome.anyFailures { return .blocked(action, .runHadFailures) }
        return .armCountdown(action, seconds: max(0, countdownSeconds))
    }
}

/// The live state of a pending completion action, rendered by the countdown panel.
public struct PendingCompletion: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let action: CompletionAction
    public let totalSeconds: Int
    public var secondsRemaining: Int
    public let detail: String
    /// Set when the destination is on a removable volume, so the panel can warn
    /// against unplugging the drive before the Mac is actually asleep.
    public let removableVolumeName: String?

    public init(id: UUID = UUID(),
                action: CompletionAction,
                totalSeconds: Int,
                secondsRemaining: Int,
                detail: String,
                removableVolumeName: String? = nil) {
        self.id = id
        self.action = action
        self.totalSeconds = totalSeconds
        self.secondsRemaining = secondsRemaining
        self.detail = detail
        self.removableVolumeName = removableVolumeName
    }

    /// Remaining fraction, for the draining progress bar.
    public var fraction: Double {
        totalSeconds > 0 ? max(0, min(1, Double(secondsRemaining) / Double(totalSeconds))) : 0
    }

    public var headline: String {
        switch action {
        case .sleep: return "Sleeping in \(secondsRemaining)s"
        case .quit: return "Quitting VeriCopy in \(secondsRemaining)s"
        case .nothing: return "Finishing in \(secondsRemaining)s"
        }
    }
}
