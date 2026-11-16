import Darwin
import Dispatch
import Foundation

/// How a `UDIFDevice` decodes compressed chunks for `read(at:into:)`: how many decode at
/// once, at what priority, and how far ahead of a sequential reader.
///
/// Staging in the background uses `background` (a couple of decoders, background QoS,
/// throttled disk I/O); Install switches the device to `fast`. A change applies to chunks
/// whose decode hasn't started; decodes already running finish at their old priority.
public struct DecodePolicy: Sendable, Hashable {
    /// Most chunks decoding at once on the whole device, counting both the device's own
    /// workers and reader threads that decode a chunk themselves. At least 1.
    public var maxDecoders: Int
    /// Priority of the device's decode workers. Reader threads decode at their own QoS.
    public var qos: DispatchQoS.QoSClass
    /// How many decoded bytes to prepare ahead of each sequential reader. 0 turns
    /// read-ahead off; a read that spans several chunks still decodes them in parallel.
    public var readAheadBytes: Int
    /// Most decoded bytes the device keeps, if less than its own `cacheLimit`; nil uses
    /// the device's. Background staging keeps less: the cache was the largest single
    /// share of Drop's footprint (`impact-bench.md`, round 2). Shrinking trims at once;
    /// growing again (the boost to `fast`) lets the cache refill as reads come.
    public var cacheBytes: Int?

    /// One core left for the reader and the writer threads.
    public static let defaultMaxDecoders = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    /// Decoders for background staging, from the plan's "gentle in the background" rule.
    public static let backgroundMaxDecoders = 2
    /// Decoders for the `utility` preset: the plan's "2–3 decode threads" upper end.
    public static let utilityMaxDecoders = 3
    /// Enough to keep every decoder busy on 1 MiB chunks and most of them on 4 MiB ones,
    /// while staying inside the read-ahead share of the 64 MiB cache.
    public static let defaultReadAheadBytes = 32 * 1024 * 1024
    /// Read-ahead for the gentle presets. Background staging isn't racing anyone, and its
    /// writers are throttled, so 8 MiB (2 to 8 chunks) keeps its 2–3 decoders busy while
    /// holding a quarter of the memory `fast` does (`impact-bench.md`, round 2).
    public static let backgroundReadAheadBytes = 8 * 1024 * 1024
    /// Decoded-chunk cache for the gentle presets: half the device default. Still four
    /// times the read-ahead, so each of the 4 writer streams keeps its 8 MiB ahead.
    public static let backgroundCacheBytes = 32 * 1024 * 1024

    /// All cores but one, user-initiated: for Install and anything a person waits on.
    public static let fast = DecodePolicy(
        maxDecoders: defaultMaxDecoders, qos: .userInitiated, readAheadBytes: defaultReadAheadBytes)
    /// Two decoders at background QoS, with their disk reads throttled.
    public static let background = DecodePolicy(
        maxDecoders: backgroundMaxDecoders, qos: .background, readAheadBytes: backgroundReadAheadBytes,
        cacheBytes: backgroundCacheBytes)
    /// Three decoders at utility QoS: the default for background staging. They may run on
    /// performance cores (background QoS stays on efficiency cores) but still yield to
    /// user-initiated work; the foreground showed no measurable slowdown, and Docker is
    /// ready 4× sooner than under `background` with half the CPU time
    /// (`.claude/research/impact-bench.md`). Its disk reads get utility QoS's I/O tier,
    /// not an explicit throttle.
    public static let utility = DecodePolicy(
        maxDecoders: utilityMaxDecoders, qos: .utility, readAheadBytes: backgroundReadAheadBytes,
        cacheBytes: backgroundCacheBytes)

    public init(maxDecoders: Int, qos: DispatchQoS.QoSClass, readAheadBytes: Int, cacheBytes: Int? = nil) {
        self.maxDecoders = max(1, maxDecoders)
        self.qos = qos
        self.readAheadBytes = max(0, readAheadBytes)
        self.cacheBytes = cacheBytes.map { max(0, $0) }
    }
}

