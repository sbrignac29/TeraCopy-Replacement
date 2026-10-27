import SwiftUI
import UniformTypeIdentifiers
import VeriCopyCore

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct ContentView: View {
    @EnvironmentObject var queue: QueueViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let job = queue.selectedJob {
                JobDetailView(job: job)
                    .id(job.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No job selected")
                        .foregroundStyle(.secondary)
                    Button("New Job") { queue.newJob() }
                }
            }
        }
        .frame(minWidth: 940, minHeight: 500)
        .sheet(item: $queue.conflict) { prompt in
            ConflictSheet(prompt: prompt)
                .environmentObject(queue)
        }
        .alert("VeriCopy", isPresented: Binding(
            get: { queue.alertMessage != nil },
            set: { if !$0 { queue.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queue.alertMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var queue: QueueViewModel
    @State private var editingJobID: UUID?

    var body: some View {
        List(selection: $queue.selectedJobID) {
            Section("Queue") {
                ForEach(queue.jobs) { job in
                    JobRow(job: job, isEditing: Binding(
                        get: { editingJobID == job.id },
                        set: { editingJobID = $0 ? job.id : nil }
                    ))
                        .tag(job.id)
                        .contextMenu {
                            Button("Rename") {
                                queue.selectedJobID = job.id
                                editingJobID = job.id
                            }
                            Button("Remove Job", role: .destructive) {
                                queue.removeJob(job)
                            }
                            .disabled(job.isActive)
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                HStack {
                    Button {
                        queue.newJob()
                    } label: {
                        Label("New Job", systemImage: "plus")
                    }
                    Spacer()
                    if queue.queueActive {
                        Button(role: .destructive) {
                            queue.stopQueue()
                        } label: {
                            Label("Stop Queue", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            queue.startQueue()
                        } label: {
                            Label("Start Queue", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!queue.hasReadyJobs)
                        .help(queue.hasReadyJobs
                              ? "Run every ready job, top to bottom"
                              : "No job is ready — each job needs files and a destination")
                    }
                }
                if queue.hasFinishedJobs && !queue.queueActive {
                    Button("Clear Finished Jobs") {
                        queue.removeFinishedJobs()
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: TransferJob
    @Binding var isEditing: Bool
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            stateIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Job name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFieldFocused)
                        .onSubmit { commit() }
                        .onExitCommand { isEditing = false } // Escape discards
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commit() } // clicking away keeps the edit
                        }
                } else {
                    Text(job.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Double-click the name to rename (also available via right-click ▸ Rename).
                        .onTapGesture(count: 2) { isEditing = true }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.isActive {
                    ProgressView(value: job.progressFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .onChange(of: isEditing) { _, editing in
            if editing {
                draftName = job.name
                nameFieldFocused = true
            }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { job.name = trimmed }
        isEditing = false
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .draft:
            Image(systemName: job.isReady ? "circle" : "circle.dashed")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .finished:
            if let summary = job.summary {
                if summary.failed > 0 || summary.fatalError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                } else if summary.cancelled {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if job.items.isEmpty {
            parts.append("empty")
        } else {
            parts.append("\(job.items.count) file\(job.items.count == 1 ? "" : "s") · \(byteText(job.totalBytes))")
        }
        if let destination = job.destination {
            parts.append("→ \(destination.lastPathComponent)")
        }
        if job.state == .finished, let summary = job.summary {
            if summary.cancelled {
                parts.append("cancelled")
            } else if summary.failed > 0 {
                parts.append("\(summary.failed) failed")
            } else {
                parts.append("done")
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Job detail

enum DetailViewMode: String {
    case files
    case stats
}

struct JobDetailView: View {
    @ObservedObject var job: TransferJob
    @EnvironmentObject var queue: QueueViewModel
    @State private var dropTargeted = false
    @AppStorage("autoScrollEnabled") private var autoScroll = true
    @AppStorage("detailViewMode") private var viewModeRaw = DetailViewMode.files.rawValue
    @State private var lastAutoScroll = Date.distantPast

    private var viewMode: DetailViewMode {
        DetailViewMode(rawValue: viewModeRaw) ?? .files
    }

    var body: some View {
        // Bind the whole detail to the pane's actual height. NavigationSplitView otherwise lets
        // the (greedy) stats view grow the content taller than the window, which pushed the
        // fixed footer — the Copy button — off the bottom. With an explicit height, the middle
        // region is forced to shrink and clip its overflow, so the header and footer stay put.
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Divider()
                queueArea
                    .frame(maxHeight: .infinity)
                    .clipped()
                Divider()
                footer
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .navigationTitle(job.name)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker("", selection: $job.mode) {
                    ForEach(TransferMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!job.isEditable)

                Picker("Checksum:", selection: $job.algorithm) {
                    ForEach(HashAlgorithm.allCases) { algorithm in
                        Text(algorithm.rawValue).tag(algorithm)
                    }
                }
                .frame(width: 170)
                .disabled(!job.isEditable)

                Picker("Verify:", selection: $job.verification) {
                    ForEach(VerificationPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .frame(width: 170)
                .disabled(!job.isEditable || job.mode == .verify)
                .opacity(job.mode == .verify ? 0.4 : 1)
                .help("Each file: read every file back and check it right after it copies. At end: copy everything first, then run one verification pass (for moves, sources are deleted only after they verify). Never: skip the read-back check entirely.")

                Spacer()

                if job.scansInFlight > 0 {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    job.promptAddSources()
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                .disabled(!job.isEditable)
            }

            HStack(spacing: 8) {
                Text(job.mode == .verify ? "Verify against:" : "Destination:")
                    .foregroundStyle(.secondary)

                if let destination = job.destination {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: destination.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(destination.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination.path)
                } else {
                    Text("No folder selected")
                        .italic()
                        .foregroundStyle(.tertiary)
                }

                Button("Choose…") {
                    job.promptChooseDestination()
                }
                .disabled(!job.isEditable)

                Spacer()

                if !job.items.isEmpty {
                    Text("\(job.items.count) file\(job.items.count == 1 ? "" : "s") · \(byteText(job.totalBytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker("When done:", selection: $job.completionAction) {
                    ForEach(CompletionAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .frame(width: 190)
                .disabled(!job.isEditable)
                .help("What happens after the whole queue finishes. If several jobs run, the "
                      + "last one's choice is used. Skipped if anything failed or you stopped the queue.")

                Picker("", selection: $viewModeRaw) {
                    Image(systemName: "list.bullet").tag(DetailViewMode.files.rawValue)
                        .help("File list")
                    Image(systemName: "chart.xyaxis.line").tag(DetailViewMode.stats.rawValue)
                        .help("Counters and speed graph")
                }
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help("Switch between the file list and the live statistics view")
            }
        }
        .padding(12)
    }

    // MARK: File table

    private var queueArea: some View {
        ZStack {
            if job.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Drag files or folders here")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("or click Add… to choose what to \(job.mode.rawValue.lowercased())")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            } else if viewMode == .stats {
                JobStatsView(job: job)
            } else {
                fileTable
            }

            if dropTargeted && job.isEditable {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Size").frame(width: 80, alignment: .trailing)
                Text("Progress").frame(width: 120, alignment: .leading)
                Text("Status").frame(width: 200, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(job.items) { item in
                        FileRow(item: item)
                            .id(item.id)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowBackground(item.id == job.currentItemID && job.isActive
                                               ? Color.accentColor.opacity(0.09)
                                               : nil)
                    }
                }
                .listStyle(.plain)
                .onChange(of: job.currentItemID) { _, newID in
                    autoScrollIfNeeded(to: newID, proxy: proxy)
                }
                .onChange(of: job.progressDone) { _, _ in
                    // Trailing coverage: keeps following during a long single-file copy
                    // whose earlier scroll was throttled away.
                    autoScrollIfNeeded(to: job.currentItemID, proxy: proxy)
                }
                .onChange(of: autoScroll) { _, enabled in
                    if enabled {
                        autoScrollIfNeeded(to: job.currentItemID, proxy: proxy, force: true)
                    }
                }
            }
        }
    }

    private func autoScrollIfNeeded(to id: UUID?, proxy: ScrollViewProxy, force: Bool = false) {
        guard autoScroll, job.isActive, let id else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastAutoScroll) > 0.15 else { return }
        lastAutoScroll = now
        proxy.scrollTo(id, anchor: .center)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            ProgressView(value: job.progressFraction)
                .progressViewStyle(.linear)

            HStack(spacing: 14) {
                statsText
                Spacer()
                if viewMode == .files {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)
                        .help("Keep the file currently being copied or verified visible in the list")
                }
                footerButtons
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statsText: some View {
        switch job.state {
        case .draft:
            Text(job.readinessNote ?? "Ready — start this job or the whole queue")
                .foregroundStyle(.secondary)
        case .running, .paused:
            HStack(spacing: 10) {
                if job.isVerificationPhase {
                    Label("Verification pass", systemImage: "checkmark.shield")
                        .foregroundStyle(.orange)
                }
                Text("\(byteText(job.progressDone)) of \(byteText(job.progressTotal))")
                if job.state == .paused {
                    Text("Paused").foregroundStyle(.orange).bold()
                } else if job.speedBytesPerSecond > 1 {
                    Text("\(byteText(Int64(job.speedBytesPerSecond)))/s")
                    if let eta = job.etaText {
                        Text("about \(eta) left")
                    }
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
        case .finished:
            if let summary = job.summary {
                summaryText(summary)
            }
        }
    }

    private func summaryText(_ summary: TransferSummary) -> some View {
        let elapsed = DateComponentsFormatter.transferElapsed.string(from: summary.elapsed) ?? "\(Int(summary.elapsed))s"
        var parts: [String] = []
        if summary.cancelled { parts.append("Cancelled —") }
        parts.append("\(summary.succeeded) completed")
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.failed > 0 { parts.append("\(summary.failed) FAILED") }
        parts.append("in \(elapsed)")

        return HStack(spacing: 6) {
            Image(systemName: summary.failed > 0 || summary.fatalError != nil
                  ? "exclamationmark.triangle.fill"
                  : (summary.cancelled ? "minus.circle.fill" : "checkmark.seal.fill"))
                .foregroundStyle(summary.failed > 0 || summary.fatalError != nil
                                 ? .yellow
                                 : (summary.cancelled ? Color.secondary : .green))
            Text(parts.joined(separator: " · "))
                .foregroundStyle(summary.failed > 0 ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch job.state {
        case .draft:
            Button("Clear") { job.clearItems() }
                .disabled(job.items.isEmpty)
            Button {
                queue.startQueue(startingWith: job, only: true)
            } label: {
                Label(startTitle, systemImage: startIcon)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!job.isReady || queue.queueActive)
            .help(job.readinessNote ?? (queue.queueActive ? "Queue is running" : "Run this job now"))
        case .running:
            Button {
                queue.pauseCurrent()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            cancelButton
        case .paused:
            Button {
                queue.resumeCurrent()
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            cancelButton
        case .finished:
            if job.canExportChecksums {
                Button("Save Checksums…") { job.exportChecksums() }
            }
            Button {
                queue.runAgain(job)
            } label: {
                Label("Run Again", systemImage: "arrow.counterclockwise")
            }
            .disabled(queue.queueActive)
        }
    }

    private var startTitle: String {
        switch job.mode {
        case .copy: return "Copy"
        case .move: return "Move"
        case .verify: return "Verify"
        }
    }

    private var startIcon: String {
        switch job.mode {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .verify: return "checkmark.shield"
        }
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            queue.cancelCurrentJob()
        } label: {
            Label("Cancel Job", systemImage: "xmark")
        }
    }

    // MARK: Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard job.isEditable else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url {
                    DispatchQueue.main.async {
                        QueueViewModel.shared.handleDroppedURLs([url])
                    }
                }
            }
        }
        return true
    }
}

// MARK: - File row

private struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.sourceURL.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.sourceURL.path)
                if let renamed = item.destinationName {
                    Text("→ \(renamed)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.isSymlink ? "—" : byteText(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            progressCell
                .frame(width: 120, alignment: .leading)

            StatusCell(item: item)
                .frame(width: 200, alignment: .leading)
        }
    }

    @ViewBuilder
    private var progressCell: some View {
        if item.status == .copying || item.status == .verifying {
            ProgressView(value: item.size > 0 ? Double(item.bytesCopied) / Double(item.size) : 1)
                .progressViewStyle(.linear)
        } else if item.status == .copied {
            ProgressView(value: 1.0)
                .progressViewStyle(.linear)
                .tint(.blue)
        } else if item.status == .done || item.status == .doneNoVerify {
            ProgressView(value: 1.0)
                .progressViewStyle(.linear)
                .tint(.green)
        } else {
            ProgressView(value: 0)
                .progressViewStyle(.linear)
                .opacity(0.35)
        }
    }
}

// MARK: - Status cell

private struct StatusCell: View {
    let item: FileItem

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
        }
        .help(item.message ?? text)
    }

    private var icon: String {
        switch item.status {
        case .pending: return "clock"
        case .copying: return "arrow.forward.circle"
        case .verifying: return "magnifyingglass.circle"
        case .copied: return "clock.badge.checkmark"
        case .done: return "checkmark.seal.fill"
        case .doneNoVerify: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .pending: return .secondary
        case .copying: return .blue
        case .verifying: return .orange
        case .copied: return .blue
        case .done, .doneNoVerify: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    private var text: String {
        switch item.status {
        case .pending: return "Pending"
        case .copying: return "Copying…"
        case .verifying: return "Verifying…"
        case .copied: return item.message ?? "Copied — verify queued"
        case .done: return item.message ?? "Verified"
        case .doneNoVerify: return item.message ?? "Done"
        case .skipped: return item.message ?? "Skipped"
        case .failed: return item.message ?? "Failed"
        }
    }
}

// MARK: - Conflict sheet

private struct ConflictSheet: View {
    let prompt: QueueViewModel.ConflictPrompt
    @EnvironmentObject var queue: QueueViewModel
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: prompt.existingURL.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("“\(prompt.item.fileName)” already exists")
                        .font(.headline)
                    Text("\(prompt.jobName): the destination folder already contains an item with this name.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Existing:").foregroundStyle(.secondary)
                    Text(describe(url: prompt.existingURL))
                }
                GridRow {
                    Text("Incoming:").foregroundStyle(.secondary)
                    Text(describe(url: prompt.item.sourceURL))
                }
            }
            .font(.callout)

            Toggle("Apply to all remaining conflicts in this job", isOn: $applyToAll)

            HStack {
                Spacer()
                Button("Skip") { queue.answerConflict(.skip, applyToAll: applyToAll) }
                    .keyboardShortcut(.cancelAction)
                Button("Keep Both") { queue.answerConflict(.keepBoth, applyToAll: applyToAll) }
                Button("Overwrite") { queue.answerConflict(.overwrite, applyToAll: applyToAll) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func describe(url: URL) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return "—" }
        var parts: [String] = []
        if let size = attrs[.size] as? Int64 {
            parts.append(byteText(size))
        }
        if let date = attrs[.modificationDate] as? Date {
            parts.append("modified " + date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

extension DateComponentsFormatter {
    static let transferElapsed: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
