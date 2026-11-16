import ReaderCore

/// Allocation-block runs of one fork, already resolved through the extents overflow file,
/// as byte ranges on the device.
struct ForkMap: Sendable {
    /// Device extents in file order; `fileOffset` of each is the running total.
    let extents: [Extent]
    let logicalSize: UInt64

    /// Reads `count` bytes at `offset` within the fork. Throws `corrupt` when the range runs
    /// past the mapped blocks.
    func read(_ device: any BlockDevice, at offset: UInt64, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        var position = offset
        for extent in extents where done < count {
            let end = extent.fileOffset + extent.length
            guard position >= extent.fileOffset, position < end else { continue }
            let take = Int(min(UInt64(count - done), end - position))
            try out.withUnsafeMutableBytes { all in
                let slice = UnsafeMutableRawBufferPointer(rebasing: all[done..<done + take])
                do {
                    try device.read(at: extent.deviceOffset + (position - extent.fileOffset), into: slice)
                } catch ReaderError.outOfBounds {
                    throw ReaderError.corrupt("fork extent runs past the end of the device")
                }
            }
            done += take
            position += UInt64(take)
        }
        guard done == count else {
            throw ReaderError.corrupt("read of \(count) bytes at \(offset) past the fork's mapped blocks")
        }
        return out
    }
}

/// One B-tree node, with its descriptor checked and its record offsets validated, so
/// `record(_:)` never hands out a range outside the node.
struct BTreeNode {
    enum Kind: Int8 {
        case leaf = -1
        case index = 0
        case header = 1
        case map = 2
    }

    private enum Layout {
        static let forwardLink = 0
        static let kind = 8
        static let height = 9
        static let recordCount = 10
        static let descriptorSize = 14
        static let offsetSize = 2
    }

    let number: UInt32
    let kind: Kind
    let height: UInt8
    let forwardLink: UInt32
    let reader: ByteReader
    /// Start offsets of each record plus the free-space offset, ascending.
    private let offsets: [Int]

    init(number: UInt32, bytes: [UInt8]) throws {
        let reader = ByteReader(bytes)
        let rawKind = Int8(bitPattern: try reader.u8(Layout.kind))
        guard let kind = Kind(rawValue: rawKind) else {
            throw ReaderError.corrupt("B-tree node \(number) has kind \(rawKind)")
        }
        let count = Int(try reader.be16(Layout.recordCount))
        let tableSize = (count + 1) * Layout.offsetSize
        guard Layout.descriptorSize + tableSize <= bytes.count else {
            throw ReaderError.corrupt("B-tree node \(number) claims \(count) records")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(count + 1)
        var previous = Layout.descriptorSize
        for index in 0...count {
            let offset = Int(try reader.be16(bytes.count - Layout.offsetSize * (index + 1)))
            guard offset >= previous, offset <= bytes.count - tableSize else {
                throw ReaderError.corrupt("B-tree node \(number) record \(index) offset \(offset) out of order")
            }
            offsets.append(offset)
            previous = offset
        }
        self.number = number
        self.kind = kind
        self.height = try reader.u8(Layout.height)
        self.forwardLink = try reader.be32(Layout.forwardLink)
        self.reader = reader
        self.offsets = offsets
    }

    var recordCount: Int { offsets.count - 1 }

    /// The byte range of record `index` within the node.
    func record(_ index: Int) -> Range<Int> { offsets[index]..<offsets[index + 1] }
}

/// A key and the record data that follows it, both as offsets into the node's bytes.
struct BTreeRecord {
    let node: BTreeNode
    let index: Int
    let keyStart: Int
    let dataStart: Int
    let end: Int

    var reader: ByteReader { node.reader }
}

/// A read-only HFS+ B-tree (catalog, extents overflow or attributes).
///
/// Searches never compare names: callers pass an `isLess` predicate over raw key bytes
/// that only orders by the numeric key prefix (parent ID, file ID). That is enough for
/// every lookup the reader needs and sidesteps HFS+'s case-folding Unicode order.
struct BTree: Sendable {
    private enum HeaderLayout {
        static let recordStart = 14
        static let depth = 0
        static let rootNode = 2
        static let firstLeaf = 10
        static let nodeSize = 18
        static let maxKeyLength = 20
        static let totalNodes = 22
        static let keyCompareType = 37
        static let attributes = 38
        static let minimumNodeSize = 512
        static let maximumNodeSize = 32768
    }

    private static let bigKeysMask: UInt32 = 0x2
    private static let variableIndexKeysMask: UInt32 = 0x4
    private static let keyLengthSize = 2
    private static let childPointerSize = 4
    /// Deeper than any real tree (HFS+ caps at 8 levels); stops corrupt height loops.
    private static let maximumDepth = 16

    let name: String
    let device: any BlockDevice
    let fork: ForkMap
    let nodeSize: Int
    let rootNode: UInt32
    let firstLeaf: UInt32
    let depth: Int
    let totalNodes: UInt32
    let maxKeyLength: Int
    let variableIndexKeys: Bool
    let keyCompareType: UInt8

