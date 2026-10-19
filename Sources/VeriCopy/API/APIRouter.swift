import Foundation
import VeriCopyCore

/// Maps HTTP requests onto the queue VeriCopy already runs.
///
/// A "route" here is nothing more than a method plus a path matched to one function. With
/// five of them a `switch` is the whole router; a framework would be weight for nothing.
///
/// Everything runs on the main actor, which is where `QueueViewModel` lives. That also makes
/// concurrent requests safe for free: two simultaneous POSTs are serialised by the actor, so
/// the "does the destination already exist?" check and the job creation that follows it
/// cannot interleave with another request's.
@MainActor
final class APIRouter {

    private let queue: QueueViewModel
    private var validator: PathValidator
    private(set) var config: APIConfig

    init(queue: QueueViewModel, config: APIConfig) {
        self.queue = queue
        self.config = config
        self.validator = PathValidator(allowedRoots: config.allowedRoots)
    }

    func apply(config: APIConfig) {
        self.config = config
        self.validator = PathValidator(allowedRoots: config.allowedRoots)
    }

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: - Dispatch

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // A browser attaches `Origin` to every cross-origin request; a server-to-server
        // client never does. Refusing it stops any page the user happens to be visiting
        // from driving their drives through this API. The dashboard is a Java web server
        // calling VeriCopy from its own backend, so it is unaffected — and this is why no
        // CORS headers are sent: there is no browser origin we want to allow.
        if let origin = request.header("Origin") {
            return .error("browser_origin_refused",
                          "This API does not serve browsers. Call it from your server, not "
                          + "from page JavaScript. (Origin: \(origin))",
                          status: 403)
        }

        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        // Path first, then method, so a known path reached with the wrong verb gets a 405
        // that says so rather than a 404 that sends the caller hunting for a typo they did
        // not make. An if-chain rather than a switch because Swift's array patterns cannot
        // bind an element, and the job id is exactly that.
        if parts == ["api", "health"] {
            guard request.method == "GET" else { return methodNotAllowed(request) }
            return .json(HealthResponse(ok: true, version: version, queueActive: queue.queueActive))
        }

        if parts == ["api", "jobs"] {
            switch request.method {
            case "POST":
                return await createJob(request)
            case "GET":
                // Newest first: a dashboard showing "recent jobs" wants the latest on top.
                // The empty draft VeriCopy always keeps at the end of the list is scaffolding
                // for the window, not a job — reporting it as permanently "queued" would just
                // confuse a dashboard that never created it.
                let real = queue.jobs.reversed().filter { !($0.items.isEmpty && $0.destination == nil) }
                return .json(JobListResponse(jobs: real.map(status(of:))))
            default:
                return methodNotAllowed(request)
            }
        }

        if parts.count == 3, parts[0] == "api", parts[1] == "jobs" {
            guard request.method == "GET" else { return methodNotAllowed(request) }
            guard let job = job(withID: parts[2]) else { return unknownJob(parts[2]) }
            return .json(status(of: job))
        }

        if parts.count == 4, parts[0] == "api", parts[1] == "jobs", parts[3] == "cancel" {
            guard request.method == "POST" else { return methodNotAllowed(request) }
            guard let job = job(withID: parts[2]) else { return unknownJob(parts[2]) }
            guard queue.cancelJob(job) else {
                return .error("job_not_cancellable",
                              "Job \(parts[2]) has already finished (\(APIJobStatus.of(job).rawValue)).",
                              status: 409)
            }
            return .json(status(of: job))
        }

