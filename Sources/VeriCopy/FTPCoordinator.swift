import Foundation
import SwiftUI
import VeriCopyCore

/// Owns the FTP receiver: settings, credentials, live session state, and the server itself.
///
/// Unlike the other coordinators this one deliberately does NOT start its service at
/// launch — the user asked for the server to run only while they're actively ingesting,
/// so it starts and stops solely from the Receive tab's button.
@MainActor
final class FTPCoordinator: ObservableObject, FTPServerDelegate {
    static let shared = FTPCoordinator()

    // UserDefaults keys, shared with SettingsView's @AppStorage.
    enum Key {
        static let port = "ftpPort"
        static let username = "ftpUsername"
        static let rootPath = "ftpRootPath"
        static let lanOnly = "ftpLanOnly"
        static let overwrite = "ftpOverwrite"
    }

    @Published private(set) var isRunning = false
    @Published private(set) var listeningPort: UInt16 = 21
    @Published private(set) var connectedClient: String?
    @Published private(set) var receivedFiles: [ReceivedFile] = []
    @Published private(set) var log: [String] = []
    @Published var statusMessage: String?
    /// The address to type into the camera, refreshed when the server starts.
    @Published private(set) var advertisedAddress: String?

    private var settings = FTPSettings()
    private var server: FTPServer?
    private var observer: NSObjectProtocol?

    /// In-memory copy of the password, and whether we've consulted the Keychain yet.
    ///
    /// CRITICAL: the Keychain must be read at most once per launch. `SecItemCopyMatching`
    /// can raise a system authorization prompt (an ad-hoc signature changes identity on
    /// every rebuild, so the stored ACL never matches), and SwiftUI re-evaluates a view
    /// body constantly — reading it from a computed property used by the UI produced an
    /// unstoppable cascade of prompts. Everything the UI touches now reads this cache.
    private var cachedPassword = ""
    private var didLoadPassword = false
    /// Published so the UI can gate the Start button without ever touching the Keychain.
    @Published private(set) var hasPassword = false

    var receiveFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: Key.rootPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    var currentSettings: FTPSettings { settings }

    /// Cheap, prompt-free read of the current password. Safe to call from a view body.
    var password: String { cachedPassword }

    func setPassword(_ newValue: String) {
        cachedPassword = newValue
        hasPassword = !newValue.isEmpty
        didLoadPassword = true
        KeychainStore.setPassword(newValue, account: settings.username)
    }

    /// Reads the Keychain exactly once per launch, on demand. Never called from a view body.
    func loadStoredPasswordIfNeeded() {
        guard !didLoadPassword else { return }
        didLoadPassword = true
        cachedPassword = KeychainStore.password(account: settings.username) ?? ""
        hasPassword = !cachedPassword.isEmpty
    }

    /// Loads settings and starts observing changes. Does not start the server.
    func start() {
        sync()
        // Resolve the stored password once, up front, so nothing later has to.
        loadStoredPasswordIfNeeded()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in FTPCoordinator.shared.sync() }
        }
    }

    func sync() {
        let d = UserDefaults.standard
        var s = FTPSettings()
        let port = d.integer(forKey: Key.port) // 0 when unset
        s.port = port > 0 && port <= 65535 ? UInt16(port) : 21
        s.username = d.string(forKey: Key.username) ?? "camera"
        s.lanOnly = d.object(forKey: Key.lanOnly) as? Bool ?? true
        s.overwriteExisting = d.bool(forKey: Key.overwrite)
        settings = s
    }

    // MARK: - Control

    // NOTE: both of these are read from the SwiftUI view body on every re-render, so they
    // must stay cheap and must never touch the Keychain — see `cachedPassword`.
    var canStart: Bool {
        guard let folder = receiveFolder else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue && hasPassword && !isRunning
    }

    var startBlockedReason: String? {
        if isRunning { return nil }
        if receiveFolder == nil { return "Choose a folder to receive photos into." }
        if !hasPassword { return "Set a password for the camera to use." }
        var isDirectory: ObjCBool = false
        let folder = receiveFolder!
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "The receive folder no longer exists."
        }
        return nil
    }

    func startReceiving() {
        guard !isRunning, let folder = receiveFolder else { return }
        sync()
        let server = FTPServer(settings: settings, password: password, root: folder, delegate: self)
        if let error = server.start() {
            statusMessage = error
            return
        }
        self.server = server
        statusMessage = nil
        // An ingest shouldn't be cut short by the Mac idle-sleeping.
        QueueViewModel.shared.powerController.beginKeepAwake(reason: "VeriCopy is receiving photos")
    }

    func stopReceiving() {
        server?.stop()
        server = nil
        // Only release keep-awake if a transfer isn't also relying on it.
        if !QueueViewModel.shared.queueActive {
            QueueViewModel.shared.powerController.endKeepAwake()
        }
    }

    func shutdown() {
        stopReceiving()
    }

    func clearReceivedList() {
        receivedFiles = []
        log = []
    }

    /// Hand everything just received to the normal verified-copy pipeline.
    func createJobFromReceivedFiles() {
        let urls = receivedFiles.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let queue = QueueViewModel.shared
        let job = queue.newJob(select: true)
        job.name = "Ingest \(Date().formatted(date: .abbreviated, time: .shortened))"
        job.addSources(urls)
    }

    // MARK: - FTPServerDelegate

    func ftpServerDidStart(port: UInt16) {
        isRunning = true
        listeningPort = port
        advertisedAddress = FTPServer.primaryLANAddress()
        appendLog("Receiving on port \(port)")
    }

    func ftpServerDidStop(reason: String?) {
        isRunning = false
        connectedClient = nil
        appendLog(reason ?? "Stopped receiving")
    }

    func ftpServerDidUpdateClient(_ description: String?) {
        connectedClient = description
    }

    func ftpServerDidReceive(_ file: ReceivedFile) {
        receivedFiles.insert(file, at: 0)
        if !file.verified {
            statusMessage = "⚠️ \(file.name) did not verify after landing on disk."
        }
    }

    func ftpServerDidLog(_ line: String) {
        appendLog(line)
    }

    private func appendLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(stamp)  \(line)", at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}
