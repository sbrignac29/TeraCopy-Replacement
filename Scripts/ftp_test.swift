// End-to-end test of the built-in FTP server, compiled against the real app sources by
// Scripts/run_ftp_test.sh. Starts the server on loopback and drives it with the system
// `curl` — exercising the actual socket path, both passive AND active data modes, the
// atomic .vcpart upload, checksum verification, and the auth/path-traversal guards.

import Foundation
import VeriCopyCore

@main
struct FTPTest {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String, detail: String = "") {
        if condition {
            print("  PASS  \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    /// Collects server callbacks so the test can assert on what the UI would have shown.
    @MainActor
    final class Recorder: FTPServerDelegate {
        var received: [ReceivedFile] = []
        var started = false
        var stopped = false
        var logs: [String] = []
        func ftpServerDidStart(port: UInt16) { started = true }
        func ftpServerDidStop(reason: String?) { stopped = true }
        func ftpServerDidUpdateClient(_ description: String?) {}
        func ftpServerDidReceive(_ file: ReceivedFile) { received.append(file) }
        func ftpServerDidLog(_ line: String) { logs.append(line) }
    }

    /// Runs curl and returns (exitCode, combined output).
    static func curl(_ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func shasum(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return out.split(separator: " ").first.map(String.init)
    }

    static func main() async {
        print("== FTP server end-to-end (real sockets, driven by curl) ==")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vericopy-ftptest-\(UUID().uuidString)")
        let root = base.appendingPathComponent("receive")
        let sourceDir = base.appendingPathComponent("source")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // A realistic payload: a few MB of random bytes, like a RAW frame.
        let sample = sourceDir.appendingPathComponent("DSC_0001.CR3")
        var payload = Data(count: 5 * 1024 * 1024)
        payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try! payload.write(to: sample)
        let expectedHash = shasum(sample)

        let port: UInt16 = 2121
        let user = "camera"
        let password = "s3cret"
        let settings = FTPSettings(port: port, username: user, lanOnly: true,
                                   overwriteExisting: false, algorithm: .sha256)

        let recorder = await MainActor.run { Recorder() }
        let server = await MainActor.run {
            FTPServer(settings: settings, password: password, root: root, delegate: recorder)
        }
        if let error = server.start() {
            print("  FAIL  server did not start — \(error)")
            print("\n1 FTP TEST(S) FAILED")
            exit(1)
        }
        defer { server.stop() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(server.isRunning, "server is listening on port \(port)")

        let baseURL = "ftp://127.0.0.1:\(port)"

        // 1. Passive-mode upload (curl's default) — the common camera path.
        let (rc1, out1) = curl(["-sS", "--ftp-pasv", "-T", sample.path,
                                "--user", "\(user):\(password)", "\(baseURL)/"])
        check(rc1 == 0, "passive-mode upload succeeded", detail: out1)
        let landed = root.appendingPathComponent("DSC_0001.CR3")
        check(fm.fileExists(atPath: landed.path), "uploaded file exists at destination")
        check(fm.contentsEqual(atPath: sample.path, andPath: landed.path),
              "uploaded file is byte-identical to the source")

        // The checksum the server computed must match an INDEPENDENT tool's view of the file.
        let recorded = await MainActor.run { recorder.received.first }
        check(recorded?.checksum == expectedHash,
              "server's checksum matches independent shasum",
              detail: "server=\(recorded?.checksum ?? "nil") shasum=\(expectedHash ?? "nil")")
        check(recorded?.verified == true, "file reported as verified after read-back")

        // 2. No partial files left behind.
        let leftovers = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.contains(".vcpart") }
        check(leftovers.isEmpty, "no .vcpart temporaries left behind", detail: "\(leftovers)")

        // 3. Active mode (PORT) — many cameras default to this, so it must work too.
        let sample2 = sourceDir.appendingPathComponent("DSC_0002.CR3")
        try! payload.write(to: sample2)
        let (rc2, out2) = curl(["-sS", "-P", "-", "-T", sample2.path,
                                "--user", "\(user):\(password)", "\(baseURL)/"])
        check(rc2 == 0, "ACTIVE-mode (PORT) upload succeeded", detail: out2)
        check(fm.contentsEqual(atPath: sample2.path,
                               andPath: root.appendingPathComponent("DSC_0002.CR3").path),
              "active-mode upload is byte-identical")

        // 4. Wrong password must be refused, and must not create a file.
        let sample3 = sourceDir.appendingPathComponent("SECRET.CR3")
        try! Data("nope".utf8).write(to: sample3)
        let (rc3, _) = curl(["-sS", "--ftp-pasv", "-T", sample3.path,
                             "--user", "\(user):wrongpassword", "\(baseURL)/"])
        check(rc3 != 0, "wrong password is rejected")
        check(!fm.fileExists(atPath: root.appendingPathComponent("SECRET.CR3").path),
              "no file is written when auth fails")

        // 5. Collision handling: a second upload of the same name must NOT clobber.
        let (rc5, _) = curl(["-sS", "--ftp-pasv", "-T", sample.path,
                             "--user", "\(user):\(password)", "\(baseURL)/"])
        check(rc5 == 0, "second upload of the same name succeeds")
        check(fm.fileExists(atPath: root.appendingPathComponent("DSC_0001 2.CR3").path),
              "collision produced a renamed file rather than overwriting")
        check(fm.contentsEqual(atPath: sample.path, andPath: landed.path),
              "the ORIGINAL file was left untouched by the collision")

        // 6. Directory creation, as cameras do for dated folders.
        let (rc6, out6) = curl(["-sS", "--ftp-pasv", "--ftp-create-dirs",
                                "-T", sample.path, "--user", "\(user):\(password)",
                                "\(baseURL)/2026-08-05/frame.CR3"])
        check(rc6 == 0, "upload into a new subfolder succeeds", detail: out6)
        check(fm.fileExists(atPath: root.appendingPathComponent("2026-08-05/frame.CR3").path),
              "camera-style dated folder was created and used")

        // 7. Path traversal over the wire must not escape the receive folder.
        let escapeTarget = base.appendingPathComponent("escaped.CR3")
        let (_, _) = curl(["-sS", "--ftp-pasv", "-T", sample.path,
                           "--user", "\(user):\(password)",
                           "\(baseURL)/../escaped.CR3"])
        check(!fm.fileExists(atPath: escapeTarget.path),
              "REJECT: '..' upload did not escape the receive folder")

        // 8. Directory listing works (cameras probe it).
        let (rc8, out8) = curl(["-sS", "--ftp-pasv", "--user", "\(user):\(password)", "\(baseURL)/"])
        check(rc8 == 0 && out8.contains("DSC_0001.CR3"),
              "directory listing returns uploaded files", detail: out8.prefix(200).description)

        // 9. Clean shutdown releases the port.
        server.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(!server.isRunning, "server reports stopped")
        let (rcDead, _) = curl(["-sS", "--connect-timeout", "2", "--ftp-pasv",
                                "--user", "\(user):\(password)", "\(baseURL)/"])
        check(rcDead != 0, "port refuses connections after stop")

        print("")
        print(failures == 0 ? "ALL FTP TESTS PASSED" : "\(failures) FTP TEST(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
