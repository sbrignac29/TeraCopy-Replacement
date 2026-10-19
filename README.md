# VeriCopy

A stable, native macOS replacement for TeraCopy: copy or move files with real,
read-back checksum verification.

**The app:** `VeriCopy.app` in this folder — double-click to run, or drag it to
`/Applications`.

## Features

- **Job queue.** The sidebar lists copy jobs; each job has its own files,
  destination, mode, and verification settings. Build several jobs, then
  **Start Queue** to run them one after another. Finished jobs stay in the
  list with their complete per-file results — every file still shows its
  verified status and checksum. Jobs can also be run individually, re-run,
  or removed (right-click). **Rename any job** to label what it's copying —
  double-click its name in the sidebar, or right-click ▸ Rename. The label
  also appears in completion notifications.
- **Copy / Move / Verify modes.** Verify mode compares an existing destination
  against the source without writing anything.
- **True verification.** Every file is hashed while it is copied, then the
  destination is re-read from disk with the file-system cache bypassed
  (`F_NOCACHE`) and hashed again. A match means the bytes on disk are right —
  not just the bytes in RAM.
- **Checksum algorithms:** SHA-256 (default), SHA-512, SHA-1, MD5, CRC-32.
- **Verification policy per task.** Choose when copied data is read back and
  checked: **Each file** (verify immediately after each file copies),
  **At end** (copy everything first at full speed, then run one verification
  pass — for moves, each source is deleted only after its copy verifies), or
  **Never**. The read-back pass costs a full re-read of everything written,
  roughly doubling total time on the same disk. Checksums are always computed
  in-flight, so the manifest export works under every policy. The choice is
  remembered between launches.
- **Pipelined I/O.** The next chunk is read from the source while the current
  chunk is hashed and written to the destination (double-buffered, 8 MiB
  chunks, zero per-chunk allocations, contiguous preallocation of the target
  file). Large transfers run at the destination drive's hardware limit.
- **Pause / Resume / Cancel** at any point, with per-file and overall progress,
  live speed, and ETA.
- **Auto-scroll** (checkbox in the footer, on by default): the file list
  follows the transfer, keeping the file currently being copied or verified
  centered and highlighted. Untick it to browse the list freely mid-run.
- **Stats view.** The toggle at the top-right of a job switches between the
  file list and a live dashboard: Copied / Verified / Failed / Waiting
  counters, total bytes read & written, and a read/write speed graph. During
  an end-of-job verification pass you can watch the write line drop to zero
  while the read line carries on — that's the read-back happening.
- **Crash-safe writes.** Data is written to a hidden `.vcpart` partial file and
  renamed into place only when complete, so the destination never holds a
  half-written file. Partials are cleaned up on cancel or error.
- **Per-file error isolation.** One unreadable file is marked failed and the
  queue keeps going — the job never dies because of one bad file.
- **Conflict handling:** Skip / Keep Both / Overwrite, with "apply to all",
  showing size and modification date of both files.
- **Safe moves.** Same-volume moves are instant renames; cross-volume moves
  copy, verify, and only then delete the source. Empty source folders are
  cleaned up afterwards.
- **Metadata preserved:** dates, permissions, extended attributes, ACLs, and
  Finder tags travel with the files (via `copyfile`); symlinks are copied as
  symlinks.
- **Completion notifications.** A macOS banner + sound when a job (or the whole
  queue) finishes — configurable in Settings (⌘,) to fire after each job or only
  when the queue is done, and optionally only on failure. Can also **text you via
  iMessage**: enter a phone number or Apple ID and VeriCopy sends a short summary
  through your Messages app (no passwords stored; macOS asks once for permission
  to control Messages). Notifications are best-effort and fully isolated — a
  failed or denied notification never affects a copy.
