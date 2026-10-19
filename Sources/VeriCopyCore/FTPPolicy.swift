import Foundation

/// Settings for the built-in FTP receiver. A plain value type so the app can sync it from
/// `@AppStorage` and the test suite can construct it directly — same shape as
/// `PowerSettings` / `NotificationSettings`.
public struct FTPSettings: Sendable, Equatable {
    public var port: UInt16
    public var username: String
    /// Refuse control connections from anything that isn't on a private/loopback network.
    public var lanOnly: Bool
    /// When false (the default) an incoming file that collides gets a new name rather than
    /// clobbering what's already on disk — a receiver must never destroy existing data.
    public var overwriteExisting: Bool
    public var algorithm: HashAlgorithm

    public init(port: UInt16 = 21,
                username: String = "camera",
                lanOnly: Bool = true,
                overwriteExisting: Bool = false,
                algorithm: HashAlgorithm = .sha256) {
        self.port = port
        self.username = username
        self.lanOnly = lanOnly
        self.overwriteExisting = overwriteExisting
        self.algorithm = algorithm
    }
}

// MARK: - Path confinement (security boundary)

/// Resolves an FTP-supplied path against the session's working directory, confined to `root`.
///
/// Returns `nil` for anything that would escape the receive folder. This is the single
/// gate protecting the rest of the disk from a malformed or hostile client, so it is a
/// pure function with no filesystem access — every rejection case is asserted in the
/// test suite rather than argued about.
///
/// - Parameters:
///   - raw: the path exactly as it arrived on the wire (may be absolute, relative, or empty)
///   - cwd: the session's current directory as an FTP-absolute path, e.g. `/` or `/2026-08-05`
///   - root: the real directory on disk that `/` maps to
public func resolveFTPPath(_ raw: String, cwd: String, root: URL) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)

    // Reject NUL and newline injection outright.
    guard !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
        return nil
    }

    // An FTP-absolute path is rooted at the receive folder; anything else is relative to cwd.
    let combined = trimmed.hasPrefix("/") ? trimmed : cwd + "/" + trimmed

    var stack: [String] = []
    for component in combined.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            // Escaping above the receive folder is never allowed — not even transiently.
            if stack.isEmpty { return nil }
            stack.removeLast()
        default:
            let name = String(component)
            // A component that is only dots (beyond "." / "..") is suspicious; and a
            // component containing a path separator can't happen after splitting, but a
            // literal backslash could still confuse downstream consumers.
            if name.contains("\\") { return nil }
            stack.append(name)
        }
    }

    let base = root.standardizedFileURL
    guard !stack.isEmpty else { return base } // "/" resolves to the receive folder itself

    var url = base
    for component in stack {
        url.appendPathComponent(component)
    }
    let resolved = url.standardizedFileURL

    // Belt and braces: after standardizing, the result must still be inside root.
    let rootPath = base.path.hasSuffix("/") ? base.path : base.path + "/"
    guard resolved.path == base.path || resolved.path.hasPrefix(rootPath) else { return nil }
    return resolved
}

/// The FTP-visible path for a resolved URL, used for `PWD` and `CWD` replies.
public func ftpDisplayPath(for url: URL, root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path != base else { return "/" }
    let rootPrefix = base.hasSuffix("/") ? base : base + "/"
    guard path.hasPrefix(rootPrefix) else { return "/" }
    return "/" + String(path.dropFirst(rootPrefix.count))
}

// MARK: - Network filtering

/// True when `ip` is loopback or on a private/link-local network.
///
/// Used to refuse control connections from off-network peers before a single byte is read.
/// Plain FTP sends credentials in the clear, so the receiver should never be reachable
/// from the public internet even if the user has forwarded a port by accident.
public func isLANAddress(_ ip: String) -> Bool {
    let address = ip.hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip // IPv4-mapped IPv6

    // IPv6 forms
    if address == "::1" { return true }
    if address.contains(":") {
        let lower = address.lowercased()
        if lower.hasPrefix("fe80") { return true }              // link-local
        if let first = lower.split(separator: ":").first,
           let value = UInt16(first, radix: 16) {
            if (value & 0xFE00) == 0xFC00 { return true }        // fc00::/7 unique-local
        }
        return false
    }

    // IPv4
    let parts = address.split(separator: ".")
    guard parts.count == 4 else { return false }
    var octets: [UInt8] = []
    for part in parts {
        guard let value = UInt8(part) else { return false }
        octets.append(value)
    }
    switch (octets[0], octets[1]) {
    case (127, _): return true                                   // loopback
    case (10, _): return true                                    // 10/8
    case (192, 168): return true                                 // 192.168/16
    case (169, 254): return true                                 // link-local
    case (172, let second) where (16...31).contains(second): return true // 172.16/12
    default: return false
    }
}