/// Counters for tests: how often each chunk was decoded on the read path and how many
/// decodes ran at once.
struct DecodeStats: Sendable {
    /// Decodes per chunk index since the last reset.
    var decodes: [Int]
    /// Most decodes running at once, sampled as each decode starts.
    var maxConcurrent = 0
    /// QoS class of the most recent worker decode.
    var lastWorkerQoS: qos_class_t?

    init(chunkCount: Int) { decodes = [Int](repeating: 0, count: chunkCount) }
}

/// The read path's decoded-chunk store and decode pool for one `UDIFDevice`.
///
/// **Cache.** Two kinds of entries share `cacheLimit` bytes:
/// - *Reserved* chunks: queued, decoding or decoded ahead for a reader and not yet read.
///   They are never evicted. Read-ahead may reserve at most `readAheadShare` of the
///   cache across all readers; it stops scheduling when that is full.
/// - The LRU of chunks already read, trimmed to whatever the reservations leave (always
///   at least half the cache, for metadata walks). Reading a reserved chunk moves it here.
///
/// So read-ahead can push out old LRU entries but never a chunk a reader was promised.
/// Reservations that nobody will read (a file ended, a reader went elsewhere) belong to
/// a *stream* that goes idle; its reservations move into the LRU when the stream table
/// overflows or when another reader needs the read-ahead budget.
///
/// **Streams.** A read whose first chunk is the last chunk of an earlier read (or the one
/// after) continues that stream, and only a continuing stream gets read-ahead. Chunks
/// inside a single multi-chunk read are always decoded in parallel: they are needed now.
///
/// **No duplicate work.** A chunk queued or decoding is never scheduled again; a reader
/// that needs it waits. A reader whose chunk is still queued decodes it itself when a
/// decoder slot is free, or moves it to the front of the queue and waits.
///
/// One `NSCondition` guards all state; every change that could unblock a waiter
/// broadcasts. Decode work runs outside the lock. Events are per chunk (about 1 MiB of
/// output), so the lock is not hot.
final class DecodeScheduler: @unchecked Sendable {
    /// Largest share of the cache read-ahead may reserve, as a divisor: half.
    static let readAheadShareDivisor = 2
    /// Sequential streams tracked at once. The Extractor runs 4 readers; small files
    /// start a stream per read, so this leaves room for those without dropping big ones.
    static let maxStreams = 32
    /// Owner of chunks a reader queued for itself; never released.
    private static let demandOwner = -1
    private static let workerLabel = "dev.niduslabs.drop.decode"

    private enum Slot {
        case queued
        case decoding
        case ready([UInt8])
    }

    private struct Reservation {
        var owner: Int
        var slot: Slot
    }

    private struct Stream {
        let id: Int
        var lastChunk: Int
        var lastUse: UInt64
        var heldBytes = 0
    }

    let chunks: [Chunk]
    let cacheLimit: Int
    private let decode: @Sendable (Chunk) throws -> [UInt8]
    private let condition = NSCondition()

    // Everything below is guarded by `condition`.
    private var lru: ChunkCache
    private var reserved: [Int: Reservation] = [:]
    private var reservedBytes = 0
    private var queue: [Int] = []
    private var demandDecoding: Set<Int> = []
    private var failures: [Int: any Error] = [:]
    private var streams: [Stream] = []
    private var nextStreamID = 0
    private var clock: UInt64 = 0
    private var active = 0
    private var policy: DecodePolicy
    private var stats: DecodeStats

    init(
        chunks: [Chunk], cacheLimit: Int, policy: DecodePolicy,
        decode: @escaping @Sendable (Chunk) throws -> [UInt8]
    ) {
        self.chunks = chunks
        self.cacheLimit = cacheLimit
        self.decode = decode
        self.policy = policy
        lru = ChunkCache(limit: cacheLimit)
        stats = DecodeStats(chunkCount: chunks.count)
    }

    var decodePolicy: DecodePolicy {
        get { locked { policy } }
        set {
            locked {
                policy = newValue
                trimLRU()
                pump()
            }
        }
    }

    var decodeStats: DecodeStats { locked { stats } }

    func resetDecodeStats() { locked { stats = DecodeStats(chunkCount: chunks.count) } }

