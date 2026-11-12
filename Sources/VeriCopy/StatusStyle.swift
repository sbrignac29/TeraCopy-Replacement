import SwiftUI

/// One color per meaning, everywhere a status appears: the file list, the sidebar, the footer,
/// the stats tiles, the menu bar panel and Settings. A color never stands for two things, and
/// every status also has its own symbol, so color is never the only signal.
enum StatusColor {
    static let verified = Color.green
    static let copying = Color.blue
    static let verifying = Color.orange
    /// System red measures 3.57:1 on a light window and 4.86:1 on a dark one, so a failure
    /// symbol stays visible in both. (System yellow, used here before, was 1.51:1 in light.)
    static let failed = Color.red
    /// Waiting, paused, skipped and cancelled: states that need no attention.
    static let inactive = Color.secondary
}

/// The symbol for a failed file, job or run.
let failureSymbolName = "xmark.octagon.fill"

/// The warning sign, for conditions that are not failures: a drive that is not mounted, or
/// notifications turned off. A plain yellow triangle measures 1.51:1 on a light window, so the
/// mark is drawn black on it, which reads at about 14:1 in both appearances.
struct WarningSymbol: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, .yellow)
            .accessibilityLabel("Warning")
    }
}
