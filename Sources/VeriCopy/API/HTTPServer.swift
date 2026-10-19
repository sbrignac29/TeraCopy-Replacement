import Foundation
import Network

// A very small HTTP/1.1 server, loopback only.
//
// `NWListener` rather than BSD sockets (which is what `FTPServer` uses): that file's choice
// was driven by macOS's Local Network Privacy gate and by FTP active mode needing to dial
// back out to the client. Neither applies here — loopback traffic is exempt from the gate,
// and this server only ever answers. Verified on this machine before the code was written:
// a loopback `NWListener` binds and serves with no permission prompt.
//
// Neither API gives you HTTP; both hand you a TCP byte stream. The parsing below is the
// subset this API needs: a request line, headers, and a Content-Length body. No chunked
// encoding, no keep-alive, no TLS — all three would be weight for nothing on 127.0.0.1.

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased keys
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        // Java's `Instant.parse` reads ISO-8601 directly; the Swift default (a float offset
        // from 2001) would need hand-written conversion on the dashboard side.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"encoding_failed"}"#.utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ code: String, _ message: String, status: Int) -> HTTPResponse {
        .json(APIErrorResponse(error: code, message: message), status: status)
    }

    private static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
        413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
    ]

    func serialized() -> Data {
        let reason = Self.reasons[status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Serves requests on 127.0.0.1 and hands each one to `handler`.
final class HTTPServer: @unchecked Sendable {

    /// Requests are small JSON objects. Anything larger is a mistake or an attack, and
    /// refusing early keeps a connection from buffering without bound.
    private static let maxRequestBytes = 64 * 1024

    private let queue = DispatchQueue(label: "com.vericopy.api", qos: .userInitiated)
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private let stateLock = NSLock()
    private var running = false

    var isRunning: Bool { stateLock.withLock { running } }

    init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    /// Binds and starts listening. Returns an error string on failure, never throws, so the
    /// caller can surface a real reason instead of silently doing nothing.
    func start(port: UInt16, onReady: @escaping @Sendable (String?) -> Void) {
        stateLock.lock()
        guard !running else { stateLock.unlock(); onReady(nil); return }
        stateLock.unlock()

        let params = NWParameters.tcp
        // Binding the loopback address specifically — not `.any` — is what keeps this off
        // the network. It is a property of the socket, not a check we could forget to run.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params) else {
            onReady("Could not create a listener on port \(port).")
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateLock.withLock { self?.running = true }
                onReady(nil)
            case .failed(let error):
                self?.stateLock.withLock { self?.running = false }
                let hint = "\(error)".contains("Address already in use")
                    ? "Port \(port) is already in use by another program."
                    : "Could not listen on port \(port): \(error.localizedDescription)"
                onReady(hint)
            case .cancelled:
                self?.stateLock.withLock { self?.running = false }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.withLock { running = false }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            guard buffer.count <= Self.maxRequestBytes else {
                self.respond(connection, .error("request_too_large",
                                                "Requests are limited to \(Self.maxRequestBytes) bytes.",
                                                status: 413))
                return
            }

            switch Self.parse(buffer) {
            case .complete(let request):
                Task { [handler = self.handler] in
                    let response = await handler(request)
                    self.respond(connection, response)
                }
            case .needMore:
                if isComplete { connection.cancel() } else { self.read(connection, buffer: buffer) }
            case .malformed(let reason):
                self.respond(connection, .error("malformed_request", reason, status: 400))
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    private enum ParseResult {
        case complete(HTTPRequest)
        case needMore
        case malformed(String)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: headerTerminator) else { return .needMore }

        let headData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            return .malformed("Request headers were not valid UTF-8.")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed("Empty request.") }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .malformed("Malformed request line.") }
        let method = String(requestLine[0]).uppercased()
        // Strip any query string: none of these routes take query parameters, and keeping
        // it would make "/api/jobs" and "/api/jobs?x=1" two different paths to the router.
        let path = String(String(requestLine[1]).split(separator: "?", maxSplits: 1)[0])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let declared = Int(headers["content-length"] ?? "0") ?? 0
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= declared else { return .needMore }

        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: declared)])
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}