// MARK: - Command parsing

/// One parsed FTP control command. Parsing is pure so odd spacing, casing and CRLF
/// handling are all provable in the test suite.
public enum FTPCommand: Equatable, Sendable {
    case user(String)
    case pass(String)
    case stor(String)
    case retr(String)
    case cwd(String)
    case cdup
    case mkd(String)
    case pwd
    case type(String)
    case pasv
    case epsv
    case port(host: String, port: UInt16)
    case list(String?)
    case nlst(String?)
    case size(String)
    case dele(String)
    case noop
    case syst
    case feat
    case opts(String)
    case quit
    case abor
    case unsupported(String)

    public static func parse(_ line: String) -> FTPCommand {
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                          .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return .unsupported("") }

        // Split on the FIRST space only: filenames legitimately contain spaces.
        let verb: String
        let argument: String
        if let spaceIndex = cleaned.firstIndex(of: " ") {
            verb = String(cleaned[cleaned.startIndex..<spaceIndex]).uppercased()
            argument = String(cleaned[cleaned.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            verb = cleaned.uppercased()
            argument = ""
        }

        switch verb {
        case "USER": return .user(argument)
        case "PASS": return .pass(argument)
        case "STOR": return .stor(argument)
        case "RETR": return .retr(argument)
        case "CWD": return .cwd(argument)
        case "CDUP": return .cdup
        case "MKD", "XMKD": return .mkd(argument)
        case "PWD", "XPWD": return .pwd
        case "TYPE": return .type(argument.uppercased())
        case "PASV": return .pasv
        case "EPSV": return .epsv
        case "PORT": return parsePort(argument)
        case "LIST": return .list(argument.isEmpty ? nil : argument)
        case "NLST": return .nlst(argument.isEmpty ? nil : argument)
        case "SIZE": return .size(argument)
        case "DELE": return .dele(argument)
        case "NOOP": return .noop
        case "SYST": return .syst
        case "FEAT": return .feat
        case "OPTS": return .opts(argument.uppercased())
        case "QUIT", "BYE": return .quit
        case "ABOR": return .abor
        default: return .unsupported(verb)
        }
    }

    /// `PORT h1,h2,h3,h4,p1,p2` — the camera telling us where to connect back (active mode).
    private static func parsePort(_ argument: String) -> FTPCommand {
        let fields = argument.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard fields.count == 6 else { return .unsupported("PORT") }
        var numbers: [UInt16] = []
        for field in fields {
            guard let value = UInt16(field), value <= 255 else { return .unsupported("PORT") }
            numbers.append(value)
        }
        let host = numbers[0...3].map(String.init).joined(separator: ".")
        let port = numbers[4] << 8 | numbers[5]
        guard port > 0 else { return .unsupported("PORT") }
        return .port(host: host, port: port)
    }
}

// MARK: - Response formatting

public enum FTPResponse {
    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)` — the exact form clients parse.
    public static func pasv(host: String, port: UInt16) -> String {
        let hostFields = host.split(separator: ".").map(String.init).joined(separator: ",")
        return "227 Entering Passive Mode (\(hostFields),\(port >> 8),\(port & 0xFF))"
    }

    /// `229 Entering Extended Passive Mode (|||port|)`
    public static func epsv(port: UInt16) -> String {
        "229 Entering Extended Passive Mode (|||\(port)|)"
    }

    /// A UNIX `ls -l` style line. Cameras and clients parse this loosely, but the column
    /// layout has to look conventional or listings are misread.
    public static func listLine(name: String,
                                size: Int64,
                                isDirectory: Bool,
                                modified: Date,
                                now: Date = Date()) -> String {
        let permissions = isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        let links = isDirectory ? 2 : 1

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        // Convention: recent files show a time, older than ~6 months show the year.
        let sixMonths: TimeInterval = 60 * 60 * 24 * 182
        formatter.dateFormat = abs(now.timeIntervalSince(modified)) > sixMonths
            ? "MMM dd  yyyy"
            : "MMM dd HH:mm"
        let stamp = formatter.string(from: modified)

        let sizeField = String(format: "%12lld", size)
        return "\(permissions) \(links) vericopy vericopy \(sizeField) \(stamp) \(name)"
    }
}
