import SwiftUI
import UserNotifications
import VeriCopyCore

/// Preferences window (⌘,). Notification settings persist via @AppStorage; the
/// NotificationCoordinator observes UserDefaults and re-syncs the queue automatically.
struct SettingsView: View {
    @AppStorage(NotificationCoordinator.Key.desktopEnabled) private var desktopEnabled = true
    @AppStorage(NotificationCoordinator.Key.trigger) private var triggerRaw = NotificationTrigger.eachJob.rawValue
    @AppStorage(NotificationCoordinator.Key.onlyOnFailure) private var onlyOnFailure = false
    @AppStorage(NotificationCoordinator.Key.smsEnabled) private var smsEnabled = false
    @AppStorage(NotificationCoordinator.Key.smsRecipient) private var smsRecipient = ""

    @AppStorage(PowerCoordinator.Key.keepAwakeEnabled) private var keepAwakeEnabled = true
    @AppStorage(PowerCoordinator.Key.completionAction) private var completionActionRaw = CompletionAction.nothing.rawValue
    @AppStorage(PowerCoordinator.Key.countdownSeconds) private var countdownSeconds = 30
    @AppStorage(PowerCoordinator.Key.skipAfterFailures) private var skipAfterFailures = true

    @AppStorage(FTPCoordinator.Key.port) private var ftpPort = 21
    @AppStorage(FTPCoordinator.Key.username) private var ftpUsername = "camera"
    @AppStorage(FTPCoordinator.Key.rootPath) private var ftpRootPath = ""
    @AppStorage(FTPCoordinator.Key.lanOnly) private var ftpLanOnly = true
    @AppStorage(FTPCoordinator.Key.overwrite) private var ftpOverwrite = false

    @AppStorage("metadataPolicy") private var metadataPolicyRaw = MetadataPolicy.native.rawValue

    @ObservedObject private var ftp = FTPCoordinator.shared
    @ObservedObject private var api = APICoordinator.shared

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var smsTestResult: String?
    @State private var smsTesting = false
    @State private var isHoldingAwake = false
    /// Mirrors the Keychain-backed password; loaded in `.task`, never persisted to defaults.
    @State private var ftpPassword = ""

    private var trigger: Binding<NotificationTrigger> {
        Binding(
            get: { NotificationTrigger(rawValue: triggerRaw) ?? .eachJob },
            set: { triggerRaw = $0.rawValue }
        )
    }

