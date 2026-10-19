// Headless test of the job-queue layer (QueueViewModel + TransferJob), compiled
// against the real app sources by Scripts/run_queue_test.sh. Verifies that queued
// jobs run strictly one at a time in list order, finish with retained per-file
// verified results, and that the queue terminates cleanly.

import Foundation
import VeriCopyCore

/// Captures every notification the queue dispatches, so the test can assert the
/// completion hooks fire at the right moments with the right content.
final class MockChannel: NotificationChannel, @unchecked Sendable {
    let kind: NotificationChannelKind
    private let lock = NSLock()
    private var _received: [NotificationContent] = []
    var received: [NotificationContent] { lock.withLock { _received } }
    init(kind: NotificationChannelKind) { self.kind = kind }
    func deliver(_ content: NotificationContent) async {
        lock.withLock { _received.append(content) }
    }
}

/// Records power effects instead of performing them. This is what makes it safe to test the
/// end-of-run state machine: `sleepSystem()` and `quitApp()` only set flags, so even a
/// regression in the policy logic cannot sleep the test machine or kill the test process.
@MainActor
final class RecordingPowerController: PowerController {
    var events: [String] = []
    var keepAwakeDepth = 0
    var slept = false
    var quit = false

    func beginKeepAwake(reason: String) {
        guard keepAwakeDepth == 0 else { return } // real controller is idempotent too
        keepAwakeDepth += 1
        events.append("awake+")
    }
    func endKeepAwake() {
        guard keepAwakeDepth > 0 else { return }
        keepAwakeDepth -= 1
        events.append("awake-")
    }
    func declareUserActivity() { events.append("activity") }
    func sleepSystem() { slept = true; events.append("sleep") }
    func quitApp() { quit = true; events.append("quit") }
}