- **Receive photos straight from your camera (built-in FTP server).** macOS no longer
  ships an FTP server, so VeriCopy has one. In **Settings ▸ Receive**, pick a folder,
  set a username/password, and press **Start Receiving** — the panel then shows the
  exact address, port and username to type into the camera. Every arriving photo is
  **checksum-verified**: VeriCopy hashes the incoming data, then re-reads the saved file
  from disk (cache bypassed) to confirm it matches. Files stream into a hidden `.vcpart`
  and are only renamed into place when complete, so a dropped WiFi connection never
  leaves a half-written frame. Both **passive and active** FTP modes work (cameras
  differ — if yours won't send, flip that setting first). Name collisions are saved
  alongside rather than overwriting, deletes are refused, connections are restricted to
  your local network, and the password lives in the Keychain. The server **never starts
  on its own** — only when you press Start — and the menu-bar icon changes while it's
  listening. **Create job from received files** hands an ingest straight to the normal
  verified-copy pipeline for a backup in the same pass.
- **Keeps the Mac awake, then sleeps when done.** While a queue is running,
  VeriCopy holds a power assertion so the Mac won't idle-sleep mid-transfer —
  the *display* is still free to turn off, so an overnight copy doesn't burn
  the screen. Verify it any time with
  `pmset -g assertions | grep -i vericopy`; it disappears the moment the
  queue ends. Each job also has a **When done** setting (Do nothing / Sleep
  the Mac / Quit VeriCopy) with a default in Settings ▸ Energy. Before it acts
  you get a floating, cancelable countdown (30 s by default) that appears over
  other apps and wakes the display first. It is **skipped entirely** if the run
  had failures or you stopped the queue — on a failed run VeriCopy tells you it
  didn't sleep rather than hiding the problem behind a dark screen.
- **Menu bar indicator.** VeriCopy adds a small icon to the menu bar — a
  progress ring while a job runs, a plain icon (with a warning glyph if the
  last run had failures) when idle. Click it for a compact panel: live
  progress and speed for the running job with quick Pause/Cancel, or a
  summary of the last finished job, plus Start Queue and Open/Quit shortcuts —
  all without bringing the main window forward.
- **Local API for other apps on this Mac.** VeriCopy answers HTTP on
  `http://127.0.0.1:8787` so another program — a dashboard, a script — can start verified
  copies and moves and poll their status: `POST /api/jobs`, `GET /api/jobs/:id`,
  `GET /api/jobs`, `POST /api/jobs/:id/cancel`, `GET /api/health`. API jobs join the same
  queue as the ones you build in the window and show up there. A request copies by default;
  `"mode": "move"` moves, which across drives copies, verifies and only then deletes each
  source — a file is never removed on the strength of an unverified write. The API **never
  overwrites**: it refuses outright if the destination folder already exists. Source and
  destination must both sit inside an allowlist you keep in
  `~/Library/Application Support/VeriCopy/api-config.json`, where `"allowMove": false`
  makes it copy-only. The listener is bound to the loopback address, so nothing on your
  network can reach it, and requests from browsers are rejected. Turn it off in
  Settings ▸ API. Full reference in [API.md](API.md).
- **Pre-flight free-space check** before a single byte is written.
- **Checksum manifest export** (`.sha256`/`.md5`/… in `shasum` format, `.sfv`
  for CRC-32) after a run. One hash per file: because a verified copy has an
  identical source and destination hash, the single recorded value represents
  both. Files that **failed** verification are omitted (their destination
  doesn't match the recorded hash), and the app tells you how many were left
  out. Files copied with verification off are included but flagged, since only
  the source was hashed. The output is checkable with the standard
  `shasum -c` / `md5sum -c` tools.
- The app blocks idle sleep during a transfer and warns before quitting
  mid-transfer.

## Usage

1. Drag files/folders into the window (or **Add…** / ⌘O).
2. Pick a destination with **Choose…**.
3. Pick mode (Copy / Move / Verify) and checksum algorithm.
4. Hit **Copy**. Watch per-file status: Copying → Verifying → “SHA-256 verified”.

## Building from source

Requires only Xcode Command Line Tools (Swift 6+):

```bash
./Scripts/build_app.sh    # runs the test suite, builds, bundles, signs VeriCopy.app
```

## Testing

The copy engine is UI-independent (`Sources/VeriCopyCore`) and has a headless
test suite covering copy integrity, corruption detection, conflict policies,
same/cross-volume moves, pause/cancel cleanup, and free-space pre-flight:

```bash
swift run -c release vericopy-selftest                          # full check suite
swift run -c release vericopy-selftest --stress                 # + 1,501-file / 256 MB stress run
swift run -c release vericopy-selftest --external "/Volumes/X"  # round-trip test on a real drive
swift run -c release vericopy-selftest --bench ["/Volumes/X"]   # throughput benchmark
./Scripts/run_queue_test.sh                                     # queue sequencing test (app layer)
```