    /// Called once per read that touches a compressed chunk, before it reads any, with
    /// the first and last chunk indices the read covers.
    func plan(first: Int, last: Int) {
        locked {
            clock += 1
            let previousUse: UInt64
            let owner: Int
            let sequential: Bool
            if let s = streams.firstIndex(where: { $0.lastChunk == first || $0.lastChunk + 1 == first }) {
                previousUse = streams[s].lastUse
                streams[s].lastChunk = last
                streams[s].lastUse = clock
                owner = streams[s].id
                sequential = true
            } else {
                if streams.count >= Self.maxStreams,
                    let idle = streams.indices.min(by: { streams[$0].lastUse < streams[$1].lastUse })
                {
                    release(streams[idle].id)
                    streams.remove(at: idle)
                }
                owner = nextStreamID
                nextStreamID += 1
                streams.append(Stream(id: owner, lastChunk: last, lastUse: clock))
                previousUse = clock
                sequential = false
            }

            if first < last {
                for index in (first + 1)...last where needsDecode(index) { reserve(index, owner: owner) }
            }
            if sequential, policy.readAheadBytes > 0 {
                readAhead(after: last, owner: owner, previousUse: previousUse)
            }
            pump()
        }
    }

    /// The decoded bytes of compressed chunk `index`, decoding it on this thread or
    /// waiting for a worker as needed.
    func bytes(of index: Int) throws -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let hit = lru.get(index) { return hit }
            if let error = failures.removeValue(forKey: index) { throw error }
            if let reservation = reserved[index] {
                switch reservation.slot {
                case .ready(let bytes):
                    unreserve(index)
                    lru.put(index, bytes)
                    trimLRU()
                    pump()
                    return bytes
                case .decoding:
                    claim(index)
                    condition.wait()
                    continue
                case .queued:
                    if active < policy.maxDecoders {
                        unreserve(index)
                        return try decodeHere(index)
                    }
                    claim(index)
                    queue.removeAll { $0 == index }
                    queue.insert(index, at: 0)
                    pump()
                    condition.wait()
                    continue
                }
            }
            if demandDecoding.contains(index) {
                condition.wait()
                continue
            }
            if active < policy.maxDecoders { return try decodeHere(index) }
            reserve(index, owner: Self.demandOwner)
            queue.removeAll { $0 == index }
            queue.insert(index, at: 0)
            pump()
            condition.wait()
        }
    }

    // MARK: Internals (call with the lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    private func needsDecode(_ index: Int) -> Bool {
        let type = chunks[index].type
        guard !type.isZeroFill, type != .raw else { return false }
        return !lru.contains(index) && reserved[index] == nil && !demandDecoding.contains(index)
    }

    /// Reserves compressed chunks after `last` until `readAheadBytes` of them are covered
    /// or the shared budget is full. When it is full, frees the budget of a stream that
    /// hasn't read since this one last did (it went idle), then tries once more.
    private func readAhead(after last: Int, owner: Int, previousUse: UInt64) {
        let budget = limit / Self.readAheadShareDivisor
        var covered = 0
        var index = last + 1
        var freedIdle = false
        while index < chunks.count, covered < policy.readAheadBytes {
            let type = chunks[index].type
            if type.isZeroFill || type == .raw {
                index += 1
                continue
            }
            let length = Int(chunks[index].length)
            if needsDecode(index) {
                if reservedBytes + length > budget {
                    guard !freedIdle, let idle = idleStream(other: owner, before: previousUse) else { return }
                    freedIdle = true
                    release(streams[idle].id)
                    continue
                }
                reserve(index, owner: owner)
            }
            covered += length
            index += 1
        }
    }

    private func idleStream(other owner: Int, before use: UInt64) -> Int? {
        streams.indices
            .filter { streams[$0].id != owner && streams[$0].heldBytes > 0 && streams[$0].lastUse < use }
            .min { streams[$0].lastUse < streams[$1].lastUse }
    }

    private func reserve(_ index: Int, owner: Int) {
        let length = Int(chunks[index].length)
        reserved[index] = Reservation(owner: owner, slot: .queued)
        reservedBytes += length
        if let s = streams.firstIndex(where: { $0.id == owner }) { streams[s].heldBytes += length }
        queue.append(index)
        trimLRU()
    }

    /// Hands a reservation to the waiting reader, so releasing its stream can't drop it.
    private func claim(_ index: Int) {
        guard var reservation = reserved[index], reservation.owner != Self.demandOwner else { return }
        if let s = streams.firstIndex(where: { $0.id == reservation.owner }) {
            streams[s].heldBytes -= Int(chunks[index].length)
        }
        reservation.owner = Self.demandOwner
        reserved[index] = reservation
    }

    private func unreserve(_ index: Int) {
        guard let reservation = reserved.removeValue(forKey: index) else { return }
        let length = Int(chunks[index].length)
        reservedBytes -= length
        if let s = streams.firstIndex(where: { $0.id == reservation.owner }) { streams[s].heldBytes -= length }
        if case .queued = reservation.slot { queue.removeAll { $0 == index } }
    }

    /// Drops a stream's queued chunks and moves its decoded ones into the LRU. Chunks
    /// still decoding go to the LRU when they finish.
    private func release(_ owner: Int) {
        for (index, reservation) in reserved where reservation.owner == owner {
            switch reservation.slot {
            case .queued:
                unreserve(index)
            case .ready(let bytes):
                unreserve(index)
                lru.put(index, bytes)
            case .decoding:
                break
            }
        }
        trimLRU()
    }

    /// The cache budget under the current policy.
    private var limit: Int { min(cacheLimit, policy.cacheBytes ?? cacheLimit) }

    private func trimLRU() { lru.trim(to: max(0, limit - reservedBytes)) }

    /// Starts workers for queued chunks while decoder slots are free.
    private func pump() {
        while active < policy.maxDecoders, !queue.isEmpty {
            let index = queue.removeFirst()
            guard var reservation = reserved[index], case .queued = reservation.slot else { continue }
            reservation.slot = .decoding
            reserved[index] = reservation
            started(index)
            // A queue of its own rather than a global one: private serial queues always get
            // a thread, while the global pool can be full of readers blocked in `bytes(of:)`
            // waiting for this very chunk. `maxDecoders` bounds how many exist at once.
            let qos = policy.qos
            DispatchQueue(label: Self.workerLabel, qos: DispatchQoS(qosClass: qos, relativePriority: 0)).async {
                self.work(index, throttled: qos == .background)
            }
        }
    }

    private func started(_ index: Int) {
        active += 1
        stats.decodes[index] += 1
        stats.maxConcurrent = max(stats.maxConcurrent, active)
    }

    /// Decodes `index` on the calling thread, which holds the lock on entry and exit.
    private func decodeHere(_ index: Int) throws -> [UInt8] {
        started(index)
        demandDecoding.insert(index)
        condition.unlock()
        let result = Result { try decode(chunks[index]) }
        condition.lock()
        active -= 1
        demandDecoding.remove(index)
        if case .success(let bytes) = result {
            lru.put(index, bytes)
            trimLRU()
        }
        condition.broadcast()
        pump()
        return try result.get()
    }

    /// A worker's job: one chunk, then back to the pool. Background workers throttle
    /// their disk reads like the Extractor's background threads do.
    private func work(_ index: Int, throttled: Bool) {
        let saved = throttled ? getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) : -1
        if throttled { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE) }
        let result = Result { try decode(chunks[index]) }
        if saved >= 0 { _ = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, saved) }

        locked {
            active -= 1
            stats.lastWorkerQoS = qos_class_self()
            switch result {
            case .success(let bytes):
                if var reservation = reserved[index],
                    reservation.owner == Self.demandOwner || streams.contains(where: { $0.id == reservation.owner })
                {
                    reservation.slot = .ready(bytes)
                    reserved[index] = reservation
                } else {
                    unreserve(index)
                    lru.put(index, bytes)
                    trimLRU()
                }
            case .failure(let error):
                unreserve(index)
                failures[index] = error
            }
            condition.broadcast()
            pump()
        }
    }
}
