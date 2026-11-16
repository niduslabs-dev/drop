import Dispatch
import ReaderCore
import Synchronization

/// The whole decoded disk of a UDIF image, with every `blkx` table merged by sector.
///
/// Reads decode only the chunks they touch. Decoded chunks go into a small LRU cache bounded
/// by bytes (`cacheLimit`), so metadata walks that revisit the same chunks stay fast while
/// bulk reads can't grow memory. Raw and zero-fill chunks bypass the cache. Two threads that
/// miss on the same chunk at once both decode it; that wastes a little work but keeps the
/// lock out of the decode path.
///
/// For bulk extraction, decode chunks in parallel with `decodeAll(maxConcurrency:_:)` or
/// your own scheduler over `chunks` and `decodeChunk(_:)`: chunks are independent.
public final class UDIFDevice: BlockDevice {
    /// Default byte budget for the decoded-chunk cache.
    public static let defaultCacheLimit = 64 * 1024 * 1024
    /// Largest decoded chunk accepted from a compressed type. hdiutil writes 1 MiB (UDZO)
    /// to 4 MiB chunks; anything far bigger is a damaged or hostile table, and refusing it
    /// keeps one bad entry from allocating gigabytes.
    public static let maxDecodedChunkSize: UInt64 = 64 * 1024 * 1024
    /// Largest piece of a raw chunk `decodeAll` hands over at once, so huge raw chunks
    /// (UDRO/UDRW store whole partitions as one) don't need one huge buffer.
    public static let rawPieceSize = 4 * 1024 * 1024

    public let size: UInt64
    /// Every data-carrying chunk, sorted by `deviceOffset`, non-overlapping. Gaps between
    /// chunks read as zeros.
    public let chunks: [Chunk]
    /// The `blkx` tables, in plist order.
    public let tables: [BlockTable]
    public let cacheLimit: Int

    private let file: any BlockDevice
    private let cache: Mutex<ChunkCache>

    /// `file` is the `.dmg` itself. `chunks` need not be sorted; overlapping chunks or chunks
    /// past `size` throw `corrupt`.
    init(
        file: any BlockDevice, size: UInt64, tables: [BlockTable], chunks unsorted: [Chunk],
        cacheLimit: Int = UDIFDevice.defaultCacheLimit
    ) throws {
        let sorted = unsorted.sorted { $0.deviceOffset < $1.deviceOffset }
        var chunks: [Chunk] = []
        chunks.reserveCapacity(sorted.count)
        var previousEnd: UInt64 = 0
        for chunk in sorted {
            guard chunk.deviceOffset >= previousEnd else {
                throw ReaderError.corrupt("chunks overlap at \(chunk.deviceOffset)")
            }
            previousEnd = chunk.deviceOffset + chunk.length
            guard previousEnd <= size else {
                throw ReaderError.corrupt("chunk at \(chunk.deviceOffset) runs past the disk")
            }
            if !chunk.type.isZeroFill, chunk.type != .raw, chunk.length > Self.maxDecodedChunkSize {
                throw ReaderError.corrupt("chunk at \(chunk.deviceOffset) decodes to \(chunk.length) bytes")
            }
            chunks.append(
                Chunk(
                    index: chunks.count, type: chunk.type, deviceOffset: chunk.deviceOffset, length: chunk.length,
                    fileOffset: chunk.fileOffset, fileLength: chunk.fileLength))
        }
        self.file = file
        self.size = size
        self.tables = tables
        self.chunks = chunks
        self.cacheLimit = cacheLimit
        self.cache = Mutex(ChunkCache(limit: cacheLimit))
    }

