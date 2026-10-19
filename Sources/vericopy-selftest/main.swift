import Foundation
import VeriCopyCore

// Headless engine test suite. Exercises copy, verification, corruption detection,
// conflict policies, move (same- and cross-volume paths), pause and cancel.
// Exits 0 on success, 1 on any failure.

var failures = 0

func check(_ condition: Bool, _ name: String, detail: String = "") {
    if condition {
        print("  PASS  \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

final class TestDelegate: TransferEngineDelegate {
    var resolution = ConflictResolution(choice: .skip, applyToAll: false)
    var conflictCount = 0
    var sawCopying = false

    func engineDidUpdate(item: FileItem, at index: Int) async {
        if item.status == .copying { sawCopying = true }
    }
    func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
    func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
        conflictCount += 1
        return resolution
    }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("vericopy-selftest-\(UUID().uuidString)")
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }

func makeTempDir(_ name: String) throws -> URL {
    let url = base.appendingPathComponent(name)
    try? fm.removeItem(at: url)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        arc4random_buf(buffer.baseAddress, count)
    }
    return data
}

func buildSourceTree(in dir: URL) throws {
    let root = dir.appendingPathComponent("tree")
    try fm.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
    try "hello vericopy\n".data(using: .utf8)!.write(to: root.appendingPathComponent("file1.txt"))
    try randomData(9 * 1024 * 1024 + 137).write(to: root.appendingPathComponent("nested/big.bin"))
    try Data().write(to: root.appendingPathComponent("empty.txt"))
    try "émoji 🚀 data".data(using: .utf8)!.write(to: root.appendingPathComponent("nested/deeper/wéird nàme 🚀.txt"))
    try fm.createSymbolicLink(
        atPath: root.appendingPathComponent("link-to-file1").path,
        withDestinationPath: "file1.txt"
    )
}

func statuses(_ items: [FileItem]) -> [String: ItemStatus] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0.status) })
}

// ============================================================
print("== Known-answer hash tests ==")
do {
    func hexOf(_ algorithm: HashAlgorithm, _ string: String) -> String {
        let hasher = algorithm.makeHasher()
        hasher.update(string.data(using: .utf8)!)
        return hasher.finalizedHex()
    }
    // Every algorithm must carry a user-facing explanation + kind label for Settings.
    for algo in HashAlgorithm.allCases {
        check(algo.explanation.count > 40 && algo.kindLabel.contains("·"),
              "\(algo.rawValue) has an explanation and kind label",
              detail: "explanation=\(algo.explanation.count) chars")
    }
    check(HashAlgorithm.allCases.filter(\.isRecommended) == [.sha256], "SHA-256 is the recommended default")

    check(hexOf(.crc32, "123456789") == "cbf43926", "CRC-32 known answer")
    check(hexOf(.sha256, "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known answer")
    check(hexOf(.md5, "abc") == "900150983cd24fb0d6963f7d28e17f72", "MD5 known answer")
    check(hexOf(.sha1, "abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 known answer")
}

// ============================================================
print("== Copy + verify a mixed tree ==")
let copySource = try makeTempDir("copy-src")
let copyDest = try makeTempDir("copy-dst")
try buildSourceTree(in: copySource)

do {
    let plan = SourceScanner.scan(sources: [copySource.appendingPathComponent("tree")])
    check(plan.items.count == 5, "scanner found 5 items", detail: "got \(plan.items.count)")
    check(plan.scanErrors.isEmpty, "no scan errors")

    let delegate = TestDelegate()
    let engine = TransferEngine()
    let summary = await engine.run(plan: plan, mode: .copy, algorithm: .sha256,
                                   destinationRoot: copyDest, delegate: delegate)

    check(summary.failed == 0 && summary.fatalError == nil, "no failures", detail: summary.fatalError ?? "\(summary.failed) failed")
    check(summary.succeeded == 5, "5 items succeeded", detail: "got \(summary.succeeded)")

    let map = statuses(plan.items)
    _ = map // plan items are value copies; final statuses were delivered via delegate — validate on disk instead.

    let destTree = copyDest.appendingPathComponent("tree")
    check(fm.contentsEqual(atPath: copySource.appendingPathComponent("tree/file1.txt").path,
                           andPath: destTree.appendingPathComponent("file1.txt").path),
          "file1.txt byte-identical")
    check(fm.contentsEqual(atPath: copySource.appendingPathComponent("tree/nested/big.bin").path,
                           andPath: destTree.appendingPathComponent("nested/big.bin").path),
          "big.bin (9 MB, multi-chunk) byte-identical")
    check(fm.fileExists(atPath: destTree.appendingPathComponent("empty.txt").path), "empty file copied")

    var isDir: ObjCBool = false
    _ = fm.fileExists(atPath: destTree.appendingPathComponent("empty-dir").path, isDirectory: &isDir)
    check(isDir.boolValue, "empty directory recreated")

    let linkTarget = try? fm.destinationOfSymbolicLink(atPath: destTree.appendingPathComponent("link-to-file1").path)
    check(linkTarget == "file1.txt", "symlink copied as symlink", detail: "target=\(linkTarget ?? "nil")")

    check(fm.fileExists(atPath: destTree.appendingPathComponent("nested/deeper/wéird nàme 🚀.txt").path),
          "unicode filename copied")

    // Source must be untouched by a copy.
    check(fm.fileExists(atPath: copySource.appendingPathComponent("tree/file1.txt").path), "source intact after copy")
}

// ============================================================
print("== Verify mode detects corruption ==")
do {
    let corruptTarget = copyDest.appendingPathComponent("tree/nested/big.bin")
    let handle = try FileHandle(forWritingTo: corruptTarget)
    try handle.seek(toOffset: 5 * 1024 * 1024) // flip one byte mid-file
    var byte: UInt8 = 0
    let reader = try FileHandle(forReadingFrom: corruptTarget)
    try reader.seek(toOffset: 5 * 1024 * 1024)
    byte = (try reader.read(upToCount: 1))?.first ?? 0
    try reader.close()
    try handle.write(contentsOf: Data([byte ^ 0xFF]))
    try handle.close()

    let plan = SourceScanner.scan(sources: [copySource.appendingPathComponent("tree")])
    let delegate = TestDelegate()
    let engine = TransferEngine()
    var collected: [Int: FileItem] = [:]

    final class Collector: TransferEngineDelegate {
        var items: [Int: FileItem] = [:]
        func engineDidUpdate(item: FileItem, at index: Int) async { items[index] = item }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
    }
    let collector = Collector()
    let summary = await engine.run(plan: plan, mode: .verify, algorithm: .sha256,
                                   destinationRoot: copyDest, delegate: collector)
    collected = collector.items
    _ = delegate

    check(summary.failed == 1, "exactly one file failed verification", detail: "failed=\(summary.failed)")
    let failedItems = collected.values.filter { $0.status == .failed }
    check(failedItems.count == 1 && failedItems.first?.relativePath.hasSuffix("big.bin") == true,
          "the corrupted file is the one flagged",
          detail: failedItems.map(\.relativePath).joined(separator: ","))

    // The intact files must actually COMPLETE — the bug was that verify never pushed the final
    // .done status, so good files stayed stuck showing "Verifying…" forever.
    let stuck = collected.values.filter { $0.status == .verifying }
    check(stuck.isEmpty, "no intact file is left stuck in the verifying state",
          detail: "stuck=\(stuck.map(\.relativePath))")
    check(summary.succeeded == 4, "the four intact items are reported as succeeded",
          detail: "succeeded=\(summary.succeeded)")
    let doneCount = collected.values.filter { $0.status == .done || $0.status == .doneNoVerify }.count
    check(doneCount == 4, "four items reach a completed (done) state via the delegate",
          detail: "done=\(doneCount)")
}

// ============================================================
print("== Conflict policies ==")
do {
    let source = try makeTempDir("conflict-src")
    let dest = try makeTempDir("conflict-dst")
    try "NEW CONTENT".data(using: .utf8)!.write(to: source.appendingPathComponent("dup.txt"))
    try "OLD CONTENT".data(using: .utf8)!.write(to: dest.appendingPathComponent("dup.txt"))

    // Skip
    var plan = SourceScanner.scan(sources: [source.appendingPathComponent("dup.txt")])
    let delegate = TestDelegate()
    delegate.resolution = ConflictResolution(choice: .skip, applyToAll: false)
    var summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, delegate: delegate)
    let afterSkip = try String(contentsOf: dest.appendingPathComponent("dup.txt"), encoding: .utf8)
    check(summary.skipped == 1 && afterSkip == "OLD CONTENT", "skip leaves existing file untouched")

    // Keep both
    delegate.resolution = ConflictResolution(choice: .keepBoth, applyToAll: false)
    plan = SourceScanner.scan(sources: [source.appendingPathComponent("dup.txt")])
    summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                         destinationRoot: dest, delegate: delegate)
    let keptBoth = try String(contentsOf: dest.appendingPathComponent("dup 2.txt"), encoding: .utf8)
    let originalAfterKeepBoth = try String(contentsOf: dest.appendingPathComponent("dup.txt"), encoding: .utf8)
    check(summary.succeeded == 1 && keptBoth == "NEW CONTENT" && originalAfterKeepBoth == "OLD CONTENT",
          "keep-both writes \"dup 2.txt\" and preserves the original")

    // Overwrite
    delegate.resolution = ConflictResolution(choice: .overwrite, applyToAll: false)
    plan = SourceScanner.scan(sources: [source.appendingPathComponent("dup.txt")])
    summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                         destinationRoot: dest, delegate: delegate)
    let afterOverwrite = try String(contentsOf: dest.appendingPathComponent("dup.txt"), encoding: .utf8)
    check(summary.succeeded == 1 && afterOverwrite == "NEW CONTENT", "overwrite replaces the file")
    check(delegate.conflictCount == 3, "conflict dialog consulted every time", detail: "count=\(delegate.conflictCount)")
}

