import Foundation
import SwiftUI

/// Owns the local HTTP API: config, the listener, and its lifecycle.
///
/// Unlike `FTPCoordinator`, this one *does* start at launch. The FTP server deliberately
/// waits for a button because it accepts connections from the whole local network. This one
/// is bound to 127.0.0.1 and gated by a path allowlist, so nothing off this Mac can reach it
/// — and a dashboard that needed the user to press Start after every launch would not be
/// much of an integration. It can still be turned off in Settings ▸ API.
@MainActor
final class APICoordinator: ObservableObject {
    static let shared = APICoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var listeningPort: UInt16 = 8787
    @Published private(set) var allowedRoots: [String] = []
    /// Last thing that happened, for the Settings panel. Not an error channel on its own.
    @Published var statusMessage: String?

    private var server: HTTPServer?
    private var router: APIRouter?
    private var config = APIConfig.default

    var configPath: String { APIConfig.fileURL.path }

    /// Loads the config and, unless disabled, starts listening.
    func start() {
        let (loaded, note) = APIConfig.load()
        config = loaded
        listeningPort = loaded.port
        allowedRoots = loaded.allowedRoots
        if let note { statusMessage = note }

        guard loaded.enabled else {
            statusMessage = "The API is turned off in \(APIConfig.fileName)."
            return
        }
        startListening()
    }

    private func startListening() {
        guard server == nil else { return }

        let router = APIRouter(queue: QueueViewModel.shared, config: config)
        self.router = router

        let server = HTTPServer { request in
            // `handle` is isolated to the main actor, which is where QueueViewModel lives;
            // awaiting it from the listener's queue hops there automatically.
            await router.handle(request)
        }
        self.server = server

        let port = config.port
        server.start(port: port) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isRunning = false
                    self.statusMessage = error
                    self.server = nil
                } else {
                    self.isRunning = true
                    self.statusMessage = "Listening on http://127.0.0.1:\(port)"
                }
            }
        }
    }

    /// Re-reads the config file and restarts the listener if anything changed.
    func reload() {
        shutdown()
        start()
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        config.write()
        if enabled {
            startListening()
        } else {
            shutdown()
            statusMessage = "Stopped."
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
        router = nil
        isRunning = false
    }
}