    init(name: String, device: any BlockDevice, fork: ForkMap) throws {
        let header = ByteReader(try fork.read(device, at: 0, count: HeaderLayout.minimumNodeSize))
        let base = HeaderLayout.recordStart
        let kind = Int8(bitPattern: try header.u8(8))
        guard kind == BTreeNode.Kind.header.rawValue else {
            throw ReaderError.corrupt("\(name) B-tree node 0 is not a header node")
        }
        let nodeSize = Int(try header.be16(base + HeaderLayout.nodeSize))
        guard nodeSize >= HeaderLayout.minimumNodeSize, nodeSize <= HeaderLayout.maximumNodeSize,
            nodeSize & (nodeSize - 1) == 0
        else {
            throw ReaderError.corrupt("\(name) B-tree node size \(nodeSize)")
        }
        let totalNodes = try header.be32(base + HeaderLayout.totalNodes)
        guard UInt64(totalNodes) * UInt64(nodeSize) <= fork.logicalSize else {
            throw ReaderError.corrupt(
                "\(name) B-tree has \(totalNodes) nodes but its file is \(fork.logicalSize) bytes")
        }
        let attributes = try header.be32(base + HeaderLayout.attributes)
        guard attributes & Self.bigKeysMask != 0 else {
            throw ReaderError.corrupt("\(name) B-tree without big keys")
        }
        self.name = name
        self.device = device
        self.fork = fork
        self.nodeSize = nodeSize
        self.rootNode = try header.be32(base + HeaderLayout.rootNode)
        self.firstLeaf = try header.be32(base + HeaderLayout.firstLeaf)
        self.depth = Int(try header.be16(base + HeaderLayout.depth))
        self.totalNodes = totalNodes
        self.maxKeyLength = Int(try header.be16(base + HeaderLayout.maxKeyLength))
        self.variableIndexKeys = attributes & Self.variableIndexKeysMask != 0
        self.keyCompareType = try header.u8(base + HeaderLayout.keyCompareType)
        guard depth <= Self.maximumDepth else { throw ReaderError.corrupt("\(name) B-tree depth \(depth)") }
    }

    /// An empty tree has no root (node 0 is the header).
    var isEmpty: Bool { rootNode == 0 }

    func node(_ number: UInt32) throws -> BTreeNode {
        guard number > 0, number < totalNodes else {
            throw ReaderError.corrupt("\(name) B-tree link to node \(number) of \(totalNodes)")
        }
        let bytes = try fork.read(device, at: UInt64(number) * UInt64(nodeSize), count: nodeSize)
        return try BTreeNode(number: number, bytes: bytes)
    }

    /// Splits record `index` of a leaf or index node into key and data.
    func record(_ node: BTreeNode, _ index: Int) throws -> BTreeRecord {
        let range = node.record(index)
        let keyLength = Int(try node.reader.be16(range.lowerBound))
        let storedKeyLength =
            node.kind == .index && !variableIndexKeys ? maxKeyLength : keyLength
        var dataStart = range.lowerBound + Self.keyLengthSize + storedKeyLength
        dataStart += dataStart & 1
        guard dataStart <= range.upperBound else {
            throw ReaderError.corrupt("\(name) B-tree node \(node.number) record \(index) key overruns record")
        }
        return BTreeRecord(
            node: node, index: index, keyStart: range.lowerBound, dataStart: dataStart, end: range.upperBound)
    }

    /// Where a search landed: a leaf node and the index of the first record not less than
    /// the target. `index` may equal the node's record count; `scan` then moves on.
    struct Position {
        let node: BTreeNode
        let index: Int
    }

    /// Descends from the root to the first leaf record whose key is not `isLess`.
    func seek(isLess: (BTreeRecord) throws -> Bool) throws -> Position? {
        guard !isEmpty else { return nil }
        var current = try node(rootNode)
        var level = 0
        while current.kind == .index {
            level += 1
            guard level <= Self.maximumDepth, current.recordCount > 0 else {
                throw ReaderError.corrupt("\(name) B-tree index node \(current.number) is empty or too deep")
            }
            var chosen = try record(current, 0)
            for index in 1..<max(1, current.recordCount) {
                let candidate = try record(current, index)
                guard try isLess(candidate) else { break }
                chosen = candidate
            }
            let child = try chosen.reader.be32(chosen.dataStart)
            let next = try node(child)
            guard next.height + 1 == current.height else {
                throw ReaderError.corrupt("\(name) B-tree node \(child) height \(next.height) under \(current.height)")
            }
            current = next
        }
        guard current.kind == .leaf else {
            throw ReaderError.corrupt("\(name) B-tree search reached a \(current.kind) node")
        }
        var index = 0
        while index < current.recordCount, try isLess(try record(current, index)) { index += 1 }
        return Position(node: current, index: index)
    }

    /// Visits leaf records in key order from `start` (or the first leaf) until `body`
    /// returns false. Follows forward links, visiting at most `totalNodes` nodes so a
    /// looping chain throws instead of hanging.
    func scan(from start: Position? = nil, _ body: (BTreeRecord) throws -> Bool) throws {
        var current: BTreeNode
        var index: Int
        if let start {
            current = start.node
            index = start.index
        } else {
            guard firstLeaf != 0 else { return }
            current = try node(firstLeaf)
            index = 0
        }
        var visited: UInt32 = 1
        while true {
            guard current.kind == .leaf else {
                throw ReaderError.corrupt("\(name) B-tree leaf chain reached a \(current.kind) node")
            }
            while index < current.recordCount {
                guard try body(try record(current, index)) else { return }
                index += 1
            }
            guard current.forwardLink != 0 else { return }
            visited += 1
            guard visited <= totalNodes else {
                throw ReaderError.corrupt("\(name) B-tree leaf chain loops")
            }
            current = try node(current.forwardLink)
            index = 0
        }
    }
}