    private var completionActionBinding: Binding<CompletionAction> {
        Binding(
            get: { CompletionAction(rawValue: completionActionRaw) ?? .nothing },
            set: { completionActionRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView {
            notificationsForm
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            receiveForm
                .tabItem { Label("Receive", systemImage: "antenna.radiowaves.left.and.right") }
            energyForm
                .tabItem { Label("Energy", systemImage: "bolt") }
            checksumsForm
                .tabItem { Label("Checksums", systemImage: "number") }
            apiForm
                .tabItem { Label("API", systemImage: "terminal") }
        }
        .frame(width: 520, height: 520)
        .task {
            await refreshAuth()
            // Cached by the coordinator at launch — this does not hit the Keychain.
            ftpPassword = FTPCoordinator.shared.password
        }
    }

    /// Read-only status for the local HTTP API, plus the one control worth having in the UI.
    /// The allowlist itself is edited in the JSON file — it is the safety boundary, and a
    /// folder picker here would make widening it a two-click accident.
    private var apiForm: some View {
        Form {
            Section {
                Toggle("Allow local apps to control VeriCopy", isOn: Binding(
                    get: { api.isRunning },
                    set: { api.setEnabled($0) }
                ))
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(api.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(api.isRunning ? "Listening" : "Stopped")
                    }
                }
                if api.isRunning {
                    LabeledContent("Address") {
                        Text("http://127.0.0.1:\(String(api.listeningPort))")
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if let message = api.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Local API")
            } footer: {
                Text("Answers only on this Mac (127.0.0.1) — nothing on your network can reach it. "
                     + "It can start copies and report on them. It never moves, deletes or "
                     + "overwrites anything, and refuses a copy whose destination already exists.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(api.allowedRoots, id: \.self) { root in
                    HStack(spacing: 6) {
                        Image(systemName: FileManager.default.fileExists(atPath: root)
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(FileManager.default.fileExists(atPath: root)
                                             ? Color.green : Color.orange)
                        Text(root)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Reveal Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: api.configPath)])
                    }
                    Button("Reload Config") { api.reload() }
                }
            } header: {
                Text("Allowed Folders")
            } footer: {
                Text("A copy is refused unless both its source and destination sit inside one of "
                     + "these. An orange marker means that drive is not mounted right now. "
                     + "Edit the list in \(APIConfig.fileName), then press Reload Config.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var notificationsForm: some View {
        Form {
            Section("Desktop notifications") {
                Toggle("Show a notification when a copy finishes", isOn: $desktopEnabled)

                Picker("Notify:", selection: trigger) {
                    ForEach(NotificationTrigger.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .disabled(!desktopEnabled)

                Toggle("Only notify when something fails", isOn: $onlyOnFailure)
                    .disabled(!desktopEnabled)

                if authStatus == .denied {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Notifications are turned off for VeriCopy in System Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Settings") { openNotificationSettings() }
                            .buttonStyle(.link)
                    }
                }

                Button("Send test notification") {
                    Task { await NotificationCoordinator.shared.sendTestDesktop(); await refreshAuth() }
                }
            }

            Section("Text me (iMessage)") {
                Toggle("Send a text when a copy finishes", isOn: $smsEnabled)

                TextField("Phone number or Apple ID", text: $smsRecipient, prompt: Text("e.g. +15125550123 or you@icloud.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!smsEnabled)

                Text("Sends through your Messages app — no password stored. The first send asks macOS "
                     + "for permission to control Messages.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button {
                        smsTesting = true
                        smsTestResult = nil
                        Task {
                            let failure = await NotificationCoordinator.shared.sendTestSMS(to: smsRecipient)
                            smsTesting = false
                            smsTestResult = failure.map { "⚠️ \($0)" } ?? "✅ Sent — check your phone."
                        }
                    } label: {
                        Text("Send test message")
                    }
                    .disabled(smsRecipient.trimmingCharacters(in: .whitespaces).isEmpty || smsTesting)

                    if smsTesting { ProgressView().controlSize(.small) }
                    if let smsTestResult {
                        Text(smsTestResult).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var receiveForm: some View {
        Form {
            Section {
                HStack {
                    Text("Save photos to:")
                    Spacer()
                    Text(ftpRootPath.isEmpty ? "No folder chosen"
                                             : URL(fileURLWithPath: ftpRootPath).lastPathComponent)
                        .foregroundStyle(ftpRootPath.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseReceiveFolder() }
                        .disabled(ftp.isRunning)
                }

                TextField("Username", text: $ftpUsername)
                    .disabled(ftp.isRunning)
                SecureField("Password", text: $ftpPassword)
                    .disabled(ftp.isRunning)
                    .onChange(of: ftpPassword) { _, new in
                        // Writes the Keychain only when the field actually changes —
                        // never on a plain re-render.
                        FTPCoordinator.shared.setPassword(new)
                    }

                Picker("Port:", selection: $ftpPort) {
                    Text("21 (standard)").tag(21)
                    Text("2121").tag(2121)
                    Text("8021").tag(8021)
                }
                .disabled(ftp.isRunning)

                Toggle("Only accept connections from my local network", isOn: $ftpLanOnly)
                    .disabled(ftp.isRunning)
                Toggle("Overwrite files with the same name", isOn: $ftpOverwrite)
                    .disabled(ftp.isRunning)
                Text(ftpOverwrite
                     ? "⚠️ An incoming photo will replace an existing file with the same name."
                     : "An incoming photo that matches an existing name is saved alongside it "
                       + "(“DSC_0001 2.CR3”) — nothing already on disk is replaced.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Camera upload (FTP)")
            } footer: {
                Text("Photos are checksum-verified as they arrive: VeriCopy hashes the incoming "
                     + "data, then re-reads the saved file from disk to confirm it matches.")
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ftp.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 9, height: 9)
                    Text(ftp.isRunning
                         ? (ftp.connectedClient.map { "Camera connected (\($0))" } ?? "Waiting for camera…")
                         : "Not receiving")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if ftp.isRunning {
                        Button("Stop Receiving") { ftp.stopReceiving() }
                    } else {
                        Button("Start Receiving") { ftp.startReceiving() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!ftp.canStart)
                            .help(ftp.startBlockedReason ?? "")
                    }
                }

                if let reason = ftp.startBlockedReason, !ftp.isRunning {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }

                if ftp.isRunning {
                    // Exactly what to type into the camera.
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        GridRow {
                            Text("Address").foregroundStyle(.secondary)
                            Text(ftp.advertisedAddress ?? "—").textSelection(.enabled).bold()
                        }
                        GridRow {
                            Text("Port").foregroundStyle(.secondary)
                            Text("\(ftp.listeningPort)").textSelection(.enabled).bold()
                        }
                        GridRow {
                            Text("Username").foregroundStyle(.secondary)
                            Text(ftpUsername).textSelection(.enabled).bold()
                        }
                        GridRow {
                            Text("Mode").foregroundStyle(.secondary)
                            Text("Passive or Active — both work").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }

                if let status = ftp.statusMessage {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Session")
            }

            if !ftp.receivedFiles.isEmpty {
                Section {
                    ForEach(ftp.receivedFiles.prefix(8)) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(file.verified ? .green : .yellow)
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(byteText(file.size))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    HStack {
                        Button("Create job from received files") {
                            ftp.createJobFromReceivedFiles()
                        }
                        Spacer()
                        Button("Clear") { ftp.clearReceivedList() }
                    }
                } header: {
                    Text("Received (\(ftp.receivedFiles.count))")
                } footer: {
                    Text("“Create job” queues these files for a verified copy to another "
                         + "drive — an ingest-then-backup in one pass.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseReceiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder your camera should upload into"
        if panel.runModal() == .OK, let url = panel.url {
            ftpRootPath = url.standardizedFileURL.path
        }
    }

    private var energyForm: some View {
        Form {
            Section {
                Toggle("Keep the Mac awake while transferring", isOn: $keepAwakeEnabled)
                Text("Stops the Mac from going to sleep mid-transfer. The display can still "
                     + "turn off — only system sleep is held.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isHoldingAwake {
                    Label("Currently holding the Mac awake.", systemImage: "bolt.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("During transfers")
            }

            Section {
                Picker("When the queue finishes:", selection: completionActionBinding) {
                    ForEach(CompletionAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                Text("The default for new jobs. Each job can override it with its own "
                     + "“When done” setting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Wait before acting:", selection: $countdownSeconds) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }

                Toggle("Never sleep or quit if something failed", isOn: $skipAfterFailures)

                Button("Show a 10-second test countdown") {
                    PowerCoordinator.shared.showTestCountdown()
                }

                Text("If the screen has turned off, VeriCopy wakes it so you can cancel. "
                     + "One exception: if your Mac is locked, the countdown sits behind the "
                     + "lock screen and will complete on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("When finished")
            }
        }
        .formStyle(.grouped)
        .task { isHoldingAwake = PowerCoordinator.shared.isHoldingAwake }
    }

    private var checksumsForm: some View {
        Form {
            Section {
                ForEach(HashAlgorithm.allCases) { algo in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(algo.rawValue).fontWeight(.semibold)
                            Text(algo.kindLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if algo.isRecommended {
                                Text("Default")
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(algo.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Checksum algorithms")
            } footer: {
                Text("Pick an algorithm per job from the “Checksum” menu at the top of each job — "
                     + "verification and the saved manifest use whichever you choose.")
            }

            Section {
                Picker("Copy alongside each file:", selection: metadataPolicyBinding) {
                    ForEach(MetadataPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Text(currentMetadataPolicy.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Tags, dates and permissions")
            }
        }
        .formStyle(.grouped)
    }

    private var currentMetadataPolicy: MetadataPolicy {
        MetadataPolicy(rawValue: metadataPolicyRaw) ?? .native
    }

    private var metadataPolicyBinding: Binding<MetadataPolicy> {
        Binding(get: { currentMetadataPolicy },
                set: { metadataPolicyRaw = $0.rawValue })
    }

    private func refreshAuth() async {
        authStatus = await LocalNotificationChannel.currentAuthorizationStatus()
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