    // MARK: Reading

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(buffer.count))
        guard !overflow, end <= size else { throw ReaderError.outOfBounds }
        var position = offset
        var done = 0
        var index = chunkIndex(containingOrAfter: position)
        while done < buffer.count {
            let remaining = buffer.count - done
            let out = UnsafeMutableRawBufferPointer(rebasing: buffer[done...])
            guard index < chunks.count, chunks[index].deviceOffset < end else {
                zero(out)
                return
            }
            let chunk = chunks[index]
            if position < chunk.deviceOffset {
                let gap = Int(chunk.deviceOffset - position)
                zero(UnsafeMutableRawBufferPointer(rebasing: out[..<gap]))
                done += gap
                position += UInt64(gap)
                continue
            }
            let within = position - chunk.deviceOffset
            let take = Int(min(UInt64(remaining), chunk.length - within))
            let target = UnsafeMutableRawBufferPointer(rebasing: out[..<take])
            switch chunk.type {
            case .zero, .ignore:
                zero(target)
            case .raw:
                try file.read(at: chunk.fileOffset + within, into: target)
            default:
                let decoded = try cachedChunk(chunk)
                decoded.withUnsafeBytes { bytes in
                    target.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[Int(within)..<Int(within) + take]))
                }
            }
            done += take
            position += UInt64(take)
            index += 1
        }
    }

    /// Decodes one chunk into a new array of `chunk.length` bytes, without the cache.
    /// Zero-fill chunks return zeros; prefer skipping them.
    public func decodeChunk(_ chunk: Chunk) throws -> [UInt8] {
        guard chunk.length <= Self.maxDecodedChunkSize else {
            throw ReaderError.corrupt("chunk at \(chunk.deviceOffset) too large to decode whole")
        }
        var output = [UInt8](repeating: 0, count: Int(chunk.length))
        if chunk.type.isZeroFill { return output }
        let input = try storedBytes(of: chunk)
        try input.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { try Decoders.decode(chunk.type, input: source, output: $0) }
        }
        return output
    }

    /// Decodes every chunk with at most `maxConcurrency` workers and hands each decoded run
    /// to `body` with its byte offset on the disk. `body` runs on several threads at once,
    /// in no particular order. Zero-fill chunks and gaps are not passed: those bytes are
    /// zeros, so a caller writing a disk out only has to start from zeros. Raw chunks arrive
    /// in pieces of at most `rawPieceSize` bytes. The first error stops further work and is
    /// rethrown.
    public func decodeAll(
        maxConcurrency: Int,
        _ body: @Sendable (_ deviceOffset: UInt64, _ bytes: UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let work = chunks.filter { !$0.type.isZeroFill }
        let next = Atomic<Int>(0)
        let failure = Mutex<(any Error)?>(nil)
        let workers = max(1, min(maxConcurrency, work.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while failure.withLock({ $0 == nil }) {
                let i = next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard i < work.count else { return }
                do {
                    try self.decode(work[i], body)
                } catch {
                    failure.withLock { if $0 == nil { $0 = error } }
                }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    // MARK: Internals

    private func decode(
        _ chunk: Chunk, _ body: (_ deviceOffset: UInt64, _ bytes: UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard chunk.type == .raw else {
            let bytes = try decodeChunk(chunk)
            try bytes.withUnsafeBytes { try body(chunk.deviceOffset, $0) }
            return
        }
        var piece = [UInt8](repeating: 0, count: Int(min(chunk.length, UInt64(Self.rawPieceSize))))
        var within: UInt64 = 0
        while within < chunk.length {
            let count = Int(min(chunk.length - within, UInt64(piece.count)))
            try piece.withUnsafeMutableBytes { all in
                let target = UnsafeMutableRawBufferPointer(rebasing: all[..<count])
                try file.read(at: chunk.fileOffset + within, into: target)
                try body(chunk.deviceOffset + within, UnsafeRawBufferPointer(target))
            }
            within += UInt64(count)
        }
    }

    private func storedBytes(of chunk: Chunk) throws -> [UInt8] {
        guard chunk.fileLength <= Self.maxDecodedChunkSize * 2 else {
            throw ReaderError.corrupt("chunk at \(chunk.deviceOffset) stores \(chunk.fileLength) bytes")
        }
        do {
            return try file.read(at: chunk.fileOffset, count: Int(chunk.fileLength))
        } catch ReaderError.outOfBounds {
            throw ReaderError.corrupt("chunk at \(chunk.deviceOffset) points past the file")
        }
    }

    private func cachedChunk(_ chunk: Chunk) throws -> [UInt8] {
        if let hit = cache.withLock({ $0.get(chunk.index) }) { return hit }
        let decoded = try decodeChunk(chunk)
        cache.withLock { $0.put(chunk.index, decoded) }
        return decoded
    }

    /// The first chunk whose end is past `offset`.
    private func chunkIndex(containingOrAfter offset: UInt64) -> Int {
        var low = 0
        var high = chunks.count
        while low < high {
            let mid = (low + high) / 2
            if chunks[mid].deviceOffset + chunks[mid].length <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func zero(_ buffer: UnsafeMutableRawBufferPointer) {
        if let base = buffer.baseAddress { memset(base, 0, buffer.count) }
    }
}

/// A least-recently-used map from chunk index to decoded bytes, bounded by total bytes.
/// A doubly linked list over a dictionary keeps every operation O(1), which matters for
/// images with thousands of tiny chunks.
struct ChunkCache: ~Copyable {
    private struct Node {
        var bytes: [UInt8]
        var previous: Int?
        var next: Int?
    }

    let limit: Int
    private(set) var total = 0
    private var nodes: [Int: Node] = [:]
    private var newest: Int?
    private var oldest: Int?

    init(limit: Int) { self.limit = limit }

    var count: Int { nodes.count }

    mutating func get(_ key: Int) -> [UInt8]? {
        guard let node = nodes[key] else { return nil }
        unlink(key)
        pushNewest(key, node.bytes)
        return node.bytes
    }

    mutating func put(_ key: Int, _ bytes: [UInt8]) {
        guard bytes.count <= limit else { return }
        if nodes[key] != nil { unlink(key) }
        pushNewest(key, bytes)
        while total > limit, let victim = oldest { unlink(victim) }
    }

    private mutating func pushNewest(_ key: Int, _ bytes: [UInt8]) {
        nodes[key] = Node(bytes: bytes, previous: nil, next: newest)
        if let newest { nodes[newest]?.previous = key }
        newest = key
        if oldest == nil { oldest = key }
        total += bytes.count
    }

    private mutating func unlink(_ key: Int) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        if let previous = node.previous { nodes[previous]?.next = node.next } else { newest = node.next }
        if let next = node.next { nodes[next]?.previous = node.previous } else { oldest = node.previous }
        total -= node.bytes.count
    }
}
