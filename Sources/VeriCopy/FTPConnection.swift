import Darwin
import Foundation
import VeriCopyCore

/// One FTP control connection: the protocol state machine plus the upload path.
///
/// Runs entirely on the server's dispatch queue (blocking socket calls), and only hops to
/// the main actor to report progress.
final class FTPConnection: @unchecked Sendable {

    private let controlFD: Int32
    private let peerIP: String
    private let localIP: String
    private let settings: FTPSettings
    private let password: String
    private let root: URL
    private weak var delegate: FTPServerDelegate?
    private let queue: DispatchQueue

    // Session state
    private var authenticatedUser: String?
    private var loggedIn = false
    private var failedAttempts = 0
    private var cwd = "/"
    private var binaryMode = true
    /// Passive listener, when the client asked for PASV/EPSV.
    private var passiveFD: Int32 = -1
    /// Active-mode target, when the client sent PORT.
    private var activeTarget: (host: String, port: UInt16)?
    private var closed = false

    private static let bufferSize = 1 << 20 // 1 MiB socket chunks

    init(controlFD: Int32,
         peerIP: String,
         localIP: String,
         settings: FTPSettings,
         password: String,
         root: URL,
         delegate: FTPServerDelegate?,
         queue: DispatchQueue) {
        self.controlFD = controlFD
        self.peerIP = peerIP
        self.localIP = localIP
        self.settings = settings
        self.password = password
        self.root = root
        self.delegate = delegate
        self.queue = queue
    }

    func close() {
        guard !closed else { return }
        closed = true
        closePassive()
        shutdown(controlFD, SHUT_RDWR)
        Darwin.close(controlFD)
    }

    // MARK: - Control loop

    func run() {
        log("Connected from \(peerIP)")
        send("220 VeriCopy FTP ready")

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !closed {
            let n = recv(controlFD, &buffer, buffer.count, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            pending.append(contentsOf: buffer[0..<n])

            // Commands are CRLF-delimited; a single read may hold several or a partial one.
            while let range = pending.range(of: Data([0x0D, 0x0A]))
                    ?? pending.range(of: Data([0x0A])) {
                let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8)
                        ?? String(data: lineData, encoding: .isoLatin1) else { continue }
                if handle(FTPCommand.parse(line), raw: line) == .disconnect {
                    close()
                    log("Disconnected \(peerIP)")
                    return
                }
            }
            // Guard against a client that never sends a newline.
            if pending.count > 8192 { pending.removeAll() }
        }
        close()
        log("Disconnected \(peerIP)")
    }

    private enum Outcome { case keepGoing, disconnect }

