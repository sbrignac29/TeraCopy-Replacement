import Foundation

/// The version `Scripts/build_app.sh` stamps into the bundle, shown in the main window so two
/// builds can be told apart at a glance.
enum AppVersion {
    /// Info.plist key the build script writes the short commit hash to.
    static let commitKey = "VeriCopyGitCommit"

    /// "VeriCopy 1.0 · build 10 (4cd0265)" for the running bundle.
    static let display = describe(Bundle.main.infoDictionary ?? [:])

    /// "build 10 (4cd0265)" for the window subtitle, where the window already says VeriCopy.
    static let subtitle = describeBuild(Bundle.main.infoDictionary ?? [:])

    /// The build part alone. An unbundled `swift run` has none, so falls back to `describe`.
    static func describeBuild(_ info: [String: Any]) -> String {
        var parts: [String] = []
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty {
            parts.append("build \(build)")
        }
        if let commit = info[commitKey] as? String, !commit.isEmpty {
            parts.append("(\(commit))")
        }
        return parts.isEmpty ? describe(info) : parts.joined(separator: " ")
    }

    /// Formats an Info.plist dictionary. Parts it lacks are left out, so an unbundled
    /// `swift run` shows just "VeriCopy".
    static func describe(_ info: [String: Any]) -> String {
        var text = "VeriCopy"
        if let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            text += " \(version)"
        }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty {
            text += " · build \(build)"
        }
        if let commit = info[commitKey] as? String, !commit.isEmpty {
            text += " (\(commit))"
        }
        return text
    }
}
