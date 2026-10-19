# VeriCopy Local API

A small HTTP API so another program on this Mac — the SSD Offload Dashboard — can start
verified copies and moves and watch them finish.

```
Base URL   http://127.0.0.1:8787
```

**Use `127.0.0.1`, not `localhost`.** The server binds the IPv4 loopback address. A JVM
resolving `localhost` may try the IPv6 loopback (`::1`) first, where nothing is listening,
giving you a connection refused or a slow retry. Writing the address literally avoids the
whole question.

> **Changed since the first version.** The status `copied_unverified` is now
> `completed_unverified`, because it no longer only means "copied". `POST /api/jobs` takes
> an optional `mode`, and job records carry two new fields, `mode` and `filesUnverified`.
> A caller that omits `mode` keeps copying exactly as before.

## What it can and cannot do

The API copies, and — when you ask it to with `"mode": "move"` — moves.

- **It never overwrites.** If the folder the source would land as already exists at the
  destination, the request is refused with `409 destination_exists`. Nothing is merged, for
  a copy or a move.
- **A move deletes the source, and only after the copy is proven good.** Across drives,
  each file is copied, read back, checksum-compared, and only then is that one source file
  deleted. A file is never removed on the strength of a write that was not verified.
- **It only touches allowed folders.** Both `source` and `destination` must sit inside a
  root listed in the config file (below). Anything else is `403 path_not_allowed`.
- **Moves can be switched off entirely.** Set `"allowMove": false` in the config and the
  API is copy-only again, no rebuild needed.
- **It is not on your network.** The listener is bound to `127.0.0.1`. Nothing off this Mac
  can reach it, and there is no authentication because nothing remote can connect.
- **It refuses browsers.** Any request carrying an `Origin` header is rejected with `403`,
  and `POST /api/jobs` requires `Content-Type: application/json` (which forces a CORS
  preflight this server never answers). Together these stop a web page the user happens to
  be visiting from driving their drives. Call the API from your Java backend, server to
  server — not from page JavaScript. No CORS headers are sent, by design.
- **VeriCopy must be running.** It is a desktop app; the API answers only while it is open.
  It starts automatically when VeriCopy launches and can be turned off in Settings ▸ API.

Jobs created over the API appear in the VeriCopy window like any other job, and can be
watched, paused or cancelled there.

## Configuration

`~/Library/Application Support/VeriCopy/api-config.json`, written with defaults on first
launch:

```json
{
  "allowMove" : true,
  "allowedRoots" : [
    "/Volumes/BRIGSMEDIA",
    "/Volumes/BRIGSMEDIA LIBRARY",
    "/Volumes/Expansion/BRIGSMEDIA ARCHIVE",
    "/Users/spencerbrignac/VeriCopyAPITest"
  ],
  "enabled" : true,
  "port" : 8787
}
```

**The config is read when VeriCopy launches.** After editing, press **Reload Config** in
Settings ▸ API, or restart the app — otherwise the old values stay in effect.

The last allowed root is a scratch folder for trying the API out; delete that line when you
are done testing.

A path is matched component by component, so `/Volumes/BRIGSMEDIA` does **not** grant access
to `/Volumes/BRIGSMEDIA LIBRARY` or `/Volumes/BRIGSMEDIAX` — each drive needs its own entry.
Symlinks are resolved before the check, so a link inside an allowed folder cannot point out
of it.

If a drive is not plugged in, requests naming it fail with `400 path_not_found` rather than
anything destructive. Settings ▸ API marks unmounted roots in orange.

---

## Routes

### `GET /api/health`

```json
{ "ok": true, "version": "1.0", "queueActive": false }
```

Always `200` while VeriCopy is running. `queueActive` is true while any job is transferring.

### `POST /api/jobs`

Request — both paths absolute, both inside an allowed root:

```json
{
  "source": "/Volumes/BRIGSMEDIA/Shoot_041",
  "destination": "/Volumes/Expansion/BRIGSMEDIA ARCHIVE",
  "mode": "move"
}
```

| Field | Required | Notes |
|---|---|---|
| `source` | yes | A file or a folder |
| `destination` | yes | A folder that must already exist |
| `mode` | no | `"copy"` (the default when absent) or `"move"` |

Response — `202 Accepted`:

```json
{ "jobId": "5584C666-76CC-438B-991D-D8561E4E4CD6" }
```

The source lands at `destination/<source name>` — the example above produces
`/Volumes/Expansion/BRIGSMEDIA ARCHIVE/Shoot_041`. The `destination` itself must already
exist; the folder inside it must not.

