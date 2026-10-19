import Foundation

/// Turns the engine's raw seconds-remaining, which is recomputed about fifteen times a second and
/// moves whenever the model learns something, into a countdown a person can watch.
///
/// The thing worth holding steady is not the time *remaining* but the time of *finishing*. If
/// the estimate is right, the finish time does not move — the remaining time just falls by a
/// second every second — so that is what this keeps, and the countdown is read off it. Smoothing
/// the remaining time itself instead would make it lag behind a falling estimate by the filter's
/// time constant, and would have no way of telling a wobble from a change.
///
/// The finish time moves toward each new reading, but how fast depends on how far apart they
/// are. A reading within a few percent of the current prediction is noise and barely nudges it.
/// One that is far outside that band is moved toward quickly, because by then it is more likely
/// the job changed than that the model wobbled. There is no snap and no threshold to cross:
/// the pull simply strengthens with the disagreement, so a real change shows up within seconds
/// and a flicker never does.
///
/// What is shown is the rounded figure from `TimeRemaining`, redrawn at most once a second and
/// reluctant to go *up*: a rounding boundary that the estimate wobbles around would otherwise
/// flip the text back and forth, and a figure that rises reads as the job getting worse.
public struct ETASmoother: Sendable {

    /// The smoothed countdown as of the last update, unrounded. Nil while there is no estimate.
    public private(set) var seconds: TimeInterval?
    /// What to put on screen. Nil while there is no estimate.
    public private(set) var text: String?
    /// The rounded figure `text` is describing, in seconds — what the hysteresis acts on.
    public var figure: TimeInterval? { shown }

    /// Time constant when readings agree, and the fastest it will ever follow a disagreement.
    private static let calmTau: TimeInterval = 60
    private static let fastestTau: TimeInterval = 3
    /// What counts as "agreeing": a floor, or a fraction of the time left, whichever is larger.
    private static let bandFloor: TimeInterval = 10
    private static let bandFraction = 0.05
    /// How far past the previous figure the countdown must climb, in rounding steps, before the
    /// text is allowed to go up.
    private static let riseMargin = 1.0
    private static let redrawInterval: TimeInterval = 1

    /// Predicted completion, in seconds since the reference date.
    private var finish: TimeInterval?
    private var lastUpdate: TimeInterval?
    private var shown: TimeInterval?
    private var lastRedraw = -TimeInterval.infinity

    public init() {}

    /// Drops everything, so a re-run or a pause-and-resume across a long gap starts fresh.
    public mutating func reset() {
        seconds = nil
        text = nil
        finish = nil
        lastUpdate = nil
        shown = nil
        lastRedraw = -.infinity
    }

    /// Takes one raw reading. Nil means the engine has no estimate yet, which clears the display.
    public mutating func update(raw: TimeInterval?, at date: Date = Date()) {
        guard let raw, raw.isFinite else {
            reset()
            return
        }
        let now = date.timeIntervalSinceReferenceDate
        let target = now + max(raw, 0)

        let predicted: TimeInterval
        if let finish, let last = lastUpdate {
            let elapsed = max(0, now - last)
            let band = max(Self.bandFloor, Self.bandFraction * max(finish - now, 0))
            let error = target - finish
            // The further the reading is outside the band, the shorter the time constant: at the
            // edge of the band it is `calmTau`, at twice that it is a quarter of it, and so on
            // down to `fastestTau`.
            let agreement = min(1, band / max(abs(error), 1e-9))
            let tau = max(Self.fastestTau, Self.calmTau * agreement * agreement)
            predicted = finish + error * (1 - exp(-elapsed / tau))
        } else {
            predicted = target
        }
        finish = predicted
        lastUpdate = now

        let remaining = max(predicted - now, 0)
        seconds = remaining
        redraw(remaining, now: now)
    }

    private mutating func redraw(_ remaining: TimeInterval, now: TimeInterval) {
        guard shown == nil || now - lastRedraw >= Self.redrawInterval else { return }
        lastRedraw = now

        var figure = TimeRemaining.rounded(remaining)
        if let previous = shown, figure > previous,
           remaining >= TimeRemaining.countdownFloor,
           remaining < previous + Self.riseMargin * TimeRemaining.step(for: remaining) {
            figure = previous
        }
        shown = figure
        text = TimeRemaining.describe(figure)
    }
}
