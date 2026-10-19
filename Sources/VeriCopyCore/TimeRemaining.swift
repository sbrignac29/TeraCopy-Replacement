import Foundation

/// Turns a raw seconds-remaining figure into something worth putting on screen.
///
/// The model behind it updates about fifteen times a second and is precise to the second,
/// which is exactly why it must not be shown that way: a countdown whose last digits churn
/// reads as guesswork even when it is accurate. Precision is spent where it changes what
/// someone does — whether to wait, to go and do something else, or to leave it overnight.
public enum TimeRemaining {

    /// Below this, the countdown stops counting and says "less than a minute".
    public static let countdownFloor: TimeInterval = 90

    /// The granularity `describe` rounds to at a given magnitude. Locked in bands, so the format
    /// never flips mid-job the way an hour boundary otherwise makes it.
    public static func step(for seconds: TimeInterval) -> TimeInterval {
        if seconds < 600 { return 30 }      // nearest 30 s
        if seconds < 3600 { return 60 }     // nearest minute
        return 300                          // nearest 5 minutes
    }

    /// The figure `describe` is showing for `seconds`, so a caller can tell whether the text
    /// would change without formatting it. Zero means "almost done".
    public static func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        if seconds < countdownFloor { return countdownFloor / 2 }
        let unit = step(for: seconds)
        return (seconds / unit).rounded() * unit
    }

    /// Rounds by magnitude, and locks the unit set above ten minutes so the format never
    /// flips mid-job the way an hour boundary otherwise makes it.
    public static func describe(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "almost done" }
        if seconds < countdownFloor { return "less than a minute" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds < 600 ? [.minute, .second] : [.hour, .minute]
        return formatter.string(from: rounded(seconds)) ?? "less than a minute"
    }
}