**This request can take a few seconds.** The source tree is scanned before the response is
sent, so that an unreadable or empty source is an honest `400` now rather than a job that
mysteriously fails later. A very large archive may take longer than your HTTP client's
default read timeout — set one generously (30 s is ample).

The job is queued immediately and starts as soon as the queue reaches it.

#### What `"mode": "move"` does

- **Across drives** (SSD → Done HDD, say): copy the file, read it back off the destination
  with the disk cache bypassed, compare checksums, and only then delete that source file.
  Verification is not optional on this path and cannot be turned off over HTTP. The job
  finishes `verified`.
- **Within one drive**: an instant rename. No bytes are rewritten, so there is no copy for
  a checksum to compare and the job finishes `completed_unverified`, with `filesUnverified`
  equal to the number of files renamed. This is not a weaker guarantee than a verified copy
  — the data was never touched — but it is a different one, and the API says so rather than
  claiming a checksum match that never happened.
- Empty source folders are removed once their contents have moved.

Two guards apply only to moves, because only a move deletes anything:

- The source cannot be an allowed root itself (`403 cannot_move_root`) — "move
  `/Volumes/BRIGSMEDIA`" would try to empty the drive.
- The folder containing the source must be writable (`403 source_not_writable`), since the
  move has to delete from it. Better an upfront refusal than a half-finished move.

### `GET /api/jobs/:id`

The full status of one job — this is what you poll.

```json
{
  "jobId": "5584C666-76CC-438B-991D-D8561E4E4CD6",
  "name": "Shoot_041",
  "origin": "api",
  "mode": "move",
  "status": "verifying",
  "sources": ["/Volumes/BRIGSMEDIA/Shoot_041"],
  "destination": "/Volumes/Expansion/BRIGSMEDIA ARCHIVE",
  "progress": 0.62,
  "bytesCopied": 41203400704,
  "bytesTotal": 66204891136,
  "filesTotal": 1204,
  "filesCopied": 760,
  "filesVerified": 742,
  "filesFailed": 0,
  "filesUnverified": 0,
  "startedAt": "2026-10-15T23:19:53Z",
  "finishedAt": null,
  "secondsRemaining": 412,
  "fatalError": null,
  "failedFiles": []
}
```

| Field | Notes |
|---|---|
| `origin` | `"api"` for jobs you created, `"ui"` for jobs built in the window |
| `mode` | `"copy"`, `"move"` or `"verify"` |
| `progress` | 0.0–1.0, spanning the copy **and** the verification read-back |
| `bytesCopied` / `bytesTotal` | bytes landed at the destination; fits a Java `long` |
| `filesUnverified` | finished but never checksum-compared — same-volume renames, or a UI job run with verification off |
| `secondsRemaining` | estimate, or absent while it is still warming up. The same smoothed countdown the app shows, to the second: it falls by one each second while the estimate holds and only moves faster when the job really has changed pace, so it is safe to poll and display |
| `fatalError` | set when the job could not start at all (no free space, unreadable destination) |
| `failedFiles` | `[{ "path", "message" }]`, populated as files fail |

**Nullable fields are omitted, not sent as `null`.** Jackson and Gson both leave the
corresponding field null, so this needs no handling — just do not expect the key.

### `GET /api/jobs`

```json
{ "jobs": [ { …same shape as above… } ] }
```

All jobs VeriCopy currently holds, newest first, including ones the user built in the
window. The empty draft VeriCopy keeps at the end of its own list is not included. The list
is cleared when VeriCopy quits, and the user can clear finished jobs from the UI — so treat
it as "recent", not as a durable history. Persist anything you need to keep on the dashboard
side.

### `POST /api/jobs/:id/cancel`

No body. Returns `200` with the job's status (same shape as `GET /api/jobs/:id`).

Works whether the job is running or still queued. `409 job_not_cancellable` if the job has
already finished.

**Cancel is a request, not a guarantee** — read the status afterwards rather than assuming.
It stops the job at the next file boundary, so a job that was already finishing will
complete normally and report `verified`. Small jobs finish fast enough that this is a real
possibility; the status you read back is the authority on what happened.

What a cancel leaves behind:

- **Copy**: files already copied stay. The file in flight is discarded — its data goes to a
  hidden `.vcpart` that is cleaned up, so the destination never holds a half-written file.
  Verified in testing: zero leftover files and zero `.vcpart` after cancelling a copy.