@main
struct QueueTest {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String, detail: String = "") {
        if condition {
            print("  PASS  \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() async {
        print("== Queue sequencing test ==")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vericopy-queuetest-\(UUID().uuidString)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func randomData(_ count: Int) -> Data {
            var data = Data(count: count)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
            return data
        }

        // Build three jobs, each copying one 48 MB file to its own destination.
        var jobIDs: [UUID] = []
        var destinations: [URL] = []
        var sources: [URL] = []

        await MainActor.run {
            let queue = QueueViewModel.shared
            if let auto = queue.jobs.first, auto.items.isEmpty {
                queue.removeJob(auto) // discard the auto-created empty draft
            }
            for index in 1...3 {
                let sourceDir = base.appendingPathComponent("src\(index)")
                let destDir = base.appendingPathComponent("dst\(index)")
                try! fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
                try! fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                let file = sourceDir.appendingPathComponent("payload\(index).bin")
                try! randomData(48 * 1024 * 1024).write(to: file)

                let job = queue.newJob()
                job.destination = destDir
                job.verification = .perFile // pin: the I/O-counter checks below assume a verify pass
                job.addSources([file])
                jobIDs.append(job.id)
                destinations.append(destDir)
                sources.append(file)
            }
        }

        // Wait for the async source scans.
        var ticks = 0
        while ticks < 500 {
            let ready = await MainActor.run { QueueViewModel.shared.jobs.allSatisfy(\.isReady) }
            if ready { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            ticks += 1
        }
        let allReady = await MainActor.run { QueueViewModel.shared.jobs.allSatisfy(\.isReady) }
        check(allReady, "all three jobs became ready after scanning")

        // Inject a mock notification channel + default settings (desktop on, per-job trigger).
        let mock = MockChannel(kind: .desktop)
        let power = RecordingPowerController()
        await MainActor.run {
            let queue = QueueViewModel.shared
            queue.notificationChannels = [mock]
            queue.notificationSettings = NotificationSettings(desktopEnabled: true, trigger: .eachJob)
            // Arm "sleep when finished" with a 1-second countdown so the test exercises the
            // whole path quickly. RecordingPowerController only sets a flag.
            queue.powerController = power
            queue.powerSettings = PowerSettings(defaultCompletionAction: .sleep, countdownSeconds: 1)
            for job in queue.jobs { job.completionAction = .sleep }
        }

        // Start the queue and watch it: never more than one job running,
        // and observed activations must respect list order.
        await MainActor.run { QueueViewModel.shared.startQueue() }

        var observedOrder: [UUID] = []
        var sawConcurrent = false
        // Track, per job, whether its "copied" count ever DROPPED between samples. With verify-at-end,
        // a file moving copied→verifying must not un-count it — the copied number should be monotonic.
        var maxCopiedSeen: [UUID: Int] = [:]
        var sawCopiedRegression = false
        var sawVerifyingActivity = false
        var waited = 0
        while waited < 6000 { // 60 s ceiling
            let snapshot = await MainActor.run { () -> (Bool, [UUID], [(UUID, Int, Bool)]) in
                let queue = QueueViewModel.shared
                let perJob = queue.jobs.map { job -> (UUID, Int, Bool) in
                    let counts = job.statusCounts
                    let verifying = job.items.contains { $0.status == .verifying }
                    return (job.id, counts.copied, verifying)
                }
                return (queue.queueActive, queue.jobs.filter(\.isActive).map(\.id), perJob)
            }
            let (active, running, perJob) = snapshot
            if running.count > 1 { sawConcurrent = true }
            if let current = running.first, observedOrder.last != current {
                observedOrder.append(current)
            }
            for (id, copied, verifying) in perJob {
                if verifying { sawVerifyingActivity = true }
                let prevMax = maxCopiedSeen[id] ?? 0
                if copied < prevMax { sawCopiedRegression = true } // the reported glitch
                maxCopiedSeen[id] = max(prevMax, copied)
            }
            if !active { break }
            try? await Task.sleep(nanoseconds: 8_000_000)
            waited += 1
        }

        check(waited < 6000, "queue finished within the time limit")
        check(!sawConcurrent, "never more than one job running at a time")
        check(sawVerifyingActivity, "observed the verification phase while sampling (guards the check below)")
        check(!sawCopiedRegression, "copied count never drops during verification (no glitch)")

        let orderIndexes = observedOrder.compactMap { jobIDs.firstIndex(of: $0) }
        check(orderIndexes == orderIndexes.sorted() && !orderIndexes.isEmpty,
              "jobs started in queue order", detail: "\(orderIndexes)")

        // Every job finished, kept its summary, and kept per-file verified results.
        let states = await MainActor.run { QueueViewModel.shared.jobs.map(\.state) }
        check(states.allSatisfy { $0 == .finished }, "all jobs marked finished", detail: "\(states)")

        let results = await MainActor.run { () -> [(ok: Int, failed: Int, statuses: [ItemStatus], messages: [String]) ] in
            QueueViewModel.shared.jobs.map { job in
                (job.summary?.succeeded ?? -1,
                 job.summary?.failed ?? -1,
                 job.items.map(\.status),
                 job.items.compactMap(\.message))
            }
        }
        check(results.allSatisfy { $0.ok == 1 && $0.failed == 0 },
              "each job reports 1 succeeded, 0 failed",
              detail: "\(results.map { ($0.ok, $0.failed) })")
        check(results.allSatisfy { $0.statuses.allSatisfy { $0 == .done } },
              "finished jobs still show every file in verified state")
        check(results.allSatisfy { $0.messages.allSatisfy { $0.contains("verified") } },
              "per-file 'verified' labels retained after completion")

        for (index, file) in sources.enumerated() {
            let copied = destinations[index].appendingPathComponent(file.lastPathComponent)
            check(fm.contentsEqual(atPath: file.path, andPath: copied.path),
                  "job \(index + 1) output byte-identical")
        }

        // Read/write accounting for the stats view: each job copies 48 MB (read+write)
        // then verifies it (read-back), so read = 2×48 MB and write = 48 MB, exactly.
        let fileBytes: Int64 = 48 * 1024 * 1024
        let ioTotals = await MainActor.run {
            QueueViewModel.shared.jobs.map { ($0.readBytesTotal, $0.writeBytesTotal) }
        }
        check(ioTotals.allSatisfy { $0.0 == 2 * fileBytes },
              "read counter = copy read + verify read-back (2× file size)",
              detail: "\(ioTotals.map(\.0)) expected \(2 * fileBytes)")
        check(ioTotals.allSatisfy { $0.1 == fileBytes },
              "write counter = exactly the file size",
              detail: "\(ioTotals.map(\.1)) expected \(fileBytes)")

        let countsOK = await MainActor.run {
            QueueViewModel.shared.jobs.allSatisfy { job in
                let counts = job.statusCounts
                return counts.copied == 1 && counts.verified == 1 && counts.failed == 0
                    && counts.waiting == 0 && counts.total == 1
            }
        }
        check(countsOK, "status counts report 1 copied + 1 verified, none waiting/failed")

        // Notification wiring: 3 per-job notifications + 1 queue rollup (fires because >1 job ran).
        let notes = mock.received
        let jobNotes = notes.filter { $0.title.hasPrefix("Job") && $0.title.contains("complete") }
        let queueNotes = notes.filter { $0.title == "Queue complete" }
        check(jobNotes.count == 3, "one desktop notification fired per finished job",
              detail: "got \(jobNotes.count) of \(notes.map(\.title))")
        check(queueNotes.count == 1, "one queue-complete rollup notification fired",
              detail: "got \(queueNotes.count) of \(notes.map(\.title))")
        check(queueNotes.first?.body.contains("3 jobs") == true, "queue rollup counts all jobs",
              detail: queueNotes.first?.body ?? "nil")
        check(notes.allSatisfy { !$0.isFailure }, "clean run produced no failure-flagged notifications")

        // Power wiring. The keep-awake hold must be balanced across the whole run: an
        // unbalanced depth means a leaked system-wide assertion.
        let (depth, events, sleptDuringRun) = await MainActor.run {
            (power.keepAwakeDepth, power.events, power.slept)
        }
        check(events.contains("awake+"), "keep-awake was taken when the queue started",
              detail: "\(events)")
        check(depth == 0, "keep-awake released — balanced across the run", detail: "depth=\(depth)")
        check(!sleptDuringRun, "did not sleep before the countdown elapsed")

        // The countdown was armed; wait for it to elapse (1 s) and confirm it fired.
        var countdownWaits = 0
        while countdownWaits < 500 {
            let pending = await MainActor.run { QueueViewModel.shared.pendingCompletion != nil }
            if !pending, await MainActor.run(body: { power.slept }) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            countdownWaits += 1
        }
        let (slept, quit) = await MainActor.run { (power.slept, power.quit) }
        check(slept, "clean run slept the Mac after the countdown elapsed")
        check(!quit, "sleep action did not quit the app")

        // Second scenario: a stopped queue must never sleep.
        let power2 = RecordingPowerController()
        await MainActor.run {
            let queue = QueueViewModel.shared
            queue.powerController = power2
            queue.powerSettings = PowerSettings(defaultCompletionAction: .sleep, countdownSeconds: 1)
            for job in queue.jobs {
                job.resetForRun()
                job.state = .draft
                job.completionAction = .sleep
            }
            queue.startQueue()
        }
        try? await Task.sleep(nanoseconds: 120_000_000) // let the first job get going
        await MainActor.run { QueueViewModel.shared.stopQueue() }

        var stopWaits = 0
        while stopWaits < 600 {
            if await MainActor.run(body: { !QueueViewModel.shared.queueActive }) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
            stopWaits += 1
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000) // longer than the countdown would be
        let (slept2, pending2, depth2) = await MainActor.run {
            (power2.slept, QueueViewModel.shared.pendingCompletion != nil, power2.keepAwakeDepth)
        }
        check(!slept2, "STOPPED queue never sleeps the Mac")
        check(!pending2, "stopped queue arms no countdown")
        check(depth2 == 0, "keep-awake released after a stopped queue too", detail: "depth=\(depth2)")

        // Batched delivery must be indistinguishable from one-at-a-time delivery.
        //
        // The engine's pump hands a whole pass to `applyUpdates(_:)` in one call, because
        // delivering per file cost a display frame apiece in the app. That is only a safe
        // trade if the model cannot tell the difference: the per-file statuses, the live
        // counts, and the read/write byte totals the stats graph is drawn from all have to
        // come out identical. Those totals are derived from the SEQUENCE of phase
        // transitions, so this is the assertion that actually protects the graph.
        func buildJob(_ count: Int) async -> TransferJob {
            await MainActor.run {
                let job = TransferJob(number: 998)
                job.items = (0..<count).map { i in
                    FileItem(sourceURL: URL(fileURLWithPath: "/tmp/eq\(i)"),
                             relativePath: "eq\(i).bin", size: 4096, isSymlink: false)
                }
                return job
            }
        }

        // The update sequence the engine really produces per file: partial copy, full copy,
        // read-back, then the finished state.
        func updateSequence(for job: TransferJob, count: Int) async -> [ItemUpdate] {
            await MainActor.run {
                var sequence: [ItemUpdate] = []
                for index in 0..<count {
                    let base = job.items[index]
                    for (status, bytes) in [(ItemStatus.copying, Int64(2048)),
                                            (.copying, 4096),
                                            (.verifying, 4096),
                                            (.done, 4096)] {
                        var item = base
                        item.status = status
                        item.bytesCopied = bytes
                        item.checksum = "deadbeef"
                        sequence.append(ItemUpdate(index: index, item: item))
                    }
                }
                return sequence
            }
        }

        let eqCount = 300
        let oneAtATime = await buildJob(eqCount)
        let asBatch = await buildJob(eqCount)
        let sequence = await updateSequence(for: oneAtATime, count: eqCount)
        // Same positions, same statuses — only the shape of the hand-off differs.
        let batchSequence = await updateSequence(for: asBatch, count: eqCount)

        await MainActor.run {
            for update in sequence { oneAtATime.updateItem(update.item, at: update.index) }
            asBatch.applyUpdates(batchSequence)
        }

        let (a, b) = await MainActor.run {
            (( counts: oneAtATime.statusCounts, read: oneAtATime.readBytesTotal,
               write: oneAtATime.writeBytesTotal, statuses: oneAtATime.items.map(\.status),
               bytes: oneAtATime.items.map(\.bytesCopied), current: oneAtATime.currentItemID,
               tally: oneAtATime.apiTally ),
             ( counts: asBatch.statusCounts, read: asBatch.readBytesTotal,
               write: asBatch.writeBytesTotal, statuses: asBatch.items.map(\.status),
               bytes: asBatch.items.map(\.bytesCopied), current: asBatch.currentItemID,
               tally: asBatch.apiTally ))
        }

        check(a.statuses == b.statuses && a.bytes == b.bytes,
              "batched delivery leaves the same per-file state as one-at-a-time")
        check(a.counts.copied == b.counts.copied && a.counts.verified == b.counts.verified
              && a.counts.failed == b.counts.failed && a.counts.waiting == b.counts.waiting
              && a.counts.active == b.counts.active && a.counts.skipped == b.counts.skipped,
              "batched delivery leaves the same live counters",
              detail: "one-at-a-time copied/verified/active \(a.counts.copied)/\(a.counts.verified)/"
                    + "\(a.counts.active) vs batched \(b.counts.copied)/\(b.counts.verified)/\(b.counts.active)")
        check(a.read == b.read && a.write == b.write,
              "batched delivery credits the same read/write bytes (stats graph)",
              detail: "one-at-a-time r/w \(a.read)/\(a.write) vs batched \(b.read)/\(b.write)")
        check(a.read == Int64(eqCount) * 4096 * 2 && a.write == Int64(eqCount) * 4096,
              "read/write totals match the work actually described",
              detail: "read \(a.read) (expected \(Int64(eqCount) * 4096 * 2)), "
                    + "write \(a.write) (expected \(Int64(eqCount) * 4096))")
        check(a.tally.unverified == b.tally.unverified && a.tally.verifying == b.tally.verifying,
              "batched delivery leaves the same API tally")
        check(b.current == batchSequence.last?.item.id,
              "a batch leaves `currentItemID` on the last file it touched (auto-scroll target)")

        // Performance regression guard.
        //
        // Per-file update cost must NOT grow with the number of files in the job. It used to:
        // `items` was a @Published array, so every element write copied the whole thing, making
        // a big job of small files O(n²) and collapsing throughput to a few KB/s. This asserts
        // the cost stays flat between a small and a large job.
        func measureUpdateCost(itemCount: Int, updates: Int) async -> Double {
            let job = await MainActor.run { () -> TransferJob in
                let job = TransferJob(number: 999)
                job.items = (0..<itemCount).map { i in
                    FileItem(sourceURL: URL(fileURLWithPath: "/tmp/p\(i)"),
                             relativePath: "p\(i).xmp", size: 8192, isSymlink: false)
                }
                return job
            }
            return await MainActor.run { () -> Double in
                let start = Date()
                for i in 0..<updates {
                    var item = job.items[i % itemCount]
                    item.status = .done
                    item.bytesCopied = 8192
                    job.updateItem(item, at: i % itemCount)
                }
                return Date().timeIntervalSince(start) / Double(updates) * 1000 // ms per update
            }
        }

        let smallJobCost = await measureUpdateCost(itemCount: 500, updates: 20_000)
        let largeJobCost = await measureUpdateCost(itemCount: 20_000, updates: 20_000)
        let ratio = largeJobCost / max(smallJobCost, 0.0000001)
        check(ratio < 8,
              "per-file update cost does not scale with job size (no O(n²) regression)",
              detail: String(format: "500 items: %.5f ms, 20000 items: %.5f ms, ratio %.1fx",
                             smallJobCost, largeJobCost, ratio))
        check(largeJobCost < 0.05,
              "per-file update stays fast on a 20,000-file job",
              detail: String(format: "%.5f ms/update", largeJobCost))

        print("")
        print(failures == 0 ? "ALL QUEUE TESTS PASSED" : "\(failures) QUEUE TEST(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
