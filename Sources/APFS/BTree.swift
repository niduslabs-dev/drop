import ReaderCore

/// One verified B-tree node. Record ranges are validated against the node's key and
/// value areas when they are read, so a bad table of contents throws `corrupt`.
struct BTreeNode: Sendable {
    let data: ByteReader
    let oid: UInt64
    let xid: UInt64
    let flags: UInt16
    let level: Int
    let count: Int
    private let tableStart: Int
    private let keyStart: Int
    private let valueEnd: Int

    var isRoot: Bool { flags & Format.BTree.flagRoot != 0 }
    var isLeaf: Bool { flags & Format.BTree.flagLeaf != 0 }
    var isFixedSize: Bool { flags & Format.BTree.flagFixedSize != 0 }

    init(_ data: ByteReader) throws {
        self.data = data
        oid = try data.le64(Format.Object.oid)
        xid = try data.le64(Format.Object.xid)
        flags = try data.le16(Format.BTree.flags)
        level = Int(try data.le16(Format.BTree.level))
        count = Int(try data.le32(Format.BTree.keyCount))
        let tableOffset = Int(try data.le16(Format.BTree.tableSpaceOffset))
        let tableLength = Int(try data.le16(Format.BTree.tableSpaceLength))
        tableStart = Format.BTree.data + tableOffset
        keyStart = tableStart + tableLength
        valueEnd = data.bytes.count - (flags & Format.BTree.flagRoot != 0 ? Format.BTree.infoSize : 0)
        let entrySize =
            flags & Format.BTree.flagFixedSize != 0
            ? Format.BTree.fixedEntrySize : Format.BTree.variableEntrySize
        guard level < Format.BTree.maxDepth, keyStart <= valueEnd, count * entrySize <= tableLength,
            (level == 0) == (flags & Format.BTree.flagLeaf != 0)
        else {
            throw ReaderError.corrupt("malformed B-tree node \(oid)")
        }
    }

    /// Key and value byte ranges of record `index`. Fixed-size trees take their sizes from
    /// the tree's `btree_info_t`; their index nodes always hold 8-byte child IDs.
    func record(_ index: Int, fixedKeySize: Int, fixedValueSize: Int) throws -> (key: Range<Int>, value: Range<Int>) {
        let keyOffset: Int
        let keyLength: Int
        let valueOffset: Int
        let valueLength: Int
        if isFixedSize {
            let entry = tableStart + index * Format.BTree.fixedEntrySize
            keyOffset = Int(try data.le16(entry))
            valueOffset = Int(try data.le16(entry + 2))
            keyLength = fixedKeySize
            valueLength = isLeaf ? fixedValueSize : Format.BTree.childOIDSize
        } else {
            let entry = tableStart + index * Format.BTree.variableEntrySize
            keyOffset = Int(try data.le16(entry))
            keyLength = Int(try data.le16(entry + 2))
            valueOffset = Int(try data.le16(entry + 4))
            valueLength = Int(try data.le16(entry + 6))
        }
        let keyLower = keyStart + keyOffset
        let valueLower = valueEnd - valueOffset
        guard keyLower + keyLength <= valueEnd, valueLower >= keyStart, valueLower + valueLength <= valueEnd else {
            throw ReaderError.corrupt("record \(index) of B-tree node \(oid) is out of bounds")
        }
        return (keyLower..<keyLower + keyLength, valueLower..<valueLower + valueLength)
    }
}

/// How a tree's child pointers turn into block addresses.
enum NodeAddressing: Sendable {
    /// Child IDs are block numbers (object maps, sealed volumes' trees).
    case physical
    /// Child IDs are virtual and resolve through a volume's object map.
    case virtual(ObjectMap)
}

/// Where a key sits relative to the range a scan is looking for.
enum KeyOrder {
    case before, inside, after
}

/// A read-only view of one APFS B-tree.
///
/// Scans are range queries: the caller says where a key sits relative to the wanted
/// range, and the scan visits only subtrees that can hold matching records. APFS index
/// nodes have no sibling links, so this is how lookups and "all records of object N"
/// both work.
struct BTree: Sendable {
    /// Upper bound on nodes one scan may visit, so a tree whose nodes are shared many
    /// times over (a corrupt DAG) can't turn a lookup into an exponential walk.
    static let maxNodesPerScan = 1_000_000

    let store: ObjectStore
    let rootOID: UInt64
    let addressing: NodeAddressing
    let maxXID: UInt64
    let fixedKeySize: Int
    let fixedValueSize: Int

    init(store: ObjectStore, rootOID: UInt64, addressing: NodeAddressing, maxXID: UInt64) throws {
        self.store = store
        self.rootOID = rootOID
        self.addressing = addressing
        self.maxXID = maxXID
        let root = try Self.node(store: store, oid: rootOID, addressing: addressing, maxXID: maxXID)
        guard root.isRoot else { throw ReaderError.corrupt("B-tree root \(rootOID) lacks the root flag") }
        let info = root.data.bytes.count - Format.BTree.infoSize
        fixedKeySize = Int(try root.data.le32(info + Format.BTree.infoKeySize))
        fixedValueSize = Int(try root.data.le32(info + Format.BTree.infoValueSize))
    }