// ============================================================
print("== Verification-off copy ==")
do {
    let source = try makeTempDir("noverify-src")
    let dest = try makeTempDir("noverify-dst")
    try randomData(6 * 1024 * 1024).write(to: source.appendingPathComponent("clip.bin"))

    final class Collector: TransferEngineDelegate {
        var last: FileItem?
        func engineDidUpdate(item: FileItem, at index: Int) async { last = item }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
    }
    let collector = Collector()
    let plan = SourceScanner.scan(sources: [source.appendingPathComponent("clip.bin")])
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, verification: .off,
                                             delegate: collector)
    check(summary.succeeded == 1 && summary.failed == 0, "verify-off copy succeeds")
    check(fm.contentsEqual(atPath: source.appendingPathComponent("clip.bin").path,
                           andPath: dest.appendingPathComponent("clip.bin").path),
          "verify-off copy is byte-identical")
    check(collector.last?.status == .doneNoVerify, "status reports verification was skipped",
          detail: "\(String(describing: collector.last?.status))")
    check(collector.last?.checksum != nil, "checksum still computed for the manifest")
}

// ============================================================
print("== Deferred verification (verify at end) ==")

func flipByte(at url: URL, offset: UInt64) throws {
    let reader = try FileHandle(forReadingFrom: url)
    try reader.seek(toOffset: offset)
    let byte = (try reader.read(upToCount: 1))?.first ?? 0
    try reader.close()
    let writer = try FileHandle(forWritingTo: url)
    try writer.seek(toOffset: offset)
    try writer.write(contentsOf: Data([byte ^ 0xFF]))
    try writer.close()
}

final class DeferredDelegate: TransferEngineDelegate {
    var phaseFileCount = 0
    var phaseTotalBytes: Int64 = 0
    var sawCopiedStatus = false
    var items: [Int: FileItem] = [:]
    /// File to corrupt at the exact moment phase 2 begins (after all copies, before any verify).
    var corruptTarget: URL?

    func engineDidUpdate(item: FileItem, at index: Int) async {
        if item.status == .copied { sawCopiedStatus = true }
        items[index] = item
    }
    func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
    func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
        ConflictResolution(choice: .skip, applyToAll: true)
    }
    func engineDidBeginVerificationPhase(fileCount: Int, totalBytes: Int64) async {
        phaseFileCount = fileCount
        phaseTotalBytes = totalBytes
        if let corruptTarget { try? flipByte(at: corruptTarget, offset: 1024) }
    }
}

do {
    // Clean copy: everything copies first, then verifies in one pass.
    let source = try makeTempDir("deferred-src")
    let dest = try makeTempDir("deferred-dst")
    let root = source.appendingPathComponent("batch")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try randomData(5 * 1024 * 1024).write(to: root.appendingPathComponent("a.bin"))
    try randomData(5 * 1024 * 1024).write(to: root.appendingPathComponent("b.bin"))

    let delegate = DeferredDelegate()
    let plan = SourceScanner.scan(sources: [root])
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, verification: .afterAll,
                                             delegate: delegate)
    check(delegate.sawCopiedStatus, "items pass through the copied-awaiting-verify state")
    check(delegate.phaseFileCount == 2 && delegate.phaseTotalBytes == 10 * 1024 * 1024,
          "verification phase announced with correct scope",
          detail: "files=\(delegate.phaseFileCount) bytes=\(delegate.phaseTotalBytes)")
    check(summary.succeeded == 2 && summary.failed == 0, "both files verified in the end pass")
    check(delegate.items.values.allSatisfy { $0.status == .done }, "all items end in verified state")
}

do {
    // Corruption that happens AFTER copying but BEFORE the end pass must be caught,
    // and — for a move — the corrupted file's source must NOT be deleted.
    let source = try makeTempDir("deferred-move-src")
    let dest = try makeTempDir("deferred-move-dst")
    let root = source.appendingPathComponent("batch")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try randomData(5 * 1024 * 1024).write(to: root.appendingPathComponent("a.bin"))
    try randomData(5 * 1024 * 1024).write(to: root.appendingPathComponent("b.bin"))

    let delegate = DeferredDelegate()
    delegate.corruptTarget = dest.appendingPathComponent("batch/a.bin")
    let plan = SourceScanner.scan(sources: [root])
    let summary = await TransferEngine(forceCrossVolume: true).run(
        plan: plan, mode: .move, algorithm: .sha256,
        destinationRoot: dest, verification: .afterAll, delegate: delegate)

    check(summary.failed == 1 && summary.succeeded == 1,
          "end-pass corruption detected on exactly one file",
          detail: "ok=\(summary.succeeded) fail=\(summary.failed)")
    check(fm.fileExists(atPath: root.appendingPathComponent("a.bin").path),
          "MOVE SAFETY: corrupted file's source was NOT deleted")
    check(!fm.fileExists(atPath: root.appendingPathComponent("b.bin").path),
          "verified file's source was deleted as part of the move")
    let failed = delegate.items.values.filter { $0.status == .failed }
    check(failed.count == 1 && failed.first?.relativePath.hasSuffix("a.bin") == true,
          "the corrupted file is the one flagged in the end pass")
}

// ============================================================
print("== Checksum manifest ==")
do {
    // Manually-built items: one verified-good, one verification-failed, one copied-unverified.
    func item(_ path: String, status: ItemStatus, checksum: String?) -> FileItem {
        var it = FileItem(sourceURL: URL(fileURLWithPath: "/tmp/\(path)"), relativePath: path,
                          size: 10, isSymlink: false)
        it.status = status
        it.checksum = checksum
        return it
    }
    let good = item("a.txt", status: .done, checksum: "aaaa")
    let failed = item("bad.txt", status: .failed, checksum: "bbbb")   // has source hash but bad dest
    let unverified = item("c.txt", status: .doneNoVerify, checksum: "cccc")
    let skipped = item("skip.txt", status: .skipped, checksum: nil)

    let result = ChecksumManifest.build(from: [good, failed, unverified, skipped], algorithm: .sha256)
    check(result.includedCount == 2, "manifest includes only good + unverified files",
          detail: "included=\(result.includedCount)")
    check(result.excludedFailedCount == 1, "failed file is excluded and counted",
          detail: "excluded=\(result.excludedFailedCount)")
    check(result.unverifiedCount == 1, "verification-off file counted for the warning",
          detail: "unverified=\(result.unverifiedCount)")
    check(!result.text.contains("bad.txt"), "failed file's path is absent from the manifest text")
    check(result.text.contains("aaaa  a.txt"), "shasum format is hash + two spaces + path")

    // keep-both rename must be recorded under the destination name.
    var renamed = item("photos/pic.jpg", status: .done, checksum: "dddd")
    renamed.destinationName = "pic 2.jpg"
    let renamedResult = ChecksumManifest.build(from: [renamed], algorithm: .sha256)
    check(renamedResult.text.contains("dddd  photos/pic 2.jpg"),
          "keep-both rename is reflected in the manifest path", detail: renamedResult.text)

    // CRC-32 uses SFV order (name first).
    let sfv = ChecksumManifest.build(from: [item("movie.bin", status: .done, checksum: "cbf43926")], algorithm: .crc32)
    check(sfv.text.contains("movie.bin cbf43926"), "CRC-32 manifest uses SFV name-first format", detail: sfv.text)
}

// ============================================================
print("== Manifest round-trips through the system shasum tool ==")
do {
    let source = try makeTempDir("manifest-src")
    let dest = try makeTempDir("manifest-dst")
    let root = source.appendingPathComponent("data")
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "one".data(using: .utf8)!.write(to: root.appendingPathComponent("one.txt"))
    try randomData(3 * 1024 * 1024).write(to: root.appendingPathComponent("sub/two.bin"))

    final class Collector: TransferEngineDelegate {
        var items: [Int: FileItem] = [:]
        func engineDidUpdate(item: FileItem, at index: Int) async { items[index] = item }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }
    let collector = Collector()
    let plan = SourceScanner.scan(sources: [root])
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, verification: .perFile,
                                             delegate: collector)
    check(summary.failed == 0, "copy for manifest test succeeded")

    let finalItems = plan.items.indices.compactMap { collector.items[$0] }
    let manifest = ChecksumManifest.build(from: finalItems, algorithm: .sha256)
    check(manifest.excludedFailedCount == 0, "no failures to exclude in a clean copy")

    // Write the manifest into the destination and check it with the real `shasum -c`,
    // proving our hashes match what an independent tool computes on the copied files.
    let manifestURL = dest.appendingPathComponent("checksums.sha256")
    try manifest.text.write(to: manifestURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", "-c", "checksums.sha256"]
    process.currentDirectoryURL = dest
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(process.terminationStatus == 0, "system shasum -c accepts the manifest (exit 0)",
          detail: "status=\(process.terminationStatus)")
    check(out.contains("one.txt: OK") && out.contains("two.bin: OK"),
          "shasum confirms both destination files match the recorded hashes",
          detail: out.trimmingCharacters(in: .whitespacesAndNewlines))
}