    private func handle(_ command: FTPCommand, raw: String) -> Outcome {
        // Never log the password itself.
        if case .pass = command {
            log("← PASS ****")
        } else {
            log("← \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Everything except the handshake commands requires a login.
        switch command {
        case .user, .pass, .quit, .noop, .syst, .feat, .opts:
            break
        default:
            guard loggedIn else {
                send("530 Please log in with USER and PASS.")
                return .keepGoing
            }
        }

        switch command {
        case .user(let name):
            authenticatedUser = name
            loggedIn = false
            send("331 Password required for \(name).")

        case .pass(let supplied):
            let userOK = authenticatedUser == settings.username
            let passOK = supplied == password
            if userOK && passOK {
                loggedIn = true
                failedAttempts = 0
                send("230 Logged in.")
                log("Authenticated as \(settings.username)")
            } else {
                failedAttempts += 1
                send("530 Login incorrect.")
                log("Failed login attempt \(failedAttempts) from \(peerIP)")
                if failedAttempts >= 3 {
                    send("421 Too many failed attempts.")
                    return .disconnect
                }
            }

        case .syst:
            send("215 UNIX Type: L8")

        case .feat:
            // Multi-line reply. Cameras probe this to decide what they can use.
            sendRaw("211-Features:\r\n SIZE\r\n MDTM\r\n UTF8\r\n EPSV\r\n211 End\r\n")

        case .opts(let argument):
            send(argument.hasPrefix("UTF8") ? "200 UTF8 set to on." : "200 OK.")

        case .noop:
            send("200 OK.")

        case .type(let mode):
            binaryMode = mode.hasPrefix("I") || mode.hasPrefix("L")
            send("200 Type set to \(binaryMode ? "I" : "A").")

        case .pwd:
            send("257 \"\(cwd)\" is the current directory.")

        case .cwd(let path):
            changeDirectory(to: path)

        case .cdup:
            changeDirectory(to: "..")

        case .mkd(let path):
            makeDirectory(path)

        case .pasv:
            enterPassive(extended: false)

        case .epsv:
            enterPassive(extended: true)

        case .port(let host, let port):
            // Active mode: we connect back to the camera for data.
            closePassive()
            activeTarget = (host, port)
            send("200 PORT command successful.")

        case .stor(let name):
            receiveFile(named: name)

        case .list(let path):
            sendListing(path: path, namesOnly: false)

        case .nlst(let path):
            sendListing(path: path, namesOnly: true)

        case .size(let name):
            if let url = resolve(name),
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                send("213 \(size)")
            } else {
                send("550 Could not determine size.")
            }

        case .retr(let name):
            sendFile(named: name)

        case .dele(let name):
            // Deliberately refused: a receiver should never destroy the user's photos.
            _ = name
            send("550 Deleting files is not permitted.")

        case .abor:
            send("226 Abort successful.")

        case .quit:
            send("221 Goodbye.")
            return .disconnect

        case .unsupported(let verb):
            send(verb.isEmpty ? "500 Syntax error." : "502 Command '\(verb)' not implemented.")
        }
        return .keepGoing
    }

    // MARK: - Directories

    private func resolve(_ path: String) -> URL? {
        resolveFTPPath(path, cwd: cwd, root: root)
    }

    private func changeDirectory(to path: String) {
        guard let url = resolve(path) else {
            send("550 Path not allowed.")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            send("550 No such directory.")
            return
        }
        cwd = ftpDisplayPath(for: url, root: root)
        send("250 Directory changed to \(cwd).")
    }

    /// Cameras routinely create a dated folder before uploading.
    private func makeDirectory(_ path: String) {
        guard let url = resolve(path) else {
            send("550 Path not allowed.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            send("257 \"\(ftpDisplayPath(for: url, root: root))\" created.")
        } catch {
            send("550 Could not create directory.")
        }
    }

    // MARK: - Data channel

    private func closePassive() {
        if passiveFD >= 0 {
            Darwin.close(passiveFD)
            passiveFD = -1
        }
    }

    /// Opens a listening socket on an ephemeral port and tells the client where to connect.
    private func enterPassive(extended: Bool) {
        closePassive()
        activeTarget = nil

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { send("425 Can't open data connection."); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the kernel choose
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            send("425 Can't open data connection.")
            return
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        passiveFD = fd

        send(extended ? FTPResponse.epsv(port: port)
                      : FTPResponse.pasv(host: localIP, port: port))
    }

    /// Returns a connected data socket for whichever mode the client selected.
    private func openDataConnection() -> Int32? {
        if passiveFD >= 0 {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(passiveFD, $0, &length)
                }
            }
            closePassive()
            return fd >= 0 ? fd : nil
        }
        if let target = activeTarget {
            // Active mode: connect back to the client.
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = target.port.bigEndian
            inet_pton(AF_INET, target.host, &addr.sin_addr)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            activeTarget = nil
            if connected == 0 { return fd }
            Darwin.close(fd)
            return nil
        }
        return nil
    }

    // MARK: - STOR (the critical path)

    private func receiveFile(named name: String) {
        guard let target = resolve(name) else {
            send("550 Path not allowed.")
            return
        }
        guard !name.isEmpty, target.path != root.path else {
            send("550 Invalid filename.")
            return
        }

        // Never clobber existing data unless the user explicitly opted in.
        var destination = target
        if FileManager.default.fileExists(atPath: destination.path), !settings.overwriteExisting {
            destination = TransferEngine.availableURL(for: destination)
        }

        // Same atomic idiom as the copy engine: stream into a hidden sibling, then rename,
        // so a dropped connection never leaves a half-written photo at the real path.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).vcpart")
        try? FileManager.default.removeItem(at: partial)

        // Make sure the parent exists (camera may STOR into a folder it just created).
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            send("550 Could not create file.")
            return
        }

        send("150 Opening data connection for \(destination.lastPathComponent).")
        guard let dataFD = openDataConnection() else {
            try? FileManager.default.removeItem(at: partial)
            send("425 Can't open data connection.")
            return
        }
        defer { Darwin.close(dataFD) }

        guard let handle = FileHandle(forWritingAtPath: partial.path) else {
            try? FileManager.default.removeItem(at: partial)
            send("550 Could not open file for writing.")
            return
        }