        return .error("not_found", "No route for \(request.method) \(request.path).", status: 404)
    }

    private func methodNotAllowed(_ request: HTTPRequest) -> HTTPResponse {
        .error("method_not_allowed",
               "\(request.method) is not supported on \(request.path).",
               status: 405)
    }

    private func unknownJob(_ id: String) -> HTTPResponse {
        .error("job_not_found", "No job with id \(id).", status: 404)
    }

    private func job(withID id: String) -> TransferJob? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return queue.jobs.first { $0.id == uuid }
    }

    // MARK: - POST /api/jobs

    private func createJob(_ request: HTTPRequest) async -> HTTPResponse {
        // Requiring JSON is not pedantry: it is the header that forces a browser to send a
        // CORS preflight, which this server never answers. Together with the Origin check
        // above, that leaves no path for a drive-by request from a web page.
        let contentType = request.header("Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("application/json") else {
            return .error("unsupported_media_type",
                          "Send Content-Type: application/json.",
                          status: 400)
        }

        let decoded: CreateJobRequest
        do {
            decoded = try JSONDecoder().decode(CreateJobRequest.self, from: request.body)
        } catch {
            return .error("invalid_body",
                          #"Body must be {"source": "/absolute/path", "destination": "/absolute/path"}."#,
                          status: 400)
        }

        // Absent means copy, so a caller written against the copy-only version of this API
        // keeps copying and cannot start deleting things by accident.
        let requestedMode = (decoded.mode ?? "copy").lowercased()
        let transferMode: TransferMode
        switch requestedMode {
        case "copy":
            transferMode = .copy
        case "move":
            guard config.allowMove else {
                return .error("move_not_allowed",
                              "Moves are turned off. Set \"allowMove\": true in "
                              + "\(APIConfig.fileURL.path) to enable them.",
                              status: 403)
            }
            transferMode = .move
        default:
            return .error("invalid_mode",
                          "mode must be \"copy\" or \"move\"; got \"\(requestedMode)\".",
                          status: 400)
        }

        // Structure is now guaranteed by Codable. Meaning is not — the allowlist, existence
        // and overwrite checks are all still ours to make.
        let sourceURL: URL
        let destinationRoot: URL
        do {
            sourceURL = try validator.existingSource(decoded.source)
        } catch let error as PathValidationError {
            return pathError(error, field: "source", path: decoded.source)
        } catch {
            return .error("invalid_source", "Could not read source.", status: 400)
        }
        do {
            destinationRoot = try validator.existingDirectory(decoded.destination)
        } catch let error as PathValidationError {
            return pathError(error, field: "destination", path: decoded.destination)
        } catch {
            return .error("invalid_destination", "Could not read destination.", status: 400)
        }

        // Copying a folder into itself, or into its own subtree, would recurse.
        if destinationRoot.path == sourceURL.path
            || destinationRoot.pathComponents.starts(with: sourceURL.pathComponents) {
            return .error("destination_inside_source",
                          "The destination is inside the source; that would copy into itself.",
                          status: 400)
        }

        // A move deletes the source once each file verifies, so it gets two guards a copy
        // does not need.
        if transferMode == .move {
            // Refuse to move an allowlist root itself. The roots are whole drives (or the
            // folders standing in for them); "move /Volumes/BRIGSMEDIA" is never a thing the
            // dashboard means, and it would try to empty one.
            if validator.allowedRoots.contains(where: { $0.pathComponents == sourceURL.pathComponents }) {
                return .error("cannot_move_root",
                              "\(sourceURL.path) is an allowed root itself. Move something "
                              + "inside it, not the root.",
                              status: 403)
            }
            // Removing an entry needs write permission on the folder holding it, not on the
            // entry. Catching that here turns a half-finished move into an upfront refusal.
            let parent = sourceURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                return .error("source_not_writable",
                              "A move has to delete the source afterwards, and \(parent.path) "
                              + "is not writable. Use \"mode\": \"copy\" instead.",
                              status: 403)
            }
        }

        // The safety rule: this API only ever creates new files. VeriCopy copies *into* a
        // destination root, so the thing that must not already exist is the folder (or file)
        // the source would land as.
        let target = destinationRoot.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            return .error("destination_exists",
                          "\(target.path) already exists. This API never overwrites, deletes "
                          + "or merges — move or rename it first, or pick another destination.",
                          status: 409)
        }

        // Scanning is a filesystem walk, so it happens off the main actor. It is awaited
        // rather than backgrounded: it is what turns an unreadable or empty source into an
        // honest 400 now, instead of a job that mysteriously fails later. Large trees can
        // make this request take a few seconds — see API.md.
        let plan = await Task.detached(priority: .userInitiated) {
            SourceScanner.scan(sources: [sourceURL])
        }.value

        guard !plan.items.isEmpty else {
            return .error("source_empty",
                          "Nothing to copy — \(sourceURL.path) contains no files.",
                          status: 400)
        }

        let job = queue.newJob(select: false)
        job.persistsSettings = false   // must not rewrite the user's UI defaults
        job.createdViaAPI = true
        job.name = sourceURL.lastPathComponent
        job.mode = transferMode        // .copy unless the caller explicitly asked to move
        // Always on. For a move this is what stands between a verified copy and a deleted
        // source: the engine removes each source only once its copy reads back clean.
        job.verification = .perFile
        job.completionAction = .nothing // never sleep or quit the Mac behind a dashboard request
        job.destination = destinationRoot
        job.sourceRoots = [sourceURL]
        job.items = plan.items
        job.directories = plan.directories
        job.directorySources = plan.directorySources
        job.totalBytes = plan.totalBytes
        job.progressTotal = plan.totalBytes

        // No-op when a queue is already draining — that loop re-scans for ready jobs on each
        // pass and will pick this one up in order, one job at a time.
        queue.startQueue()

        return .json(CreateJobResponse(jobId: job.id.uuidString), status: 202)
    }

    private func pathError(_ error: PathValidationError, field: String, path: String) -> HTTPResponse {
        let message: String
        switch error {
        case .notAbsolute:
            message = "\(field) must be an absolute path; got \"\(path)\"."
        case .outsideAllowlist:
            message = "\(field) \"\(path)\" is not inside an allowed root. Allowed: "
                + config.allowedRoots.joined(separator: ", ")
                + ". Edit \(APIConfig.fileURL.path) to change this."
        case .notFound:
            message = "\(field) \"\(path)\" does not exist. If it is on an external drive, "
                + "check the drive is plugged in and mounted."
        case .notADirectory:
            message = "\(field) \"\(path)\" is not a folder."
        }
        return .error(error.code, message, status: error == .outsideAllowlist ? 403 : 400)
    }

    // MARK: - Status projection

    private func status(of job: TransferJob) -> JobStatusResponse {
        let counts = job.statusCounts
        let tally = job.apiTally
        let failed = job.items
            .filter { $0.status == .failed }
            .map { FailedFileDTO(path: $0.relativePath, message: $0.message ?? "Failed") }

        return JobStatusResponse(
            jobId: job.id.uuidString,
            name: job.name,
            origin: job.createdViaAPI ? "api" : "ui",
            mode: job.mode.rawValue.lowercased(),
            status: APIJobStatus.of(job, tally: tally).rawValue,
            sources: job.sourceRoots.map(\.path).sorted(),
            destination: job.destination?.path,
            progress: job.progressFraction,
            bytesCopied: job.progressDone,
            bytesTotal: job.totalBytes,
            filesTotal: job.items.count,
            filesCopied: counts.copied,
            filesVerified: counts.verified,
            filesFailed: counts.failed,
            filesUnverified: tally.unverified,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            secondsRemaining: job.secondsRemaining,
            fatalError: job.summary?.fatalError,
            failedFiles: failed
        )
    }
}

extension PathValidationError: Equatable {}