// ============================================================
print("== Notification content ==")
do {
    func summary(succeeded: Int = 0, skipped: Int = 0, failed: Int = 0,
                 bytes: Int64 = 0, elapsed: TimeInterval = 0,
                 cancelled: Bool = false, fatal: String? = nil) -> TransferSummary {
        var s = TransferSummary()
        s.succeeded = succeeded; s.skipped = skipped; s.failed = failed
        s.bytesCopied = bytes; s.elapsed = elapsed; s.cancelled = cancelled; s.fatalError = fatal
        return s
    }
    let dest = URL(fileURLWithPath: "/Volumes/Backup/Photos")

    let ok = NotificationContent.forJob(name: "Job 1", destination: dest,
                                        summary: summary(succeeded: 128, bytes: 2_400_000_000, elapsed: 192))
    check(!ok.isFailure, "successful job is not a failure")
    check(ok.title == "Job 1 complete", "success title", detail: ok.title)
    check(ok.body.contains("128 files copied & verified") && ok.body.contains("Photos"),
          "success body has count + destination", detail: ok.body)
    check(ok.shortText.contains("✅") && ok.shortText.contains("Job 1"), "success short text", detail: ok.shortText)

    let oneFile = NotificationContent.forJob(name: "J", destination: nil, summary: summary(succeeded: 1, bytes: 10, elapsed: 1))
    check(oneFile.body.contains("1 file copied"), "singular 'file' for one item", detail: oneFile.body)

    // A user-supplied job label (the rename feature) flows verbatim into notifications.
    let labeled = NotificationContent.forJob(name: "Wedding 📸 RAWs", destination: dest,
                                             summary: summary(succeeded: 40, bytes: 10, elapsed: 5))
    check(labeled.title == "Wedding 📸 RAWs complete" && labeled.shortText.contains("Wedding 📸 RAWs"),
          "custom job label appears in notification title + text", detail: labeled.title)

    let fail = NotificationContent.forJob(name: "Job 2", destination: dest,
                                          summary: summary(succeeded: 126, failed: 2, bytes: 10, elapsed: 60))
    check(fail.isFailure, "job with failures is a failure")
    check(fail.title.contains("errors") && fail.body.contains("2 files FAILED"),
          "failure title + body emphasize failures", detail: "\(fail.title) / \(fail.body)")
    check(fail.shortText.contains("⚠️"), "failure short text warns", detail: fail.shortText)

    let cancelled = NotificationContent.forJob(name: "J", destination: dest,
                                               summary: summary(succeeded: 3, bytes: 10, cancelled: true))
    check(!cancelled.isFailure && cancelled.title.contains("cancelled"), "cancelled title", detail: cancelled.title)

    let fatal = NotificationContent.forJob(name: "J", destination: dest,
                                           summary: summary(fatal: "Not enough free space on the destination volume."))
    check(fatal.isFailure && fatal.body.contains("free space"), "fatal surfaces the reason", detail: fatal.body)

    let queue = NotificationContent.forQueue(jobCount: 3, combined: summary(succeeded: 340, bytes: 5_000_000_000, elapsed: 600))
    check(queue.title == "Queue complete" && queue.body.contains("3 jobs"), "queue rollup content", detail: "\(queue.title)/\(queue.body)")
}

// ============================================================
print("== Notification gating (shouldNotify) ==")
do {
    func ok() -> TransferSummary { var s = TransferSummary(); s.succeeded = 5; return s }
    func bad() -> TransferSummary { var s = TransferSummary(); s.succeeded = 3; s.failed = 2; return s }

    // Desktop, per-job trigger
    let perJob = NotificationSettings(desktopEnabled: true, trigger: .eachJob, onlyOnFailure: false)
    check(perJob.shouldNotifyDesktop(isFailure: false, phase: .job), "eachJob: desktop fires per job")
    check(perJob.shouldNotifyDesktop(isFailure: false, phase: .queue), "eachJob: desktop also allowed at queue rollup")

    // Desktop, queue-only trigger — no per-job notifications
    let queueOnly = NotificationSettings(desktopEnabled: true, trigger: .queueComplete)
    check(!queueOnly.shouldNotifyDesktop(isFailure: false, phase: .job), "queueComplete: no per-job desktop")
    check(queueOnly.shouldNotifyDesktop(isFailure: false, phase: .queue), "queueComplete: desktop fires at queue end")

    // onlyOnFailure gate
    let onlyFail = NotificationSettings(desktopEnabled: true, trigger: .eachJob, onlyOnFailure: true)
    check(!onlyFail.shouldNotifyDesktop(isFailure: false, phase: .job), "onlyOnFailure suppresses success")
    check(onlyFail.shouldNotifyDesktop(isFailure: true, phase: .job), "onlyOnFailure allows failure")

    // Disabled desktop
    let off = NotificationSettings(desktopEnabled: false)
    check(!off.shouldNotifyDesktop(isFailure: true, phase: .queue), "disabled desktop never fires")

    // SMS requires enabled + recipient, and is quiet per-job unless failure+eachJob
    let smsOff = NotificationSettings(smsEnabled: false, smsRecipient: "x")
    check(!smsOff.shouldNotifySMS(isFailure: true, phase: .queue), "SMS disabled never fires")
    let smsNoRecipient = NotificationSettings(smsEnabled: true, smsRecipient: "   ")
    check(!smsNoRecipient.shouldNotifySMS(isFailure: true, phase: .queue), "SMS with blank recipient never fires")
    let smsOn = NotificationSettings(smsEnabled: true, trigger: .eachJob, smsRecipient: "+1555")
    check(!smsOn.shouldNotifySMS(isFailure: false, phase: .job), "SMS stays quiet on per-job success")
    check(smsOn.shouldNotifySMS(isFailure: true, phase: .job), "SMS texts on a per-job failure")
    check(smsOn.shouldNotifySMS(isFailure: false, phase: .queue), "SMS texts on queue completion")
    _ = (ok(), bad())
}

// ============================================================
print("== FTP path confinement (security boundary) ==")
do {
    let root = URL(fileURLWithPath: "/Users/test/Receive")

    // Normal, legitimate paths resolve inside the receive folder.
    check(resolveFTPPath("DSC_0001.CR3", cwd: "/", root: root)?.path
            == "/Users/test/Receive/DSC_0001.CR3", "plain filename resolves")
    check(resolveFTPPath("2026-08-05/DSC_0001.CR3", cwd: "/", root: root)?.path
            == "/Users/test/Receive/2026-08-05/DSC_0001.CR3", "nested path resolves")
    check(resolveFTPPath("shot.CR3", cwd: "/2026-08-05", root: root)?.path
            == "/Users/test/Receive/2026-08-05/shot.CR3", "relative to cwd resolves")
    check(resolveFTPPath("/", cwd: "/", root: root)?.path == "/Users/test/Receive",
          "root resolves to the receive folder")
    check(resolveFTPPath("./a/./b.CR3", cwd: "/", root: root)?.path
            == "/Users/test/Receive/a/b.CR3", "'.' components are ignored")
    check(resolveFTPPath("a/b/../c.CR3", cwd: "/", root: root)?.path
            == "/Users/test/Receive/a/c.CR3", "interior '..' that stays inside is allowed")
    check(resolveFTPPath("my photo.CR3", cwd: "/", root: root)?.path
            == "/Users/test/Receive/my photo.CR3", "spaces in filenames survive")

    // ESCAPES — every one of these must be refused.
    check(resolveFTPPath("..", cwd: "/", root: root) == nil, "REJECT: '..'")
    check(resolveFTPPath("../secrets", cwd: "/", root: root) == nil, "REJECT: '../secrets'")
    check(resolveFTPPath("../../etc/passwd", cwd: "/", root: root) == nil, "REJECT: deep '..' escape")
    // FTP-absolute paths are rooted at the RECEIVE FOLDER, not the filesystem root — so
    // "/etc/passwd" is contained rather than refused. This is the containment property:
    // no absolute path a client sends can ever reach the real /etc/passwd.
    check(resolveFTPPath("/etc/passwd", cwd: "/", root: root)?.path
            == "/Users/test/Receive/etc/passwd",
          "absolute client path is confined to the receive folder, not the real /etc")
    check(resolveFTPPath("/../../etc/passwd", cwd: "/", root: root) == nil,
          "REJECT: absolute path with '..' escaping root")
    check(resolveFTPPath("a/../../b", cwd: "/", root: root) == nil,
          "REJECT: '..' that climbs out after descending")
    check(resolveFTPPath("../x", cwd: "/sub", root: root)?.path == "/Users/test/Receive/x",
          "'..' from a subdir lands back at root (allowed)")
    check(resolveFTPPath("../../x", cwd: "/sub", root: root) == nil,
          "REJECT: '..' past root from a subdir")
    check(resolveFTPPath("bad\u{0000}name", cwd: "/", root: root) == nil, "REJECT: NUL byte")
    check(resolveFTPPath("bad\nname", cwd: "/", root: root) == nil, "REJECT: newline injection")
    check(resolveFTPPath("back\\slash", cwd: "/", root: root) == nil, "REJECT: backslash component")

    // Display paths for PWD/CWD replies.
    check(ftpDisplayPath(for: root, root: root) == "/", "display path for root is '/'")
    check(ftpDisplayPath(for: root.appendingPathComponent("a/b"), root: root) == "/a/b",
          "display path for a nested folder")
}