- **Move**: files already moved stay moved and their sources are gone; files not yet reached
  are untouched at the source. Because a source is only ever deleted after its copy
  verifies, no file ends up in neither place. Expect a partial move and re-issue for the
  remainder — re-running against the same destination will be refused with
  `409 destination_exists`, so move the remaining files into a fresh destination folder.

---

## Status values

| `status` | Meaning |
|---|---|
| `queued` | Created, waiting its turn. One job runs at a time. |
| `copying` | Data is being written to the destination. |
| `verifying` | Data is being read back off the disk and re-hashed. |
| `verified` | **Every file** transferred and its checksum matched on read-back. |
| `failed` | At least one file failed, or the job could not start. See `failedFiles` / `fatalError`. |
| `cancelled` | Stopped by `POST /cancel`, or by the user in the window. |
| `completed_unverified` | Finished successfully, but at least one file was never checksum-compared. |

`verified` is the only status that means the transfer is known good. It requires that
**every** file matched — VeriCopy does not abort a run on one bad file, it isolates it and
keeps going, so a job with one failure finishes as `failed` with the rest of the files
intact.

`completed_unverified` reaches you two ways: a **same-volume move** (renames — nothing was
rewritten, so nothing could be checksummed), or a `origin: "ui"` job the user ran with
verification set to Never. Check `filesUnverified` to see how many files it covers. API
copies always verify.

On a `cancelled` job, trust `status`, `filesVerified` and `bytesCopied`. The `progress`
figure is a display value and can read high on a job that stopped early.

## Errors

Every non-2xx response has the same shape, so you can bind them all to one class:

```json
{ "error": "destination_exists", "message": "…already exists. This API never overwrites…" }
```

Branch on `error`; show `message`. The codes are stable, the prose is not.

| `error` | HTTP | Cause |
|---|---|---|
| `invalid_body` | 400 | Body is not `{ source, destination }` |
| `invalid_mode` | 400 | `mode` was neither `"copy"` nor `"move"` |
| `unsupported_media_type` | 400 | Missing `Content-Type: application/json` |
| `path_not_absolute` | 400 | A path did not start with `/` |
| `path_not_found` | 400 | Path does not exist (drive unplugged?) |
| `path_not_a_directory` | 400 | Destination is a file, not a folder |
| `source_empty` | 400 | Source contains no files |
| `destination_inside_source` | 400 | Would copy a folder into itself |
| `path_not_allowed` | 403 | Outside every allowed root |
| `move_not_allowed` | 403 | `"mode": "move"` while `allowMove` is false |
| `cannot_move_root` | 403 | Tried to move an allowed root itself |
| `source_not_writable` | 403 | A move cannot delete from the source's folder |
| `browser_origin_refused` | 403 | Request carried an `Origin` header |
| `job_not_found` | 404 | No job with that id |
| `not_found` | 404 | No such route |
| `method_not_allowed` | 405 | Right path, wrong HTTP method |
| `destination_exists` | 409 | Target already exists; nothing was touched |
| `job_not_cancellable` | 409 | Job already finished |
| `request_too_large` | 413 | Request body over 64 KB |

## Polling

HTTP cannot push, so the dashboard asks. **Every 1–2 seconds while a job is active** is
plenty.

Stop polling once `status` is `verified`, `failed`, `cancelled` or `completed_unverified`;
those are terminal and will never change.

**What you read is current.** The figures come from VeriCopy's own live state, which now
tracks the work rather than trailing it: progress is delivered to the UI in batches about
fifteen times a second, so a poll is at worst a fraction of a second behind the bytes.
Measured on this machine with 1,200 small files: the files finished landing at 0.8 s and the
API reported `verified` at 1.4 s. The same job run headless, with no window at all, takes
0.7 s — so the window costs well under a second, on any job size.

- **Counts are a reading, not a floor.** `filesCopied` and `filesVerified` are what has
  actually happened, within the polling interval.
- **`finishedAt` is when the job finished.**
- **A cancel takes effect promptly.** `POST /api/jobs/:id/cancel` reaches a terminal status
  in well under a second; on a 5,000-file job it was measured at 0.3 s, with the remaining
  files genuinely not copied.
- **Terminal status and final counts are accurate.** Trust the end state, as before.

If you are reading an older copy of this document: there used to be a large lag here —
roughly 45 seconds on a 1,200-file job, during which counts climbed long after the transfer
was over and a cancel appeared to do nothing. That was a VeriCopy UI issue (each per-file
update was handed to the main thread on its own, costing a display frame apiece) and it is
fixed. Mid-job counts no longer need to be treated as a lower bound.