        // Hash the bytes as they arrive, using the engine's public hasher.
        let hasher = settings.algorithm.makeHasher()
        var received: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        var failed: String?

        while true {
            let n = recv(dataFD, &buffer, buffer.count, 0)
            if n == 0 { break }               // clean EOF: transfer complete
            if n < 0 {
                if errno == EINTR { continue }
                failed = String(cString: strerror(errno))
                break
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(buffer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
            do {
                try handle.write(contentsOf: Data(bytes: buffer, count: n))
            } catch {
                failed = error.localizedDescription
                break
            }
            received += Int64(n)
        }
        try? handle.synchronize()
        try? handle.close()

        if let failed {
            try? FileManager.default.removeItem(at: partial)
            send("426 Transfer failed: \(failed)")
            log("Upload of \(destination.lastPathComponent) failed: \(failed)")
            return
        }

        let sourceHex = hasher.finalizedHex()
        do {
            if settings.overwriteExisting,
               FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            send("550 Could not finalize file.")
            return
        }

        // Read back from disk, bypassing the cache, to prove what landed matches the wire.
        let landedHex = Self.hashOnDisk(destination, algorithm: settings.algorithm)
        let verified = (landedHex == sourceHex)
        send(verified
             ? "226 Transfer complete."
             : "226 Transfer complete (verification mismatch).")

        let file = ReceivedFile(
            name: destination.lastPathComponent,
            url: destination,
            size: received,
            checksum: sourceHex,
            verified: verified,
            receivedAt: Date(),
            message: verified
                ? "\(settings.algorithm.rawValue) verified"
                : "Checksum mismatch after writing to disk"
        )
        Task { @MainActor in self.delegate?.ftpServerDidReceive(file) }
        log("Received \(destination.lastPathComponent) (\(received) bytes) — \(verified ? "verified" : "MISMATCH")")
    }

    /// Re-reads a file with the unified buffer cache bypassed and returns its hex digest.
    private static func hashOnDisk(_ url: URL, algorithm: HashAlgorithm) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        let hasher = algorithm.makeHasher()
        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalizedHex()
    }

    // MARK: - LIST / RETR

    private func sendListing(path: String?, namesOnly: Bool) {
        let target = resolve(path ?? ".") ?? root
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])) ?? []

        var body = ""
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue } // hide dotfiles and .vcpart temporaries
            if namesOnly {
                body += name + "\r\n"
            } else {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
                body += FTPResponse.listLine(
                    name: name,
                    size: Int64(values?.fileSize ?? 0),
                    isDirectory: values?.isDirectory ?? false,
                    modified: values?.contentModificationDate ?? Date()
                ) + "\r\n"
            }
        }

        send("150 Opening data connection for directory listing.")
        guard let dataFD = openDataConnection() else {
            send("425 Can't open data connection.")
            return
        }
        _ = body.withCString { pointer -> Int in
            Darwin.send(dataFD, pointer, strlen(pointer), 0)
        }
        Darwin.close(dataFD)
        send("226 Directory send OK.")
    }

    private func sendFile(named name: String) {
        guard let url = resolve(name),
              let handle = FileHandle(forReadingAtPath: url.path) else {
            send("550 No such file.")
            return
        }
        defer { try? handle.close() }
        send("150 Opening data connection.")
        guard let dataFD = openDataConnection() else {
            send("425 Can't open data connection.")
            return
        }
        while let chunk = try? handle.read(upToCount: Self.bufferSize), !chunk.isEmpty {
            var sentTotal = 0
            chunk.withUnsafeBytes { raw in
                while sentTotal < chunk.count {
                    let n = Darwin.send(dataFD, raw.baseAddress!.advanced(by: sentTotal),
                                        chunk.count - sentTotal, 0)
                    if n <= 0 { sentTotal = chunk.count; break }
                    sentTotal += n
                }
            }
        }
        Darwin.close(dataFD)
        send("226 Transfer complete.")
    }

    // MARK: - Control replies

    private func send(_ line: String) {
        sendRaw(line + "\r\n")
        log("→ \(line)")
    }

    private func sendRaw(_ text: String) {
        text.withCString { pointer in
            let total = strlen(pointer)
            var offset = 0
            while offset < total {
                let n = Darwin.send(controlFD, pointer.advanced(by: offset), total - offset, 0)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private func log(_ line: String) {
        Task { @MainActor in self.delegate?.ftpServerDidLog(line) }
    }
}