// ============================================================
print("== FTP LAN filtering ==")
do {
    for ip in ["127.0.0.1", "10.0.0.5", "192.168.1.42", "172.16.0.1", "172.31.255.254",
               "169.254.1.1", "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.9"] {
        check(isLANAddress(ip), "accept LAN address \(ip)")
    }
    for ip in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "203.0.113.5",
               "2001:4860:4860::8888", "not-an-ip", "", "999.1.1.1"] {
        check(!isLANAddress(ip), "REJECT non-LAN address '\(ip)'")
    }
}

// ============================================================
print("== FTP command parsing ==")
do {
    check(FTPCommand.parse("USER camera\r\n") == .user("camera"), "USER with CRLF")
    check(FTPCommand.parse("pass secret") == .pass("secret"), "lowercase verb")
    check(FTPCommand.parse("  TYPE   i  ") == .type("I"), "odd spacing + case normalization")
    check(FTPCommand.parse("STOR my photo.CR3") == .stor("my photo.CR3"),
          "filename with spaces is not split")
    check(FTPCommand.parse("PASV") == .pasv, "PASV")
    check(FTPCommand.parse("EPSV") == .epsv, "EPSV")
    check(FTPCommand.parse("XPWD") == .pwd, "XPWD aliases PWD")
    check(FTPCommand.parse("XMKD shots") == .mkd("shots"), "XMKD aliases MKD")
    check(FTPCommand.parse("LIST") == .list(nil), "bare LIST")
    check(FTPCommand.parse("LIST /a") == .list("/a"), "LIST with path")
    check(FTPCommand.parse("QUIT") == .quit && FTPCommand.parse("BYE") == .quit, "QUIT/BYE")
    check(FTPCommand.parse("FROBNICATE") == .unsupported("FROBNICATE"), "unknown verb")
    check(FTPCommand.parse("") == .unsupported(""), "empty line")

    // Active mode: the camera tells us where to connect back.
    check(FTPCommand.parse("PORT 192,168,1,42,4,1") == .port(host: "192.168.1.42", port: 1025),
          "PORT parses host and port")
    check(FTPCommand.parse("PORT 1,2,3") == .unsupported("PORT"), "REJECT: short PORT")
    check(FTPCommand.parse("PORT 192,168,1,42,999,1") == .unsupported("PORT"),
          "REJECT: PORT octet out of range")
    check(FTPCommand.parse("PORT 192,168,1,42,0,0") == .unsupported("PORT"),
          "REJECT: PORT resolving to port 0")
}

// ============================================================
print("== FTP response formatting ==")
do {
    check(FTPResponse.pasv(host: "192.168.1.42", port: 50000)
            == "227 Entering Passive Mode (192,168,1,42,195,80)",
          "PASV reply uses the exact h1,h2,h3,h4,p1,p2 form")
    check(FTPResponse.epsv(port: 50000) == "229 Entering Extended Passive Mode (|||50000|)",
          "EPSV reply form")

    let now = Date()
    let recent = FTPResponse.listLine(name: "a.CR3", size: 1234, isDirectory: false,
                                      modified: now, now: now)
    check(recent.hasPrefix("-rw-r--r--") && recent.hasSuffix(" a.CR3") && recent.contains("1234"),
          "file list line looks like ls -l", detail: recent)
    let dir = FTPResponse.listLine(name: "shots", size: 0, isDirectory: true,
                                   modified: now, now: now)
    check(dir.hasPrefix("drwxr-xr-x"), "directory list line", detail: dir)
    let old = FTPResponse.listLine(name: "old.CR3", size: 1, isDirectory: false,
                                   modified: now.addingTimeInterval(-60 * 60 * 24 * 400), now: now)
    check(old.contains("20"), "old files show a year instead of a time", detail: old)
}

// ============================================================
print("== Completion policy (sleep / quit when finished) ==")
do {
    func summary(succeeded: Int = 1, failed: Int = 0, cancelled: Bool = false,
                 fatal: String? = nil, bytes: Int64 = 1024) -> TransferSummary {
        var s = TransferSummary()
        s.succeeded = succeeded; s.failed = failed; s.cancelled = cancelled
        s.fatalError = fatal; s.bytesCopied = bytes
        return s
    }
    let sleepDefault = PowerSettings(defaultCompletionAction: .sleep, countdownSeconds: 30)

    // Clean multi-job run arms the countdown.
    let clean = RunOutcome.summarize([summary(), summary()], stopRequested: false)
    check(sleepDefault.decideCompletion(jobActions: [.sleep, .sleep], outcome: clean)
            == .armCountdown(.sleep, seconds: 30),
          "clean run arms the countdown")

    // Failures block it (the user should see what went wrong).
    let failed = RunOutcome.summarize([summary(), summary(failed: 2)], stopRequested: false)
    check(sleepDefault.decideCompletion(jobActions: [.sleep, .sleep], outcome: failed)
            == .blocked(.sleep, .runHadFailures),
          "a failed file blocks sleeping")
    check(RunOutcome.summarize([summary(fatal: "no space")], stopRequested: false).anyFailures,
          "a fatalError counts as a failure")

    // …unless the user turned that guard off.
    var noGuard = sleepDefault; noGuard.skipAfterFailures = false
    check(noGuard.decideCompletion(jobActions: [.sleep], outcome: failed)
            == .armCountdown(.sleep, seconds: 30),
          "with the failure guard off, failures still sleep")

    // Stop Queue blocks it — the user is clearly at the machine.
    let stopped = RunOutcome.summarize([summary()], stopRequested: true)
    check(sleepDefault.decideCompletion(jobActions: [.sleep], outcome: stopped)
            == .blocked(.sleep, .runWasCancelled),
          "Stop Queue blocks sleeping")

    // So does a per-job cancel, which sets summary.cancelled without stopRequested.
    let perJobCancel = RunOutcome.summarize([summary(cancelled: true)], stopRequested: false)
    check(sleepDefault.decideCompletion(jobActions: [.sleep], outcome: perJobCancel)
            == .blocked(.sleep, .runWasCancelled),
          "a per-job cancel blocks sleeping")

    // Nothing ran at all.
    check(sleepDefault.decideCompletion(jobActions: [], outcome: RunOutcome.summarize([], stopRequested: false))
            == .blocked(.sleep, .nothingRan),
          "a run where no job executed is blocked")

    // Precedence: `.nothing` wins over everything, so an un-armed run never explains itself.
    check(sleepDefault.decideCompletion(jobActions: [.nothing], outcome: failed) == .doNothing,
          "'Do nothing' takes precedence over the failure block")

    // Last job that ran wins; empty falls back to the Settings default.
    check(sleepDefault.resolveAction(jobActions: [.sleep, .quit]) == .quit, "last job's action wins")
    check(sleepDefault.resolveAction(jobActions: []) == .sleep, "no jobs falls back to the default")
    check(PowerSettings().resolveAction(jobActions: []) == .nothing, "shipping default is 'Do nothing'")

    // Keep-awake gate.
    check(PowerSettings().shouldHoldAwake(queueActive: true), "keep-awake holds while the queue runs")
    check(!PowerSettings().shouldHoldAwake(queueActive: false), "keep-awake drops when idle")
    check(!PowerSettings(keepAwakeEnabled: false).shouldHoldAwake(queueActive: true),
          "keep-awake respects the setting being off")

    // Countdown presentation.
    let pending = PendingCompletion(action: .sleep, totalSeconds: 30, secondsRemaining: 15,
                                    detail: clean.detailLine)
    check(pending.fraction == 0.5, "countdown fraction drains linearly", detail: "\(pending.fraction)")
    check(pending.headline == "Sleeping in 15s", "countdown headline", detail: pending.headline)
    check(clean.detailLine.contains("2 jobs"), "run detail line summarizes the run", detail: clean.detailLine)
}

// ============================================================
print("== Move: same-volume fast path ==")
do {
    let source = try makeTempDir("move-src")
    let dest = try makeTempDir("move-dst")
    try buildSourceTree(in: source)

    let plan = SourceScanner.scan(sources: [source.appendingPathComponent("tree")])
    let summary = await TransferEngine().run(plan: plan, mode: .move, algorithm: .sha256,
                                             destinationRoot: dest, delegate: TestDelegate())
    check(summary.failed == 0 && summary.succeeded == 5, "all items moved", detail: "ok=\(summary.succeeded) fail=\(summary.failed)")
    check(fm.fileExists(atPath: dest.appendingPathComponent("tree/nested/big.bin").path), "moved file exists at destination")
    check(!fm.fileExists(atPath: source.appendingPathComponent("tree").path), "source tree fully removed after move")
}

// ============================================================
print("== Move: cross-volume path (copy + verify + delete source) ==")
do {
    let source = try makeTempDir("xmove-src")
    let dest = try makeTempDir("xmove-dst")
    try buildSourceTree(in: source)

    let plan = SourceScanner.scan(sources: [source.appendingPathComponent("tree")])
    let engine = TransferEngine(forceCrossVolume: true)
    let summary = await engine.run(plan: plan, mode: .move, algorithm: .sha256,
                                   destinationRoot: dest, delegate: TestDelegate())
    check(summary.failed == 0 && summary.succeeded == 5, "all items copy-moved", detail: "ok=\(summary.succeeded) fail=\(summary.failed)")
    check(fm.contentsEqual(atPath: dest.appendingPathComponent("tree/nested/big.bin").path,
                           andPath: dest.appendingPathComponent("tree/nested/big.bin").path),
          "moved big.bin readable at destination")
    check(fm.fileExists(atPath: dest.appendingPathComponent("tree/file1.txt").path), "file1.txt at destination")
    check(!fm.fileExists(atPath: source.appendingPathComponent("tree").path), "source tree removed after verified cross-volume move")
}

