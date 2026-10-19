import Foundation

/// When completion notifications fire.
public enum NotificationTrigger: String, CaseIterable, Identifiable, Sendable {
    case eachJob        // after every job in the queue
    case queueComplete  // once, when the whole queue finishes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .eachJob: return "After each job"
        case .queueComplete: return "When the queue finishes"
        }
    }
}

/// Which completion moment produced a notification — used for gating.
public enum NotificationPhase: Sendable {
    case job
    case queue
}

/// User-facing notification preferences. A plain value type so the app can sync it
/// from `@AppStorage` and the test suite can construct it directly.
public struct NotificationSettings: Sendable, Equatable {
    public var desktopEnabled: Bool
    public var smsEnabled: Bool
    public var trigger: NotificationTrigger
    public var onlyOnFailure: Bool
    public var smsRecipient: String

    public init(desktopEnabled: Bool = true,
                smsEnabled: Bool = false,
                trigger: NotificationTrigger = .eachJob,
                onlyOnFailure: Bool = false,
                smsRecipient: String = "") {
        self.desktopEnabled = desktopEnabled
        self.smsEnabled = smsEnabled
        self.trigger = trigger
        self.onlyOnFailure = onlyOnFailure
        self.smsRecipient = smsRecipient
    }

    /// Should a desktop notification post for this completion moment?
    /// - `phase == .job` fires only when the trigger is per-job.
    /// - `phase == .queue` always represents the end-of-queue summary and is allowed through
    ///   (the caller decides whether a queue summary is worth sending, e.g. only for >1 job).
    public func shouldNotifyDesktop(isFailure: Bool, phase: NotificationPhase) -> Bool {
        guard desktopEnabled else { return false }
        return passesGate(isFailure: isFailure, phase: phase)
    }

    /// Should a text message send? SMS defaults to being quieter than desktop — it never
    /// fires per-job unless the user explicitly chose the per-job trigger AND a job failed;
    /// otherwise it rides the end-of-queue summary.
    public func shouldNotifySMS(isFailure: Bool, phase: NotificationPhase) -> Bool {
        guard smsEnabled, !smsRecipient.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if phase == .job {
            // Per-job texts only when the user opted into per-job notifications and it failed.
            return trigger == .eachJob && isFailure
        }
        return passesGate(isFailure: isFailure, phase: .queue)
    }

    private func passesGate(isFailure: Bool, phase: NotificationPhase) -> Bool {
        if onlyOnFailure && !isFailure { return false }
        switch phase {
        case .job: return trigger == .eachJob
        case .queue: return true
        }
    }
}

/// The rendered text for one notification, across surfaces.
public struct NotificationContent: Sendable, Equatable {
    public let title: String
    public let body: String       // desktop banner body
    public let shortText: String  // one-line SMS-style summary
    public let isFailure: Bool

    public init(title: String, body: String, shortText: String, isFailure: Bool) {
        self.title = title
        self.body = body
        self.shortText = shortText
        self.isFailure = isFailure
    }

    // MARK: - Builders

    /// Notification for a single finished job.
    public static func forJob(name: String, destination: URL?, summary: TransferSummary) -> NotificationContent {
        let outcome = Outcome(summary: summary)
        let title: String
        switch outcome.kind {
        case .fatal:   title = "\(name) couldn't start"
        case .failure: title = "\(name) finished with errors"
        case .cancelled: title = "\(name) cancelled"
        case .success: title = "\(name) complete"
        }

        var body = outcome.sentence
        if let destination, outcome.kind != .fatal {
            body += " → \(destination.lastPathComponent)"
        }

        let short = "VeriCopy: \(name) — \(outcome.shortSentence) \(outcome.emoji)"
        return NotificationContent(title: title, body: body, shortText: short, isFailure: outcome.isFailure)
    }

    /// Aggregate notification for a whole queue of finished jobs.
    public static func forQueue(jobCount: Int, combined: TransferSummary) -> NotificationContent {
        let outcome = Outcome(summary: combined)
        let jobsWord = jobCount == 1 ? "1 job" : "\(jobCount) jobs"
        let title: String
        switch outcome.kind {
        case .failure: title = "Queue finished with errors"
        case .cancelled: title = "Queue cancelled"
        case .fatal, .success: title = "Queue complete"
        }
        let body = "\(jobsWord) · \(outcome.sentence)"
        let short = "VeriCopy queue done: \(jobsWord), \(outcome.shortSentence) \(outcome.emoji)"
        return NotificationContent(title: title, body: body, shortText: short, isFailure: outcome.isFailure)
    }
}

// MARK: - Outcome summarization

private struct Outcome {
    enum Kind { case success, failure, cancelled, fatal }

    let kind: Kind
    let sentence: String       // full, e.g. "128 files copied & verified (2.4 GB) in 3m 12s"
    let shortSentence: String  // compact, e.g. "128 files verified in 3m12s"

    var isFailure: Bool { kind == .failure || kind == .fatal }

    var emoji: String {
        switch kind {
        case .success: return "✅"
        case .failure, .fatal: return "⚠️"
        case .cancelled: return "⏹"
        }
    }

    init(summary: TransferSummary) {
        let size = ByteCountFormatter.string(fromByteCount: summary.bytesCopied, countStyle: .file)
        let elapsed = Outcome.elapsedText(summary.elapsed)
        let elapsedShort = Outcome.elapsedShort(summary.elapsed)
        let files = Outcome.filesWord(summary.succeeded)

        if let fatal = summary.fatalError {
            kind = .fatal
            sentence = fatal
            shortSentence = "couldn't start"
            _ = (size, elapsed, elapsedShort, files)
            return
        }
        if summary.failed > 0 {
            kind = .failure
            let failWord = summary.failed == 1 ? "1 file failed" : "\(summary.failed) files FAILED"
            sentence = "\(failWord), \(summary.succeeded) OK (\(size)) in \(elapsed)"
            shortSentence = "\(failWord), \(summary.succeeded) OK"
            return
        }
        if summary.cancelled {
            kind = .cancelled
            sentence = "cancelled after \(files) (\(size)) in \(elapsed)"
            shortSentence = "cancelled after \(summary.succeeded)"
            return
        }
        kind = .success
        let skipNote = summary.skipped > 0 ? ", \(summary.skipped) skipped" : ""
        sentence = "\(files) copied & verified (\(size))\(skipNote) in \(elapsed)"
        shortSentence = "\(files) verified in \(elapsedShort)"
    }

    private static func filesWord(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    private static func elapsedText(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        f.unitsStyle = .abbreviated
        return f.string(from: max(0, seconds)) ?? "\(Int(seconds))s"
    }

    private static func elapsedShort(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(s % 60)s" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
