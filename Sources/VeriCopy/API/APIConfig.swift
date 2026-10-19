import Foundation

/// Where the API may read from and write to, and which port it answers on.
///
/// Stored as JSON at ~/Library/Application Support/VeriCopy/api-config.json and written with
/// defaults the first time VeriCopy launches. It is a plain file on purpose: the allowlist is
/// the main thing standing between a stray HTTP request and the user's media drives, so it
/// should be editable and auditable without going through the app.
struct APIConfig: Codable {
    var enabled: Bool
    var port: UInt16
    /// Absolute paths. A source or destination must sit inside one of these, or be one.
    var allowedRoots: [String]
    /// Whether `POST /api/jobs` will accept `"mode": "move"`. A move deletes the source
    /// after the copy verifies, so this is the one switch that lets the API remove data.
    /// Turn it off here to make the API copy-only again without rebuilding.
    var allowMove: Bool

    static let fileName = "api-config.json"

    /// Decoded key by key with per-field fallbacks rather than by the synthesized
    /// initializer. A config file written by an earlier version has no `allowMove` key, and
    /// the synthesized decoder would throw on it — sending the whole file to the "corrupt"
    /// path and silently replacing the user's allowlist with the built-in default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = APIConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? fallback.port
        allowedRoots = try c.decodeIfPresent([String].self, forKey: .allowedRoots) ?? fallback.allowedRoots
        allowMove = try c.decodeIfPresent(Bool.self, forKey: .allowMove) ?? fallback.allowMove
    }

    init(enabled: Bool, port: UInt16, allowedRoots: [String], allowMove: Bool) {
        self.enabled = enabled
        self.port = port
        self.allowedRoots = allowedRoots
        self.allowMove = allowMove
    }

    static var `default`: APIConfig {
        APIConfig(
            enabled: true,
            port: 8787,
            allowedRoots: [
                "/Volumes/BRIGSMEDIA",                      // working
                "/Volumes/BRIGSMEDIA LIBRARY",              // library
                "/Volumes/Expansion/BRIGSMEDIA ARCHIVE",    // archive
                // A scratch area for trying the API out without touching a real drive.
                // Safe to delete this line once you're done testing.
                NSHomeDirectory() + "/VeriCopyAPITest",
            ],
            allowMove: true
        )
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeriCopy", isDirectory: true)
        return base.appendingPathComponent(fileName)
    }

    /// Reads the config, writing the default file first if none exists.
    /// Never throws — a corrupt file falls back to the default rather than leaving the API
    /// running with an empty (or, far worse, a partially parsed) allowlist.
    static func load() -> (config: APIConfig, note: String?) {
        let url = fileURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            let fresh = APIConfig.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            fresh.write()
            return (fresh, "Created \(url.path)")
        }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(APIConfig.self, from: data) else {
            return (.default, "Could not read \(url.path) — using built-in defaults.")
        }

        // A file written by an earlier version decodes fine (see `init(from:)`) but is
        // missing the newer keys, which leaves them invisible to anyone reading the file to
        // find out what they can change. Write the full set back once.
        let present = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let expected: Set<String> = ["enabled", "port", "allowedRoots", "allowMove"]
        if let present, !expected.isSubset(of: Set(present.keys)) {
            decoded.write()
        }
        return (decoded, nil)
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: APIConfig.fileURL)
    }
}

// MARK: - Path validation

enum PathValidationError: Error {
    case notAbsolute
    case outsideAllowlist
    case notFound
    case notADirectory

    var code: String {
        switch self {
        case .notAbsolute: return "path_not_absolute"
        case .outsideAllowlist: return "path_not_allowed"
        case .notFound: return "path_not_found"
        case .notADirectory: return "path_not_a_directory"
        }
    }
}

struct PathValidator {
    let allowedRoots: [URL]

    init(allowedRoots: [String]) {
        self.allowedRoots = allowedRoots.map { Self.canonical($0) }
    }

    /// Resolve a path to the form we compare on: absolute, no `.`/`..`, symlinks followed.
    ///
    /// Symlink resolution matters for both sides. Without it a symlink inside an allowed
    /// root could point anywhere on the system and pass the check; and `/tmp` is itself a
    /// symlink to `/private/tmp`, so resolving only one side would make an allowlist entry
    /// fail to match the very path it names.
    static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// True when `url` is one of the allowed roots or sits beneath one.
    ///
    /// Compared component by component, never as a string prefix: "/Volumes/BRIGSMEDIA"
    /// is a string prefix of "/Volumes/BRIGSMEDIA LIBRARY" and of "/Volumes/BRIGSMEDIAX",
    /// so a `hasPrefix` check here would silently widen the allowlist.
    func isAllowed(_ url: URL) -> Bool {
        let parts = url.pathComponents
        for root in allowedRoots {
            let rootParts = root.pathComponents
            guard parts.count >= rootParts.count else { continue }
            if Array(parts.prefix(rootParts.count)) == rootParts { return true }
        }
        return false
    }

    /// Validates a path that must already exist as a directory (a source folder, or the
    /// destination root we copy *into*).
    func existingDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { throw PathValidationError.notAbsolute }
        let url = Self.canonical(path)
        guard isAllowed(url) else { throw PathValidationError.outsideAllowlist }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PathValidationError.notFound
        }
        guard isDirectory.boolValue else { throw PathValidationError.notADirectory }
        return url
    }

    /// Validates a source, which may be a single file as well as a folder.
    func existingSource(_ path: String) throws -> URL {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { throw PathValidationError.notAbsolute }
        let url = Self.canonical(path)
        guard isAllowed(url) else { throw PathValidationError.outsideAllowlist }
        guard FileManager.default.fileExists(atPath: url.path) else { throw PathValidationError.notFound }
        return url
    }
}