// ============================================================
print("== Pause holds the engine; cancel unwinds cleanly ==")
do {
    let source = try makeTempDir("cancel-src")
    let dest = try makeTempDir("cancel-dst")
    try randomData(32 * 1024 * 1024).write(to: source.appendingPathComponent("large.bin"))

    let plan = SourceScanner.scan(sources: [source.appendingPathComponent("large.bin")])
    let engine = TransferEngine()
    engine.pause() // paused before it ever starts

    let delegate = TestDelegate()
    let runTask = Task {
        await engine.run(plan: plan, mode: .copy, algorithm: .sha256,
                         destinationRoot: dest, delegate: delegate)
    }
    try await Task.sleep(nanoseconds: 400_000_000)
    check(!fm.fileExists(atPath: dest.appendingPathComponent("large.bin").path),
          "paused engine has not produced the destination file")

    engine.cancel()
    let summary = await runTask.value
    check(summary.cancelled, "summary reports cancellation")
    check(!fm.fileExists(atPath: dest.appendingPathComponent("large.bin").path),
          "no destination file after cancel")
    let leftovers = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
    check(leftovers.filter { $0.contains(".vcpart") }.isEmpty, "no partial files left behind", detail: "\(leftovers)")
}

// ============================================================
print("== Free-space pre-flight ==")
do {
    let source = try makeTempDir("space-src")
    let dest = try makeTempDir("space-dst")
    try "tiny".data(using: .utf8)!.write(to: source.appendingPathComponent("tiny.txt"))

    var plan = SourceScanner.scan(sources: [source.appendingPathComponent("tiny.txt")])
    // Inflate the reported size to an absurd number to trip the space check.
    plan.totalBytes = Int64.max / 4
    let real = plan.items[0]
    plan.items = [FileItem(sourceURL: real.sourceURL, relativePath: real.relativePath,
                           size: Int64.max / 4, isSymlink: false)]

    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, delegate: TestDelegate())
    check(summary.fatalError?.contains("free space") == true, "impossible job refused up front",
          detail: summary.fatalError ?? "no error")

    // The capacity helper must report a sane value for a real local folder.
    let capacity = TransferEngine.systemAvailableCapacity(at: dest)
    check((capacity ?? 0) > 0, "capacity helper reports free space on local volume",
          detail: "got \(capacity.map(String.init) ?? "nil")")

    // Regression (ExFAT/FAT32/NTFS/SMB): a volume whose capacity is UNKNOWN must not
    // be refused — the job proceeds and real write errors surface per-file if any.
    let normalPlan = SourceScanner.scan(sources: [source.appendingPathComponent("tiny.txt")])
    let unknownCapacity = TransferEngine(capacityProvider: { _ in nil })
    let unknownSummary = await unknownCapacity.run(plan: normalPlan, mode: .copy, algorithm: .sha256,
                                                   destinationRoot: dest, delegate: TestDelegate())
    check(unknownSummary.fatalError == nil && unknownSummary.succeeded == 1,
          "unknown capacity does not block the transfer",
          detail: unknownSummary.fatalError ?? "ok=\(unknownSummary.succeeded)")

    // A provider that reports a genuinely tiny capacity still refuses.
    try? fm.removeItem(at: dest.appendingPathComponent("tiny.txt"))
    let tinyCapacity = TransferEngine(capacityProvider: { _ in 1 })
    let refused = await tinyCapacity.run(plan: SourceScanner.scan(sources: [source.appendingPathComponent("tiny.txt")]),
                                         mode: .copy, algorithm: .sha256,
                                         destinationRoot: dest, delegate: TestDelegate())
    check(refused.fatalError?.contains("free space") == true, "known-tiny capacity still refused",
          detail: refused.fatalError ?? "no error")
}

// ============================================================
// Real-drive round trip: vericopy-selftest --external "/Volumes/SomeDrive"
// Copies a FAT-safe tree to a temp folder on the drive, verifies, then cleans up.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--external"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    let drivePath = CommandLine.arguments[flagIndex + 1]
    print("== EXTERNAL: copy + verify round trip on \(drivePath) ==")
    let driveRoot = URL(fileURLWithPath: drivePath)

    let capacity = TransferEngine.systemAvailableCapacity(at: driveRoot)
    check(capacity != nil, "capacity detected on external drive",
          detail: "APIs returned nil")
    if let capacity {
        print("  INFO  reported free space: \(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))")
    }

    let source = try makeTempDir("external-src")
    let root = source.appendingPathComponent("VeriCopy External Test")
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try randomData(24 * 1024 * 1024).write(to: root.appendingPathComponent("nested/payload.bin"))
    try "external drive test\n".data(using: .utf8)!.write(to: root.appendingPathComponent("note.txt"))
    try Data().write(to: root.appendingPathComponent("empty.dat"))

    let externalDest = driveRoot.appendingPathComponent(".vericopy-selftest-\(UUID().uuidString)")
    try fm.createDirectory(at: externalDest, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: externalDest) }

    let plan = SourceScanner.scan(sources: [root])
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: externalDest, delegate: TestDelegate())
    check(summary.fatalError == nil, "no fatal pre-flight error on external drive",
          detail: summary.fatalError ?? "")
    check(summary.failed == 0 && summary.succeeded == 3, "all 3 files copied + verified on external drive",
          detail: "ok=\(summary.succeeded) fail=\(summary.failed)")
    check(fm.contentsEqual(atPath: root.appendingPathComponent("nested/payload.bin").path,
                           andPath: externalDest.appendingPathComponent("VeriCopy External Test/nested/payload.bin").path),
          "24 MB payload byte-identical on external drive")
}

// ============================================================
if CommandLine.arguments.contains("--stress") {
    print("== STRESS: 1,500 small files + one 256 MB file, copy + verify ==")
    let source = try makeTempDir("stress-src")
    let dest = try makeTempDir("stress-dst")
    let root = source.appendingPathComponent("payload")

    for bucket in 0..<30 {
        let dir = root.appendingPathComponent("dir-\(bucket)/sub")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for fileIndex in 0..<50 {
            try randomData(Int.random(in: 100...20_000))
                .write(to: dir.appendingPathComponent("f\(bucket)-\(fileIndex).dat"))
        }
    }
    try randomData(256 * 1024 * 1024).write(to: root.appendingPathComponent("huge.bin"))

    let plan = SourceScanner.scan(sources: [root])
    check(plan.items.count == 1501, "scanner found 1,501 files", detail: "got \(plan.items.count)")

    final class StressDelegate: TransferEngineDelegate {
        var lastBytes: Int64 = 0
        func engineDidUpdate(item: FileItem, at index: Int) async {}
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async { lastBytes = bytesDone }
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
    }

    let delegate = StressDelegate()
    let engine = TransferEngine()
    let started = Date()

    let runTask = Task {
        await engine.run(plan: plan, mode: .copy, algorithm: .sha256,
                         destinationRoot: dest, delegate: delegate)
    }

    // Pause mid-flight and confirm progress genuinely halts, then resume.
    try await Task.sleep(nanoseconds: 300_000_000)
    engine.pause()
    try await Task.sleep(nanoseconds: 300_000_000)
    let frozen1 = delegate.lastBytes
    try await Task.sleep(nanoseconds: 500_000_000)
    let frozen2 = delegate.lastBytes
    check(frozen1 == frozen2, "progress frozen while paused", detail: "\(frozen1) vs \(frozen2)")
    engine.resume()

    let summary = await runTask.value
    let elapsed = Date().timeIntervalSince(started)
    check(summary.failed == 0 && summary.fatalError == nil, "stress copy had no failures",
          detail: summary.fatalError ?? "\(summary.failed) failed")
    check(summary.succeeded == 1501, "all 1,501 files copied + verified", detail: "got \(summary.succeeded)")
    check(fm.contentsEqual(atPath: root.appendingPathComponent("huge.bin").path,
                           andPath: dest.appendingPathComponent("payload/huge.bin").path),
          "256 MB file byte-identical after pause/resume")

    let mb = Double(summary.bytesCopied) / 1_048_576
    print(String(format: "  INFO  %.0f MB in %.1fs (incl. 1.1s forced pause + verify pass) — %.0f MB/s effective",
                 mb, elapsed, mb / elapsed))
}

