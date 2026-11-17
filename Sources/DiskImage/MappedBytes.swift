import Darwin
import ReaderCore
import Synchronization

/// Bytes in their own anonymous memory mapping, unmapped the moment the last reference goes.
///
/// Decoded chunks (and the compressed bytes they're decoded from) are 1 to 4 MiB each and
/// short-lived. From `malloc` they land in the default zone's small or large regions, and
/// once freed their pages stay dirty and count in Drop's footprint until libmalloc hands
/// them back by itself: measured at more than 2 minutes with a panel open on Ready
/// (`.claude/research/drop-memory.md`, "Footprint after close"). `munmap` returns them to
/// the kernel at once.
///
/// Every region is fresh from `mmap(MAP_ANON | MAP_PRIVATE)`, so it starts as zero pages.
/// Nothing is pooled or reused: a decoder that wrote less than it should can't expose an
/// earlier chunk's bytes. The contents are written once, inside `init`, before the object
/// can be shared; after that they are read-only, which is what makes it `Sendable`.
final class MappedBytes: @unchecked Sendable {
    /// The bytes callers see. The mapping itself is rounded up to whole pages; the tail past
    /// `count` is never exposed.
    let count: Int
    private let base: UnsafeMutableRawPointer
    /// What was passed to `mmap`, and so to `munmap`. At least 1: `mmap` refuses length 0.
    private let mappedLength: Int
    private let regions: MappedRegions?

    /// Maps `count` zeroed bytes and hands them to `fill`, which must write all of them or
    /// throw. A throw unmaps the region before it propagates. `regions`, if given, counts
    /// this mapping while it lives.
    init(
        count: Int, regions: MappedRegions? = nil, fill: (UnsafeMutableRawBufferPointer) throws -> Void
    ) throws {
        precondition(count >= 0, "negative byte count")
        let length = max(count, 1)
        guard let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
            pointer != MAP_FAILED
        else { throw ReaderError.io(errno: errno, context: "mmap \(count) bytes") }
        do {
            try fill(UnsafeMutableRawBufferPointer(start: pointer, count: count))
        } catch {
            munmap(pointer, length)
            throw error
        }
        self.base = pointer
        self.count = count
        self.mappedLength = length
        self.regions = regions
        regions?.opened()
    }

    deinit {
        munmap(base, mappedLength)
        regions?.closed()
    }

    /// The bytes, valid only inside `body`. Holding `self` keeps them mapped, so a reader
    /// copying out of a cached chunk is safe even if the cache evicts it meanwhile.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) { try body(UnsafeRawBufferPointer(start: base, count: count)) }
    }
}

/// How many `MappedBytes` regions are mapped right now, for one device. Tests read it to check
/// that releasing a reader or trimming its cache unmaps everything.
final class MappedRegions: Sendable {
    private let live = Atomic<Int>(0)

    init() {}

    var count: Int { live.load(ordering: .acquiring) }

    fileprivate func opened() { live.wrappingAdd(1, ordering: .relaxed) }
    fileprivate func closed() { live.wrappingSubtract(1, ordering: .releasing) }
}
