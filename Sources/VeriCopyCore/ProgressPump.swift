import Foundation

/// Decouples the copy loop from the delegate.
///
/// Every delegate callback is `async`, and in the app the delegate lives on the main actor — so
/// `await delegate.engineDidUpdate(…)` from inside the copy loop means the engine stops copying
/// until the main thread is free. Measured on 3,000 small files, routing updates through an idle
/// main actor cost 29%; with the main actor also diffing a SwiftUI list it cost 47%.
///
/// So the copy loop no longer awaits anything for progress. It calls `record(…)`, which takes a
/// lock, stores, and returns; a separate task drains the accumulated state to the delegate about
/// fifteen times a second. Updates coalesce, but never across a status change — the stats view
/// derives its read/write throughput from the sequence of phase transitions, and a file that
/// copied and verified inside one drain window still reports both.
final class ProgressPump: @unchecked Sendable {

    /// How often the pump looks at the queue.
    private static let tick: UInt64 = 15_000_000 // ~66 Hz

    /// How often *routine* byte-progress is delivered. Status changes ignore this and go out
    /// on the next tick: a file that copies and verifies in 40 ms must still be seen doing
    /// both, and there are only a handful of them per file, against hundreds of progress
    /// updates. Coalescing the cheap-to-lose updates is the point; losing a phase is not.
    private static let progressInterval: TimeInterval = 1.0 / 15.0

    /// Past this many queued updates, coalesce by file instead of by file-and-status. Only
    /// reachable when the delegate cannot keep up with a very fast small-file copy; losing
    /// intermediate phases there beats letting the queue grow without bound.
    private static let softCap = 4096

    private let delegate: TransferEngineDelegate
    private let lock = NSLock()
    private var queue: [ItemUpdate] = []
    private var lastPosition: [Int: Int] = [:]
    private var pending: TransferProgress?
    private var task: Task<Void, Never>?
    /// The status each file was last shown as, so a change can be spotted at record time.
    private var lastDelivered: [Int: ItemStatus] = [:]
    private var hasStatusChange = false
    private var lastProgressDelivery = Date.distantPast
    /// True while a delivery pass is running. See `drain()`.
    private var isDraining = false

    init(delegate: TransferEngineDelegate) {
        self.delegate = delegate
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tick)
                guard let self, !Task.isCancelled else { return }
                // Skips rather than queues when a pass is already running: the pass in
                // flight will take whatever this tick would have, and piling up one waiting
                // task per 15 ms tick would make the pump the bottleneck on a large job.
                if self.isDrainDue() { await self.drain(waitForTurn: false) }
            }
        }
    }

    /// Synchronous. Safe to call from the copy loop between chunks.
    func record(item: FileItem, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        if lastDelivered[index] != item.status { hasStatusChange = true }
        if let position = lastPosition[index], position < queue.count,
           queue[position].index == index,
           queue[position].item.status == item.status || queue.count >= Self.softCap {
            queue[position].item = item
        } else {
            queue.append(ItemUpdate(index: index, item: item))
            lastPosition[index] = queue.count - 1
        }
    }

    /// True when there is a phase change waiting, or enough time has passed for a routine
    /// progress refresh.
    private func isDrainDue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasStatusChange { return true }
        guard !queue.isEmpty || pending != nil else { return false }
        return Date().timeIntervalSince(lastProgressDelivery) >= Self.progressInterval
    }

    /// Synchronous. Overall progress only ever needs its most recent value.
    func record(progress: TransferProgress) {
        lock.lock()
        pending = progress
        lock.unlock()
    }

    /// Delivers everything queued so far and waits for the delegate to take it. Used at points
    /// where the UI must be consistent before something else happens — a conflict prompt, a
    /// phase change, the end of the job.
    func flush() async {
        await drain(waitForTurn: true)
    }

    /// Final flush, then stops the pump.
    ///
    /// The in-flight drain is awaited, not just cancelled. `drain()` awaits the delegate, and
    /// in the app that delegate is on the main actor — so when the main actor is busy (SwiftUI
    /// diffing the file list), a drain that started moments before the job ended can still be
    /// waiting its turn here. Returning without it meant those
    /// deliveries landed after `QueueViewModel` had already torn the run down and cleared
    /// `currentJob`, which drops them: the last file stayed stuck showing "Verifying…" even
    /// though the engine had finished and verified it. Shutdown has to mean everything was
    /// delivered, not merely that nothing new will be queued.
    func shutdown() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        await drain(waitForTurn: true)
    }

    /// Synchronous by design: taking a lock inside an async function is a Swift 6 error, and
    /// there is no reason to hold it across the delegate calls anyway.
    private func takeAll() -> (items: [ItemUpdate], progress: TransferProgress?) {
        lock.lock()
        defer { lock.unlock() }
        let taken = queue
        let progress = pending
        for entry in taken {
            switch entry.item.status {
            case .pending, .copying, .verifying, .copied:
                lastDelivered[entry.index] = entry.item.status
            case .done, .doneNoVerify, .skipped, .failed:
                // Terminal: nothing more will be reported for this file, so stop tracking it.
                lastDelivered.removeValue(forKey: entry.index)
            }
        }
        queue.removeAll(keepingCapacity: true)
        lastPosition.removeAll(keepingCapacity: true)
        pending = nil
        hasStatusChange = false
        lastProgressDelivery = Date()
        return (taken, progress)
    }

    /// Delivers queued updates, strictly one pass at a time.
    ///
    /// `takeAll()` is atomic, but what follows it is not: a pass awaits the delegate, and in
    /// the app that delegate is on the main actor. Three callers can start a pass
    /// — the background task, `flush()` at a phase boundary, and `shutdown()` — and two of
    /// them overlapping meant their awaits interleaved however the main actor happened to
    /// resume them. Updates then reached the delegate out of order, and a stale `.copying`
    /// landing after the `.done` for the same file left it stuck mid-phase for the rest of
    /// the run: the file list showed "Copying…" on a file that had finished and verified,
    /// and anything counting finished files came up short.
    ///
    /// Allowing only one pass at a time restores FIFO delivery. The timer skips its tick
    /// when a pass is already running (that pass will take whatever the tick would have),
    /// while `flush()` and `shutdown()` wait their turn because they must guarantee
    /// everything queued has actually been handed over before they return.
    private func drain(waitForTurn: Bool) async {
        while true {
            if claimPass() { break }
            guard waitForTurn else { return }   // ticker: skip, the running pass covers it
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await deliverOnce()
        lock.withLock { isDraining = false }
    }

    private func claimPass() -> Bool {
        lock.withLock {
            if isDraining { return false }
            isDraining = true
            return true
        }
    }

    private func deliverOnce() async {
        let (items, progress) = takeAll()
        if !items.isEmpty {
            await delegate.engineDidUpdate(batch: items)
        }
        if let progress {
            await delegate.engineDidUpdateProgress(progress)
        }
    }
}