// ============================================================
// Throughput benchmark: vericopy-selftest --bench [/Volumes/SomeDrive]
if let benchIndex = CommandLine.arguments.firstIndex(of: "--bench") {
    print("== BENCH ==")
    var externalBase: URL?
    if CommandLine.arguments.indices.contains(benchIndex + 1),
       !CommandLine.arguments[benchIndex + 1].hasPrefix("--") {
        externalBase = URL(fileURLWithPath: CommandLine.arguments[benchIndex + 1])
    }

    let srcDir = try makeTempDir("bench-src")
    let big = srcDir.appendingPathComponent("big.bin")
    fm.createFile(atPath: big.path, contents: nil)
    let bigHandle = try FileHandle(forWritingTo: big)
    for _ in 0..<48 { try bigHandle.write(contentsOf: randomData(32 * 1024 * 1024)) }
    try bigHandle.close()

    let smallDir = srcDir.appendingPathComponent("small")
    try fm.createDirectory(at: smallDir, withIntermediateDirectories: true)
    for index in 0..<2000 {
        try randomData(64 * 1024).write(to: smallDir.appendingPathComponent("s\(index).dat"))
    }

    final class NullDelegate: TransferEngineDelegate {
        func engineDidUpdate(item: FileItem, at index: Int) async {}
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }

    func bench(_ label: String, sources: [URL], dest: URL, mbTotal: Double, verify: Bool) async {
        let plan = SourceScanner.scan(sources: sources)
        let started = Date()
        let result = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                                destinationRoot: dest,
                                                verification: verify ? .perFile : .off,
                                                delegate: NullDelegate())
        let elapsed = Date().timeIntervalSince(started)
        let state = (result.failed == 0 && result.fatalError == nil) ? "ok" : "FAILED: \(result.fatalError ?? "\(result.failed) files")"
        print(String(format: "  %@ [%@]: %.2fs — %.0f MB/s", label, state, elapsed, mbTotal / elapsed))
    }

    var targets: [(String, URL)] = [("internal SSD", try makeTempDir("bench-dst"))]
    if let externalBase {
        let dir = externalBase.appendingPathComponent(".vericopy-bench-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        targets.append((externalBase.lastPathComponent, dir))
    }

    for (label, dest) in targets {
        await bench("1.5 GiB file, verify ON  → \(label)", sources: [big], dest: dest, mbTotal: 1536, verify: true)
        try? fm.removeItem(at: dest.appendingPathComponent("big.bin"))
        await bench("1.5 GiB file, verify OFF → \(label)", sources: [big], dest: dest, mbTotal: 1536, verify: false)
        try? fm.removeItem(at: dest.appendingPathComponent("big.bin"))
        await bench("2,000 × 64 KiB, verify ON  → \(label)", sources: [smallDir], dest: dest, mbTotal: 125, verify: true)
        try? fm.removeItem(at: dest.appendingPathComponent("small"))
        await bench("2,000 × 64 KiB, verify OFF → \(label)", sources: [smallDir], dest: dest, mbTotal: 125, verify: false)
        try? fm.removeItem(at: dest)
    }
}

// ============================================================
print("")
print("== Overlapped verification (read file N back while N+1 copies) ==")
do {
    final class Recorder: TransferEngineDelegate, @unchecked Sendable {
        var readings: [TransferProgress] = []
        var sawVerifying = false
        func engineDidUpdate(item: FileItem, at index: Int) async {
            if item.status == .verifying { sawVerifying = true }
        }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineDidUpdateProgress(_ p: TransferProgress) async { readings.append(p) }
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }

    let src = try makeTempDir("olap-src")
    var expected: [String: Data] = [:]
    for i in 0..<8 {
        let payload = randomData(700_000 + i * 1000)
        let u = src.appendingPathComponent("clip\(i).mxf")
        try payload.write(to: u)
        expected[u.lastPathComponent] = payload
    }
    let total = expected.values.reduce(Int64(0)) { $0 + Int64($1.count) }

    // The same job run both ways must agree on every verdict and every byte on disk.
    for overlap in [false, true] {
        let dest = try makeTempDir("olap-dest-\(overlap)")
        let recorder = Recorder()
        let plan = SourceScanner.scan(sources: [src])
        let engine = TransferEngine(overlapVerification: overlap)
        let summary = await engine.run(plan: plan, mode: .copy, algorithm: .sha256,
                                       destinationRoot: dest, verification: .perFile,
                                       delegate: recorder)
        check(summary.succeeded == 8 && summary.failed == 0,
              "overlap=\(overlap): all 8 files verified",
              detail: "ok \(summary.succeeded), failed \(summary.failed)")
        check(recorder.sawVerifying, "overlap=\(overlap): verification phase was visible")
        check(recorder.readings.last?.fraction == 1.0,
              "overlap=\(overlap): progress finishes at 100%")
        check(recorder.readings.last?.workTotal == total * 2,
              "overlap=\(overlap): work total still counts copy + read-back")
        var monotonic = true
        for (a, b) in zip(recorder.readings, recorder.readings.dropFirst()) where b.workDone < a.workDone {
            monotonic = false
        }
        check(monotonic, "overlap=\(overlap): progress never goes backwards")

        // Bytes on disk must match the source exactly.
        var identical = true
        for (name, payload) in expected {
            let landed = try? Data(contentsOf: dest.appendingPathComponent("olap-src/\(name)"))
            if landed != payload { identical = false }
        }
        check(identical, "overlap=\(overlap): every destination file is byte-identical")
    }

    // Move mode: sources must only disappear once their copy has been verified.
    let moveSrc = try makeTempDir("olap-move-src")
    for i in 0..<5 {
        try randomData(400_000).write(to: moveSrc.appendingPathComponent("m\(i).bin"))
    }
    let moveDest = try makeTempDir("olap-move-dest")
    let movePlan = SourceScanner.scan(sources: [moveSrc])
    let moveSummary = await TransferEngine(forceCrossVolume: true, overlapVerification: true)
        .run(plan: movePlan, mode: .move, algorithm: .sha256, destinationRoot: moveDest,
             verification: .perFile, delegate: TestDelegate())
    check(moveSummary.succeeded == 5 && moveSummary.failed == 0,
          "overlapped move: all files verified", detail: "ok \(moveSummary.succeeded)")
    let leftovers = (try? fm.contentsOfDirectory(atPath: moveSrc.path)) ?? []
    check(leftovers.isEmpty, "overlapped move: sources removed after verification",
          detail: "left behind: \(leftovers)")
    check((try? fm.contentsOfDirectory(atPath: moveDest.appendingPathComponent("olap-move-src").path))?.count == 5,
          "overlapped move: all files present at the destination")
}

print("== Overlapped verification still catches a bad copy ==")
do {
    // Corrupting a destination mid-read-back is a race unless the engine is held still, so:
    // pause at the first sign that the *next* file is copying — which means the previous
    // file's read-back is underway — flip a byte near the end of the file being verified,
    // then resume. hashFile checks for pause at every chunk boundary, so it cannot have
    // reached the tail yet.
    final class PausingDelegate: TransferEngineDelegate, @unchecked Sendable {
        weak var engine: TransferEngine?
        var victim: URL?
        var victimName = ""
        var victimIndex: Int?
        var didCorrupt = false
        var progressAtCorruption: Int64 = -1
        var statuses: [Int: ItemStatus] = [:]
        func engineDidUpdate(item: FileItem, at index: Int) async {
            statuses[index] = item.status
            if item.fileName == victimName { victimIndex = index }
            guard !didCorrupt, item.fileName == victimName, item.status == .verifying,
                  let engine, let victim else { return }
            didCorrupt = true
            progressAtCorruption = item.bytesCopied
            engine.pause()
            try? await Task.sleep(nanoseconds: 150_000_000)
            var info = stat()
            let size = stat(victim.path, &info) == 0 ? Int64(info.st_size) : 4096
            try? flipByte(at: victim, offset: UInt64(max(size - 2048, 0)))
            engine.resume()
        }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }

    let src = try makeTempDir("olap-bad-src")
    // The victim must be big enough that its read-back cannot finish in the ~15 ms before the
    // pump delivers the "verifying" status change that triggers the hook. 256 MiB takes an
    // order of magnitude longer than that even on an internal SSD.
    let victimBytes = 256 * 1024 * 1024
    try randomData(victimBytes).write(to: src.appendingPathComponent("a.bin"))
    try randomData(8 * 1024 * 1024).write(to: src.appendingPathComponent("b.bin"))
    let dest = try makeTempDir("olap-bad-dest")

    let delegate = PausingDelegate()
    let engine = TransferEngine(forceCrossVolume: true, overlapVerification: true)
    delegate.engine = engine
    delegate.victimName = "a.bin"
    delegate.victim = dest.appendingPathComponent("olap-bad-src/a.bin")

    let summary = await engine.run(plan: SourceScanner.scan(sources: [src]), mode: .move,
                                   algorithm: .sha256, destinationRoot: dest,
                                   verification: .perFile, delegate: delegate)
    if delegate.didCorrupt {
        // Guard against a vacuous pass: the hook must have fired while the read-back was
        // genuinely still in progress, not after it had already hashed the tail.
        check(delegate.progressAtCorruption < Int64(victimBytes),
              "corruption landed while the read-back was still running",
              detail: "\(delegate.progressAtCorruption) of \(victimBytes) bytes hashed")
        check(summary.failed == 1, "overlapped verification flags the corrupted file",
              detail: "failed \(summary.failed), ok \(summary.succeeded)")
        check(delegate.statuses[delegate.victimIndex ?? -1] == .failed,
              "the corrupted file is the one flagged",
              detail: "\(String(describing: delegate.statuses[delegate.victimIndex ?? -1]))")
        check(fm.fileExists(atPath: src.appendingPathComponent("a.bin").path),
              "MOVE SAFETY: corrupted file's source was NOT deleted")
        check(!fm.fileExists(atPath: src.appendingPathComponent("b.bin").path),
              "the good file's source WAS deleted")
    } else {
        check(false, "corruption hook never fired — test did not exercise the failure path")
    }
}