## Notes for the Java side

- `java.net.http.HttpClient` plus Jackson covers all of this. No special configuration —
  the JSON field names are already camelCase.
- Timestamps are ISO-8601 (`2026-10-15T23:19:53Z`), which `java.time.Instant.parse` reads
  directly.
- Set a generous read timeout on `POST /api/jobs` (see above). The other routes return
  immediately.
- Give your status enum a branch for every value in the table above, including
  `completed_unverified`, so an unmapped value cannot throw.
- There is no compile-time contract between your code and VeriCopy's. This document is the
  contract. `GET /api/health` returns the app version; if it changes, re-read this file.

---

## Trying it from Terminal

The config ships with `~/VeriCopyAPITest` allowed, so you can exercise every route without
going near a real drive. Set up a test tree:

```bash
mkdir -p ~/VeriCopyAPITest/src/nested ~/VeriCopyAPITest/dest ~/VeriCopyAPITest/moved
head -c 300000 /dev/urandom > ~/VeriCopyAPITest/src/photo1.raw
head -c 150000 /dev/urandom > ~/VeriCopyAPITest/src/photo2.raw
echo "notes" > ~/VeriCopyAPITest/src/nested/README.txt
```

Make sure VeriCopy is open, then:

**1 — Is it up?**

```bash
curl -s http://127.0.0.1:8787/api/health
```

**2 — Start a copy.** (Prints the job id and remembers it in `$JOB`.)

```bash
JOB=$(curl -s -X POST http://127.0.0.1:8787/api/jobs -H 'Content-Type: application/json' -d '{"source":"'"$HOME"'/VeriCopyAPITest/src","destination":"'"$HOME"'/VeriCopyAPITest/dest"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["jobId"])'); echo "jobId=$JOB"
```

**3 — Check on it.**

```bash
curl -s http://127.0.0.1:8787/api/jobs/$JOB
```

**4 — Confirm the copy is real, and the source is still there.**

```bash
diff -r ~/VeriCopyAPITest/src ~/VeriCopyAPITest/dest/src && echo "IDENTICAL, source kept"
```

**5 — The no-overwrite rule.** `dest/src` exists now, so repeating step 2 returns
`409 destination_exists`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/api/jobs -H 'Content-Type: application/json' -d '{"source":"'"$HOME"'/VeriCopyAPITest/src","destination":"'"$HOME"'/VeriCopyAPITest/dest"}'
```

**6 — Now a move.** The source folder will be gone afterwards.

```bash
curl -s -X POST http://127.0.0.1:8787/api/jobs -H 'Content-Type: application/json' -d '{"source":"'"$HOME"'/VeriCopyAPITest/dest/src","destination":"'"$HOME"'/VeriCopyAPITest/moved","mode":"move"}'
```

**7 — See what the move did.** Within one drive this is a rename, so expect
`completed_unverified` and a non-zero `filesUnverified`. `dest` is left empty.

```bash
ls ~/VeriCopyAPITest/moved/src && ls ~/VeriCopyAPITest/dest
```

**8 — The allowlist.** A path outside every allowed root returns `403`.

```bash
curl -s -X POST http://127.0.0.1:8787/api/jobs -H 'Content-Type: application/json' -d '{"source":"/etc/hosts","destination":"'"$HOME"'/VeriCopyAPITest/dest"}'
```

**9 — Moving a whole allowed root is refused.** This exact command trips
`destination_inside_source` first, because the destination sits inside the source; point it
at a different drive and you get `cannot_move_root`. Either way it is refused and nothing
is touched.

```bash
curl -s -X POST http://127.0.0.1:8787/api/jobs -H 'Content-Type: application/json' -d '{"source":"'"$HOME"'/VeriCopyAPITest","destination":"'"$HOME"'/VeriCopyAPITest/moved","mode":"move"}'
```

**10 — List recent jobs, and cancel one.**

```bash
curl -s http://127.0.0.1:8787/api/jobs
curl -s -X POST http://127.0.0.1:8787/api/jobs/$JOB/cancel
```

**Paths with spaces** — such as `/Volumes/BRIGSMEDIA LIBRARY` — need no escaping inside the
JSON string, but do keep the shell quoting as shown above.

**Clean up** when you are finished, and delete the `VeriCopyAPITest` line from the config:

```bash
rm -rf ~/VeriCopyAPITest
```
