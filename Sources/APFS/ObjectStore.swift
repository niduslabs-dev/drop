import ReaderCore
import Synchronization

/// How many parsed B-tree nodes each container keeps. At 4 KiB per node this is 16 MiB,
/// enough to hold the whole omap and fs tree of a large app image during a walk.
let nodeCacheCapacity = 4096

/// Reads and checksums APFS objects by physical block address, and caches parsed B-tree
/// nodes. Shared by a container and every volume opened from it.
///
/// Immutable apart from the cache, which is behind a mutex, so it is safe to use from
/// several threads at once.
final class ObjectStore: Sendable {
    let device: any BlockDevice
    let blockSize: Int
    let blockCount: UInt64
    private let cache = Mutex(LRUCache<UInt64, BTreeNode>(capacity: nodeCacheCapacity))

    init(device: any BlockDevice, blockSize: Int, blockCount: UInt64) {
        self.device = device
        self.blockSize = blockSize
        self.blockCount = blockCount
    }

    /// Byte offset of a block on the device, checked against the container and the device.
    func byteOffset(ofBlock block: UInt64, length: UInt64) throws -> UInt64 {
        let (offset, overflow) = block.multipliedReportingOverflow(by: UInt64(blockSize))
        let (end, endOverflow) = offset.addingReportingOverflow(length)
        guard !overflow, !endOverflow, block < blockCount, end <= device.size else {
            throw ReaderError.corrupt("block \(block) (+\(length) bytes) is past the end of the container")
        }
        return offset
    }

    func readBlock(_ block: UInt64) throws -> [UInt8] {
        let offset = try byteOffset(ofBlock: block, length: UInt64(blockSize))
        do {
            return try device.read(at: offset, count: blockSize)
        } catch ReaderError.outOfBounds {
            throw ReaderError.corrupt("block \(block) is past the end of the device")
        }
    }

    /// Reads the object at `block` and verifies its checksum, type and ID.
    ///
    /// - Parameters:
    ///   - oid: the ID the header must carry (the block number for physical objects).
    ///   - types: accepted values of the header's type field, masked to the type bits.
    ///   - maxXID: objects newer than the checkpoint being read are stale or corrupt.
    func readObject(at block: UInt64, oid: UInt64, types: Set<UInt32>, maxXID: UInt64) throws -> ByteReader {
        let reader = ByteReader(try readBlock(block))
        try Self.verify(reader, at: block)
        let headerOID = try reader.le64(Format.Object.oid)
        let type = try reader.le32(Format.Object.type) & Format.Object.typeMask
        let xid = try reader.le64(Format.Object.xid)
        guard headerOID == oid else {
            throw ReaderError.corrupt("block \(block) holds object \(headerOID), expected \(oid)")
        }
        guard types.contains(type) else {
            throw ReaderError.corrupt("object \(oid) has type \(type), expected \(types.sorted())")
        }
        guard xid <= maxXID else {
            throw ReaderError.corrupt("object \(oid) has transaction \(xid), newer than \(maxXID)")
        }
        return reader
    }

    /// Throws `corrupt` unless the object's stored Fletcher-64 checksum matches its bytes.
    static func verify(_ reader: ByteReader, at block: UInt64) throws {
        let stored = try reader.le64(Format.Object.checksum)
        guard stored == fletcher64(reader.bytes) else {
            throw ReaderError.corrupt("bad checksum on block \(block)")
        }
    }

    /// The APFS object checksum: Fletcher-64 over 32-bit little-endian words, skipping
    /// the checksum field itself. A valid object yields its stored checksum.
    static func fletcher64(_ bytes: [UInt8]) -> UInt64 {
        let modulus: UInt64 = 0xFFFF_FFFF
        let wordSize = 4
        var sum1: UInt64 = 0
        var sum2: UInt64 = 0
        bytes.withUnsafeBytes { raw in
            var offset = Format.Object.oid
            while offset + wordSize <= raw.count {
                let word = UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                sum1 = (sum1 + word) % modulus
                sum2 = (sum2 + sum1) % modulus
                offset += wordSize
            }
        }
        let check1 = modulus - ((sum1 + sum2) % modulus)
        let check2 = modulus - ((sum1 + check1) % modulus)
        return check2 << 32 | check1
    }

    /// A verified, parsed B-tree node, from the cache when possible.
    func node(at block: UInt64, oid: UInt64, maxXID: UInt64) throws -> BTreeNode {
        if let cached = cache.withLock({ $0.value(for: block) }) {
            guard cached.oid == oid, cached.xid <= maxXID else {
                throw ReaderError.corrupt("block \(block) holds node \(cached.oid), expected \(oid)")
            }
            return cached
        }
        let reader = try readObject(
            at: block, oid: oid, types: [Format.Object.typeBTreeRoot, Format.Object.typeBTreeNode], maxXID: maxXID)
        let node = try BTreeNode(reader)
        cache.withLock { $0.insert(node, for: block) }
        return node
    }
}

/// A fixed-capacity least-recently-used map. Not thread-safe on its own; `ObjectStore`
/// keeps it inside a mutex.
struct LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Slot: Sendable {
        var key: Key
        var value: Value
        var previous: Int
        var next: Int
    }

    private let capacity: Int
    private var index: [Key: Int] = [:]
    private var slots: [Slot] = []
    /// Most recently used slot, or -1 when empty.
    private var head = -1
    /// Least recently used slot, or -1 when empty.
    private var tail = -1

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let slot = index[key] else { return nil }
        moveToFront(slot)
        return slots[slot].value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if let slot = index[key] {
            slots[slot].value = value
            moveToFront(slot)
            return
        }
        let slot: Int
        if slots.count < capacity {
            slots.append(Slot(key: key, value: value, previous: -1, next: -1))
            slot = slots.count - 1
        } else {
            slot = tail
            unlink(slot)
            index[slots[slot].key] = nil
            slots[slot] = Slot(key: key, value: value, previous: -1, next: -1)
        }
        index[key] = slot
        linkAtFront(slot)
    }

    private mutating func moveToFront(_ slot: Int) {
        guard slot != head else { return }
        unlink(slot)
        linkAtFront(slot)
    }

    private mutating func unlink(_ slot: Int) {
        let previous = slots[slot].previous
        let next = slots[slot].next
        if previous >= 0 { slots[previous].next = next } else { head = next }
        if next >= 0 { slots[next].previous = previous } else { tail = previous }
        slots[slot].previous = -1
        slots[slot].next = -1
    }

    private mutating func linkAtFront(_ slot: Int) {
        slots[slot].next = head
        slots[slot].previous = -1
        if head >= 0 { slots[head].previous = slot }
        head = slot
        if tail < 0 { tail = slot }
    }
}