print("== Cancelling a run with a read-back in flight ==")
do {
    final class CancellingDelegate: TransferEngineDelegate, @unchecked Sendable {
        weak var engine: TransferEngine?
        var cancelled = false
        func engineDidUpdate(item: FileItem, at index: Int) async {
            guard !cancelled, index >= 1, item.status == .verifying else { return }
            cancelled = true
            engine?.cancel()
        }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }
    let src = try makeTempDir("olap-cancel-src")
    for i in 0..<12 { try randomData(3_000_000).write(to: src.appendingPathComponent("c\(i).bin")) }
    let dest = try makeTempDir("olap-cancel-dest")
    let delegate = CancellingDelegate()
    let engine = TransferEngine(overlapVerification: true)
    delegate.engine = engine

    // The real assertion is that this returns at all: a verification task left un-awaited
    // would hang the job.
    let summary = await withTaskGroup(of: TransferSummary?.self) { group -> TransferSummary? in
        group.addTask {
            await engine.run(plan: SourceScanner.scan(sources: [src]), mode: .copy,
                             algorithm: .sha256, destinationRoot: dest,
                             verification: .perFile, delegate: delegate)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    check(summary != nil, "cancelled overlapped run finished instead of hanging")
    if let summary {
        check(summary.cancelled, "summary reports cancellation")
        check(summary.failed == 0, "cancellation is not reported as a verification failure",
              detail: "failed \(summary.failed)")
    }
    check(!fm.fileExists(atPath: dest.appendingPathComponent("olap-cancel-src/.c0.bin.vcpart").path),
          "no partial files left behind after cancelling an overlapped run")
}

print("== Volume capabilities and metadata policy ==")
do {
    let caps = VolumeCapabilities.probe(at: base)
    check(!caps.unknown, "capability probe answers for the local volume")
    check(caps.nativeExtendedAttributes, "APFS reports native extended attributes")

    let exfatLike = VolumeCapabilities(nativeExtendedAttributes: false, extendedSecurity: false,
                                       cloning: false, unknown: false)
    check(MetadataPolicy.native.carriesExtendedMetadata(to: caps),
          ".native carries xattrs to a volume that stores them")
    check(!MetadataPolicy.native.carriesExtendedMetadata(to: exfatLike),
          ".native skips xattrs on an ExFAT-like volume (no '._' twins)")
    check(MetadataPolicy.full.carriesExtendedMetadata(to: exfatLike),
          ".full still carries xattrs everywhere")
    check(!MetadataPolicy.basic.carriesExtendedMetadata(to: caps),
          ".basic never carries xattrs")
    check(MetadataPolicy.native.carriesExtendedMetadata(to: .unknownVolume),
          "an unreadable volume keeps the old behaviour rather than dropping metadata")
}

print("== Per-file metadata survives the fast path ==")
do {
    let src = try makeTempDir("meta-src")
    let dest = try makeTempDir("meta-dest")
    let file = src.appendingPathComponent("clip.mxf")
    try randomData(300_000).write(to: file)
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let stamped = Date(timeIntervalSince1970: 1_600_000_000)
    try fm.setAttributes([.modificationDate: stamped], ofItemAtPath: file.path)
    let sourceAttrs = try fm.attributesOfItem(atPath: file.path)

    // .basic forces the descriptor-stamp path regardless of what the volume supports.
    let plan = SourceScanner.scan(sources: [file])
    let engine = TransferEngine(metadataPolicy: .basic)
    _ = await engine.run(plan: plan, mode: .copy, algorithm: .sha256,
                         destinationRoot: dest, verification: .perFile, delegate: TestDelegate())

    let copied = dest.appendingPathComponent("clip.mxf")
    let destAttrs = try fm.attributesOfItem(atPath: copied.path)
    let srcMod = sourceAttrs[.modificationDate] as? Date
    let dstMod = destAttrs[.modificationDate] as? Date
    check(srcMod != nil && dstMod != nil && abs(srcMod!.timeIntervalSince(dstMod!)) < 1,
          "modification date preserved by the descriptor stamp",
          detail: "\(String(describing: srcMod)) vs \(String(describing: dstMod))")
    check((destAttrs[.posixPermissions] as? NSNumber)?.int16Value == 0o640,
          "POSIX permissions preserved by the descriptor stamp")
    let srcCreated = sourceAttrs[.creationDate] as? Date
    let dstCreated = destAttrs[.creationDate] as? Date
    check(srcCreated != nil && dstCreated != nil && abs(srcCreated!.timeIntervalSince(dstCreated!)) < 1,
          "creation date preserved by the descriptor stamp")
    check(!fm.fileExists(atPath: dest.appendingPathComponent("._clip.mxf").path),
          "no AppleDouble '._' twin written alongside the copy")
}

print("== Time estimator ==")
do {
    // Recover a known cost model from synthetic observations: 200 MB/s and 10 ms per file.
    var estimator = TransferEstimator()
    let bytesPerSecond = 200.0 * 1024 * 1024
    let perFile = 0.010
    for size in [Int64(4 << 10), Int64(64 << 10), Int64(8 << 20), Int64(256 << 20)] {
        for _ in 0..<12 {
            estimator.record(phase: .copy, bytes: size,
                             seconds: Double(size) / bytesPerSecond + perFile)
        }
    }
    let fittedRate = estimator.bytesPerSecond(.copy)
    let fittedFixed = estimator.secondsPerFile(.copy)
    check(abs(fittedRate - bytesPerSecond) / bytesPerSecond < 0.05,
          "fit recovers throughput within 5%",
          detail: String(format: "%.1f MB/s vs %.1f MB/s", fittedRate / 1_048_576, bytesPerSecond / 1_048_576))
    check(abs(fittedFixed - perFile) < 0.003,
          "fit recovers per-file cost",
          detail: String(format: "%.4f s vs %.4f s", fittedFixed, perFile))

    // The whole point: a run of tiny files must not collapse the estimate for the big ones.
    let manySmall = estimator.secondsRemaining(copyBytes: 0, copyFiles: 1000,
                                               verifyBytes: 0, verifyFiles: 0)
    check(abs(manySmall - 1000 * perFile) < 2,
          "1,000 empty files cost per-file time, not zero",
          detail: String(format: "%.1f s", manySmall))
    let oneBig = estimator.secondsRemaining(copyBytes: 10 << 30, copyFiles: 1,
                                            verifyBytes: 0, verifyFiles: 0)
    let expectedBig = Double(10 << 30) / bytesPerSecond
    check(abs(oneBig - expectedBig) / expectedBig < 0.06,
          "a 10 GiB file is costed from throughput",
          detail: String(format: "%.1f s vs %.1f s", oneBig, expectedBig))

    check(estimator.secondsRemaining(copyBytes: 0, copyFiles: 0,
                                     verifyBytes: 0, verifyFiles: 0) == 0,
          "no work remaining means no time remaining")

    let restored = TransferEstimator(restoring: estimator.snapshot)
    check(abs(restored.bytesPerSecond(.copy) - fittedRate) / fittedRate < 0.02,
          "snapshot round-trips the fitted throughput")

    // A degenerate fit must not produce a negative prediction.
    var flat = TransferEstimator()
    for _ in 0..<40 { flat.record(phase: .copy, bytes: 1 << 20, seconds: 0.001) }
    check(flat.secondsRemaining(copyBytes: 1 << 30, copyFiles: 10,
                                verifyBytes: 1 << 30, verifyFiles: 10) >= 0,
          "same-sized observations never yield a negative estimate")
}

print("== Time remaining reads as a countdown, not a stopwatch ==")
do {
    check(TimeRemaining.describe(12) == "less than a minute", "under 90 s is not given in seconds")
    check(TimeRemaining.describe(0) == "almost done", "zero reads as almost done")
    check(TimeRemaining.describe(-5) == "almost done", "a negative estimate degrades gracefully")
    check(TimeRemaining.describe(.infinity) == "almost done", "a non-finite estimate degrades gracefully")
    // Rounding must be coarse enough that a ticking clock does not redraw every second.
    let a = TimeRemaining.describe(20 * 60 + 5)
    let b = TimeRemaining.describe(20 * 60 + 25)
    check(a == b, "two readings 20 s apart round to the same 20-minute display",
          detail: "\(a) vs \(b)")
    let hourish = TimeRemaining.describe(3600 + 40)
    check(!hourish.contains("s") || hourish.contains("hr") || hourish.contains("min"),
          "hour-scale estimates never show seconds", detail: hourish)
}

print("== Progress spans copy and verification ==")
do {
    final class ProgressRecorder: TransferEngineDelegate {
        var readings: [TransferProgress] = []
        var sawVerifyPhaseCallback = false
        func engineDidUpdate(item: FileItem, at index: Int) async {}
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineDidUpdateProgress(_ progress: TransferProgress) async { readings.append(progress) }
        func engineDidBeginVerificationPhase(fileCount: Int, totalBytes: Int64) async {
            sawVerifyPhaseCallback = true
        }
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .overwrite, applyToAll: true)
        }
    }

    let src = try makeTempDir("prog-src")
    var total: Int64 = 0
    for i in 0..<6 {
        let u = src.appendingPathComponent("f\(i).bin")
        try randomData(400_000).write(to: u)
        total += 400_000
    }

    for policy in [VerificationPolicy.perFile, .afterAll] {
        let dest = try makeTempDir("prog-dest-\(policy.rawValue)")
        let recorder = ProgressRecorder()
        let plan = SourceScanner.scan(sources: [src])
        _ = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                       destinationRoot: dest, verification: policy,
                                       delegate: recorder)
        let readings = recorder.readings
        check(!readings.isEmpty, "\(policy.rawValue): progress was reported")
        guard let last = readings.last else { break }
        check(last.workTotal == total * 2,
              "\(policy.rawValue): work total counts the copy and the read-back",
              detail: "\(last.workTotal) vs \(total * 2)")
        check(last.dataTotal == total,
              "\(policy.rawValue): data total counts bytes written once")
        check(last.fraction == 1.0, "\(policy.rawValue): progress finishes at 100%",
              detail: String(format: "%.4f", last.fraction))
        var monotonic = true
        for (previous, next) in zip(readings, readings.dropFirst()) where next.workDone < previous.workDone {
            monotonic = false
        }
        check(monotonic, "\(policy.rawValue): progress never goes backwards")
        if policy == .afterAll {
            check(recorder.sawVerifyPhaseCallback, "afterAll: verification phase announced")
        }
    }

    // Verification off: there is no read-back, so work is just the copy.
    let dest = try makeTempDir("prog-dest-off")
    let recorder = ProgressRecorder()
    _ = await TransferEngine().run(plan: SourceScanner.scan(sources: [src]), mode: .copy,
                                   algorithm: .sha256, destinationRoot: dest,
                                   verification: .off, delegate: recorder)
    check(recorder.readings.last?.workTotal == total,
          "verification off: work total is the copy alone")
    check(recorder.readings.last?.fraction == 1.0, "verification off: progress finishes at 100%")
}

