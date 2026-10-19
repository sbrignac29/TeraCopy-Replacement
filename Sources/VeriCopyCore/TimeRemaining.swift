import Foundation

/// Turns a raw seconds-remaining figure into something worth putting on screen.
///
/// The model behind it updates about fifteen times a second and is precise to the second,
/// which is exactly why it must not be shown that way: a countdown whose last digits churn
/// reads as guesswork even when it is accurate. Precision is spent where it changes what
/// someone does — whether to wait, to go and do something else, or to leave it overnight.
public enum TimeRemaining {

    /// Rounds by magnitude, and locks the unit set above ten minutes so the format never
    /// flips mid-job the way an hour boundary otherwise makes it.
    public static func describe(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "almost done" }
        if seconds < 90 { return "less than a minute" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        let rounded: TimeInterval
        if seconds < 600 {
            rounded = (seconds / 30).rounded() * 30          // nearest 30 s
            formatter.allowedUnits = [.minute, .second]
        } else if seconds < 3600 {
            rounded = (seconds / 60).rounded() * 60          // nearest minute
            formatter.allowedUnits = [.hour, .minute]
        } else {
            rounded = (seconds / 300).rounded() * 300        // nearest 5 minutes
            formatter.allowedUnits = [.hour, .minute]
        }
        return formatter.string(from: rounded) ?? "less than a minute"
    }
}
