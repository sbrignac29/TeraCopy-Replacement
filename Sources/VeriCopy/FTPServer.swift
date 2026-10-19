import Darwin
import Foundation
import VeriCopyCore

/// A received file, as surfaced in the UI.
struct ReceivedFile: Identifiable, Sendable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let size: Int64
    let checksum: String
    let verified: Bool
    let receivedAt: Date
    let message: String?
}

/// What the server reports back to the app layer. All callbacks arrive on the main actor.
@MainActor
protocol FTPServerDelegate: AnyObject {
    func ftpServerDidStart(port: UInt16)
    func ftpServerDidStop(reason: String?)
    func ftpServerDidUpdateClient(_ description: String?)
    func ftpServerDidReceive(_ file: ReceivedFile)
    func ftpServerDidLog(_ line: String)
}

/// A hand-rolled FTP server built on BSD sockets.
///
/// Sockets rather than `Network.framework` for two verified reasons: `NWListener` is
/// subject to macOS's Local Network Privacy gate and failed repeatedly under test, and
/// FTP's active mode requires connecting *back* to the client, which is more direct here.
/// All blocking socket work happens on a dedicated queue — never on Swift's cooperative
/// pool — for the same reason `TransferEngine` routes its I/O through `ioQueue`.
final class FTPServer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.vericopy.ftp", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var sessions: [FTPConnection] = []

    private(set) var settings: FTPSettings
    private let password: String
    private let root: URL
    private weak var delegate: FTPServerDelegate?

    var isRunning: Bool { stateLock.withLock { running } }

    init(settings: FTPSettings, password: String, root: URL, delegate: FTPServerDelegate) {
        self.settings = settings
        self.password = password
        self.root = root.standardizedFileURL
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    /// Binds and starts accepting. Returns an error string on failure (never throws) so the
    /// UI can show a real reason instead of silently doing nothing.
    func start() -> String? {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return nil }
        stateLock.unlock()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "The receive folder doesn't exist: \(root.path)"
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Could not create a socket (\(errnoText()))." }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = settings.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let reason = errno == EACCES
                ? "Port \(settings.port) needs elevated privileges on this Mac. Try a port above 1024 (e.g. 2121) and set the same port on the camera."
                : (errno == EADDRINUSE
                    ? "Port \(settings.port) is already in use by another program."
                    : "Could not bind port \(settings.port) (\(errnoText())).")
            close(fd)
            return reason
        }
        guard listen(fd, 8) == 0 else {
            let reason = "Could not listen on port \(settings.port) (\(errnoText()))."
            close(fd)
            return reason
        }

        stateLock.withLock {
            listenFD = fd
            running = true
        }
        let port = settings.port
        Task { @MainActor in self.delegate?.ftpServerDidStart(port: port) }
        queue.async { [weak self] in self?.acceptLoop(fd) }
        return nil
    }

    func stop(reason: String? = nil) {
        let fd: Int32 = stateLock.withLock {
            guard running else { return -1 }
            running = false
            let old = listenFD
            listenFD = -1
            return old
        }
        guard fd >= 0 else { return }
        // Closing the listening socket makes the blocking accept() return.
        shutdown(fd, SHUT_RDWR)
        close(fd)

        let open = stateLock.withLock { () -> [FTPConnection] in
            let current = sessions
            sessions = []
            return current
        }
        open.forEach { $0.close() }

        Task { @MainActor in
            self.delegate?.ftpServerDidUpdateClient(nil)
            self.delegate?.ftpServerDidStop(reason: reason)
        }
    }

    // MARK: - Accept loop

    private func acceptLoop(_ fd: Int32) {
        while stateLock.withLock({ running }) {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &length)
                }
            }
            guard client >= 0 else {
                if errno == EINTR { continue }
                break // listener closed
            }

            let peerIP = Self.ipString(peer.sin_addr)
            // Local means "a private range OR literally on one of my own subnets" — the
            // second clause matters on hotspots and odd networks that hand out addresses
            // outside the standard private blocks.
            let isLocal = isLANAddress(peerIP) || Self.isOnSameSubnet(peerIP)
            if settings.lanOnly && !isLocal {
                // Refuse before reading a byte: plain FTP must never serve the open internet.
                let refusal = "421 Service not available.\r\n"
                _ = refusal.withCString { send(client, $0, strlen($0), 0) }
                close(client)
                Task { @MainActor in
                    self.delegate?.ftpServerDidLog("Refused non-local connection from \(peerIP)")
                }
                continue
            }

            let connection = FTPConnection(
                controlFD: client,
                peerIP: peerIP,
                localIP: Self.localIP(for: client),
                settings: settings,
                password: password,
                root: root,
                delegate: delegate,
                queue: queue
            )
            stateLock.withLock { sessions.append(connection) }
            Task { @MainActor in self.delegate?.ftpServerDidUpdateClient(peerIP) }
            queue.async { [weak self] in
                connection.run()
                self?.stateLock.withLock {
                    self?.sessions.removeAll { $0 === connection }
                }
                Task { @MainActor in self?.delegate?.ftpServerDidUpdateClient(nil) }
            }
        }
    }

    // MARK: - Address helpers

    private func errnoText() -> String { String(cString: strerror(errno)) }

    static func ipString(_ addr: in_addr) -> String {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    /// The address the client reached us on — needed for a correct PASV reply.
    static func localIP(for fd: Int32) -> String {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return result == 0 ? ipString(addr.sin_addr) : "127.0.0.1"
    }

    /// Every non-loopback IPv4 address on this Mac, with its netmask.
    static func localIPv4Interfaces() -> [(name: String, ip: String, mask: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [(String, String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let sa = pointer.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                ipString($0.pointee.sin_addr)
            }
            let mask = pointer.pointee.ifa_netmask.map { netmask in
                netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    ipString($0.pointee.sin_addr)
                }
            } ?? "255.255.255.0"
            result.append((String(cString: pointer.pointee.ifa_name), ip, mask))
        }
        return result
    }

    /// The address to display for typing into the camera.
    ///
    /// Prefers a real Wi-Fi/Ethernet interface on a recognised private range, but falls
    /// back to *any* non-loopback IPv4 — some networks (hotspots, tethering, unusual
    /// corporate ranges) hand out addresses outside the standard private blocks, and the
    /// user still needs something concrete to type into the camera.
    static func primaryLANAddress() -> String? {
        let interfaces = localIPv4Interfaces()
        // 1. en* interface on a private range — the normal case.
        if let best = interfaces.first(where: { $0.name.hasPrefix("en") && isLANAddress($0.ip) }) {
            return best.ip
        }
        // 2. any private-range address.
        if let priv = interfaces.first(where: { isLANAddress($0.ip) }) { return priv.ip }
        // 3. any en* address at all.
        if let en = interfaces.first(where: { $0.name.hasPrefix("en") }) { return en.ip }
        // 4. anything non-loopback.
        return interfaces.first?.ip
    }

    /// True when `peer` sits on the same subnet as one of this Mac's own interfaces.
    ///
    /// Complements the private-range check: a camera on an unusual-but-genuinely-local
    /// subnet (e.g. a hotspot handing out 192.0.0.x) is still on *my* network and must not
    /// be refused, while anything routed from outside stays blocked.
    static func isOnSameSubnet(_ peer: String) -> Bool {
        func octets(_ text: String) -> [UInt8]? {
            let parts = text.split(separator: ".")
            guard parts.count == 4 else { return nil }
            var values: [UInt8] = []
            for part in parts {
                guard let value = UInt8(part) else { return nil }
                values.append(value)
            }
            return values
        }
        guard let peerOctets = octets(peer) else { return false }
        for interface in localIPv4Interfaces() {
            guard let ipOctets = octets(interface.ip),
                  let maskOctets = octets(interface.mask) else { continue }
            var matches = true
            for index in 0..<4 where (peerOctets[index] & maskOctets[index]) != (ipOctets[index] & maskOctets[index]) {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }
}