    private static func node(store: ObjectStore, oid: UInt64, addressing: NodeAddressing, maxXID: UInt64) throws
        -> BTreeNode
    {
        switch addressing {
        case .physical:
            return try store.node(at: oid, oid: oid, maxXID: maxXID)
        case .virtual(let map):
            return try store.node(at: try map.physicalAddress(of: oid), oid: oid, maxXID: maxXID)
        }
    }

    /// Visits every leaf record whose key `order` reports as `.inside`, in key order.
    /// `visit` returns false to stop early. `order` must be monotonic over the tree's
    /// key order.
    func scan(
        order: (ByteReader, Range<Int>) throws -> KeyOrder,
        visit: (ByteReader, _ key: Range<Int>, _ value: Range<Int>) throws -> Bool
    ) throws {
        var visited = 0
        let root = try Self.node(store: store, oid: rootOID, addressing: addressing, maxXID: maxXID)
        _ = try scan(root, depth: 0, visited: &visited, order: order, visit: visit)
    }

    private func scan(
        _ node: BTreeNode, depth: Int, visited: inout Int,
        order: (ByteReader, Range<Int>) throws -> KeyOrder,
        visit: (ByteReader, Range<Int>, Range<Int>) throws -> Bool
    ) throws -> Bool {
        visited += 1
        guard visited <= Self.maxNodesPerScan, depth < Format.BTree.maxDepth else {
            throw ReaderError.corrupt("B-tree \(rootOID) is too deep or loops")
        }
        let record = { (index: Int) in
            try node.record(index, fixedKeySize: fixedKeySize, fixedValueSize: fixedValueSize)
        }
        // First record whose key is not before the range.
        var low = 0
        var high = node.count
        while low < high {
            let mid = (low + high) / 2
            if try order(node.data, try record(mid).key) == .before { low = mid + 1 } else { high = mid }
        }
        if node.isLeaf {
            for index in low..<node.count {
                let (key, value) = try record(index)
                guard try order(node.data, key) == .inside else { break }
                guard try visit(node.data, key, value) else { return false }
            }
            return true
        }
        // The child before the first in-range key can still hold in-range records.
        for index in max(low - 1, 0)..<node.count {
            let (key, value) = try record(index)
            if index >= low, try order(node.data, key) == .after { break }
            guard value.count >= Format.BTree.childOIDSize else {
                throw ReaderError.corrupt("short child pointer in B-tree node \(node.oid)")
            }
            let childOID = try node.data.le64(value.lowerBound)
            let child = try Self.node(store: store, oid: childOID, addressing: addressing, maxXID: maxXID)
            guard child.level == node.level - 1, !child.isRoot else {
                throw ReaderError.corrupt("B-tree node \(childOID) has level \(child.level) under level \(node.level)")
            }
            guard try scan(child, depth: depth + 1, visited: &visited, order: order, visit: visit) else { return false }
        }
        return true
    }
}

/// An object map: virtual object ID → physical block, for the newest version no newer
/// than the transaction it was opened at.
final class ObjectMap: Sendable {
    let tree: BTree
    let xid: UInt64

    /// - Parameters:
    ///   - block: the physical address of the `omap_phys_t`.
    ///   - xid: lookups return the newest mapping with a transaction ID at most this.
    init(store: ObjectStore, block: UInt64, xid: UInt64) throws {
        let omap = try store.readObject(at: block, oid: block, types: [Format.Object.typeObjectMap], maxXID: xid)
        let treeType = try omap.le32(Format.ObjectMap.treeType)
        guard treeType & Format.Object.storageMask == Format.Object.storagePhysical else {
            throw ReaderError.corrupt("object map \(block) has a non-physical tree")
        }
        tree = try BTree(
            store: store, rootOID: try omap.le64(Format.ObjectMap.treeOID), addressing: .physical, maxXID: xid)
        self.xid = xid
    }

    func physicalAddress(of oid: UInt64) throws -> UInt64 {
        var found: (flags: UInt32, address: UInt64)?
        let xid = self.xid
        try tree.scan(
            order: { data, key in
                guard key.count >= Format.ObjectMap.keySize else {
                    throw ReaderError.corrupt("short object map key")
                }
                let keyOID = try data.le64(key.lowerBound)
                if keyOID != oid { return keyOID < oid ? .before : .after }
                return try data.le64(key.lowerBound + 8) <= xid ? .inside : .after
            },
            visit: { data, _, value in
                guard value.count >= Format.ObjectMap.valueSize else {
                    throw ReaderError.corrupt("short object map value")
                }
                found = (
                    try data.le32(value.lowerBound + Format.ObjectMap.valueFlags),
                    try data.le64(value.lowerBound + Format.ObjectMap.valuePhysicalAddress)
                )
                return true
            })
        guard let found, found.flags & Format.ObjectMap.flagDeleted == 0 else {
            throw ReaderError.corrupt("object \(oid) is not in the object map")
        }
        guard found.flags & Format.ObjectMap.flagEncrypted == 0 else { throw ReaderError.encrypted }
        return found.address
    }
}