print("== Legacy delegates keep working ==")
do {
    // A delegate that only implements the original byte callback must still be driven by the
    // protocol extension, or every existing integration silently goes quiet.
    final class LegacyDelegate: TransferEngineDelegate {
        var lastBytes: Int64 = -1
        var lastTotal: Int64 = -1
        func engineDidUpdate(item: FileItem, at index: Int) async {}
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {
            lastBytes = bytesDone
            lastTotal = totalBytes
        }
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
    }
    let src = try makeTempDir("legacy-src")
    try randomData(500_000).write(to: src.appendingPathComponent("a.bin"))
    let dest = try makeTempDir("legacy-dest")
    let legacy = LegacyDelegate()
    _ = await TransferEngine().run(plan: SourceScanner.scan(sources: [src]), mode: .copy,
                                   algorithm: .sha256, destinationRoot: dest,
                                   verification: .perFile, delegate: legacy)
    check(legacy.lastTotal == 500_000, "legacy overall callback still receives the data total",
          detail: "\(legacy.lastTotal)")
    check(legacy.lastBytes == 500_000, "legacy overall callback reaches 100%",
          detail: "\(legacy.lastBytes)")
}

// ============================================================
print("== Progress updates arrive in order, even on a slow delegate ==")
await {
    /// Delegate that is deliberately slow and records the ORDER of what it receives.
    ///
    /// Slowness is the point. The pump has three callers that can start a delivery pass —
    /// its own timer, `flush()` at a phase boundary, and `shutdown()` — and each pass awaits
    /// this delegate once per file. When the delegate is quick, passes rarely overlap and
    /// the bug this guards against stays hidden; in the real app the delegate is the main
    /// actor with SwiftUI on it, which is anything but quick.
    final class SlowRecordingDelegate: TransferEngineDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lastStatus: [Int: ItemStatus] = [:]
        private(set) var reopenedAfterTerminal: [Int] = []

        func engineDidUpdate(item: FileItem, at index: Int) async {
            try? await Task.sleep(nanoseconds: 300_000)
            lock.withLock {
                let previous = lastStatus[index]
                let wasTerminal = previous == .done || previous == .doneNoVerify
                    || previous == .failed || previous == .skipped
                let nowTerminal = item.status == .done || item.status == .doneNoVerify
                    || item.status == .failed || item.status == .skipped
                if wasTerminal && !nowTerminal { reopenedAfterTerminal.append(index) }
                lastStatus[index] = item.status
            }
        }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
        func engineDidUpdateProgress(_ progress: TransferProgress) async {}
    }

    let src = try! makeTempDir("order-src")
    for i in 0..<40 {
        try! randomData(120_000).write(to: src.appendingPathComponent(String(format: "f%03d.bin", i)))
    }
    let dest = try! makeTempDir("order-dest")
    let plan = SourceScanner.scan(sources: [src])
    let delegate = SlowRecordingDelegate()
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, verification: .perFile,
                                             delegate: delegate)

    check(summary.succeeded == plan.items.count && summary.failed == 0,
          "slow-delegate run completed cleanly",
          detail: "succeeded \(summary.succeeded)/\(plan.items.count), failed \(summary.failed)")
    check(delegate.reopenedAfterTerminal.isEmpty,
          "no file goes backwards from a finished state",
          detail: "re-opened indices \(delegate.reopenedAfterTerminal)")
    let settled = delegate.lastStatus.values.filter { $0 == .done }.count
    check(settled == plan.items.count,
          "every file's LAST delivered status is the finished one",
          detail: "\(settled)/\(plan.items.count) ended .done; "
                + "stragglers \(delegate.lastStatus.filter { $0.value != .done })")
}()

// ============================================================
print("== A delivery pass reaches the delegate as one batch ==")
await {
    /// Records the shape of the hand-off, not just its contents: how many times the delegate
    /// was called, and how many file updates arrived per call.
    ///
    /// The point of the batch callback is that one call carries a whole pass. Each call is a
    /// hop onto the delegate's actor, and when that actor is the main one with a run loop on
    /// it, a hop costs a display frame — so a 1,200-file job delivered one update per call
    /// spent 57 s doing 0.2 s of work, and reported "copying" for most of a minute after the
    /// bytes had landed. This delegate is deliberately slow, like a real UI, so that updates
    /// pile up between passes and the batching is actually exercised.
    final class BatchRecordingDelegate: TransferEngineDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var updates = 0
        private(set) var largestBatch = 0
        private(set) var singleItemCalls = 0
        private(set) var outOfOrder: [Int] = []
        private var lastStatus: [Int: ItemStatus] = [:]

        func engineDidUpdate(batch: [ItemUpdate]) async {
            try? await Task.sleep(nanoseconds: 8_000_000) // a slow delegate, like the main actor
            lock.withLock {
                calls += 1
                updates += batch.count
                largestBatch = max(largestBatch, batch.count)
                for update in batch {
                    let previous = lastStatus[update.index]
                    let wasTerminal = previous == .done || previous == .doneNoVerify
                        || previous == .failed || previous == .skipped
                    let nowTerminal = update.item.status == .done || update.item.status == .doneNoVerify
                        || update.item.status == .failed || update.item.status == .skipped
                    if wasTerminal && !nowTerminal { outOfOrder.append(update.index) }
                    lastStatus[update.index] = update.item.status
                }
            }
        }

        /// Must never be reached: the pump delivers through the batch callback, so anything
        /// arriving here means delivery went back to one hop per file.
        func engineDidUpdate(item: FileItem, at index: Int) async {
            lock.withLock { singleItemCalls += 1 }
        }
        func engineDidUpdateOverall(bytesDone: Int64, totalBytes: Int64) async {}
        func engineResolveConflict(item: FileItem, existingURL: URL) async -> ConflictResolution {
            ConflictResolution(choice: .skip, applyToAll: true)
        }
        func engineDidUpdateProgress(_ progress: TransferProgress) async {}

        var settledCount: Int { lock.withLock { lastStatus.values.filter { $0 == .done }.count } }
    }

    let src = try! makeTempDir("batch-src")
    for i in 0..<600 {
        try! randomData(20_000).write(to: src.appendingPathComponent(String(format: "b%03d.bin", i)))
    }
    let dest = try! makeTempDir("batch-dest")
    let plan = SourceScanner.scan(sources: [src])
    let delegate = BatchRecordingDelegate()
    let summary = await TransferEngine().run(plan: plan, mode: .copy, algorithm: .sha256,
                                             destinationRoot: dest, verification: .perFile,
                                             delegate: delegate)

    check(summary.succeeded == plan.items.count && summary.failed == 0,
          "batched run completed cleanly",
          detail: "succeeded \(summary.succeeded)/\(plan.items.count), failed \(summary.failed)")
    check(delegate.singleItemCalls == 0,
          "the pump delivers through the batch callback, not one hop per file",
          detail: "\(delegate.singleItemCalls) single-item call(s)")
    check(delegate.updates >= plan.items.count,
          "every file was reported at least once",
          detail: "\(delegate.updates) updates for \(plan.items.count) files")
    check(delegate.largestBatch > 1,
          "passes really do carry more than one file",
          detail: "largest batch \(delegate.largestBatch)")
    // The ratio is the whole point: hops are what cost, so there must be far fewer of them
    // than there are updates. Four is a loose floor — the app measured ~190 updates per call.
    check(delegate.calls * 4 <= delegate.updates,
          "far fewer delegate hops than file updates",
          detail: "\(delegate.calls) calls for \(delegate.updates) updates "
                + "(\(delegate.updates / max(delegate.calls, 1)) per call)")
    check(delegate.outOfOrder.isEmpty,
          "batching keeps updates in order — no file goes backwards from a finished state",
          detail: "re-opened indices \(delegate.outOfOrder)")
    check(delegate.settledCount == plan.items.count,
          "every file's last delivered status is the finished one",
          detail: "\(delegate.settledCount)/\(plan.items.count) ended .done")
}()

// ============================================================
print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
