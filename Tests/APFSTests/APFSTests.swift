import Foundation
import ReaderCore
import Testing

@testable import APFS

@Suite struct SyntheticImageTests {
    static let variants = ["ci", "cs"]

    @Test func lruEvictsLeastRecentlyUsed() {
        var cache = LRUCache<Int, Int>(capacity: 2)
        cache.insert(1, for: 1)
        cache.insert(2, for: 2)
        _ = cache.value(for: 1)
        cache.insert(3, for: 3)
        #expect(cache.value(for: 1) == 1)
        #expect(cache.value(for: 2) == nil)
        #expect(cache.value(for: 3) == 3)
    }

    @Test(arguments: variants) func volumeInfo(variant: String) throws {
        let container = try APFSContainer(device: try FileDevice(path: try Fixtures.path("\(variant).img")))
        #expect(container.volumes.count == 1)
        let volume = try #require(container.volumes.first)
        #expect(volume.name == "DropAPFS")
        #expect(!volume.isEncrypted)
        #expect(!volume.isSealed)
        #expect(volume.isCaseInsensitive == (variant == "ci"))
        #expect(try container.openDefaultVolume().volumeName == "DropAPFS")
    }

    /// Walks the whole tree and checks every item against the manifest recorded from the
    /// mounted image: names (byte-exact), kinds, modes, sizes, inode IDs, hard links,
    /// compression, symlink targets, xattrs and file contents.
    @Test(arguments: variants) func treeMatchesManifest(variant: String) throws {
        let manifest = try Fixtures.manifest("\(variant)-manifest.jsonl")
        let fs = try APFSContainer(device: try FileDevice(path: try Fixtures.path("\(variant).img")))
            .openDefaultVolume()
        let entries = try walk(fs)
        let show = { (path: [UInt8]) in String(decoding: path, as: UTF8.self) }
        let missing = Set(manifest.keys).subtracting(entries.keys).map(show).sorted()
        let extra = Set(entries.keys).subtracting(manifest.keys).map(show).sorted()
        #expect(missing.isEmpty, "not listed by the reader: \(missing)")
        #expect(extra.isEmpty, "listed but not in the manifest: \(extra)")
        #expect(entries.count > 2000)

        for (path, row) in manifest {
            guard let entry = entries[path] else { continue }
            let name = show(path)
            #expect("\(entry.kind)" == row.kind, "\(name)")
            #expect(entry.mode == row.mode, "\(name) mode \(String(entry.mode, radix: 8))")
            #expect(entry.id == row.ino, "\(name)")
            #expect(entry.isCompressed == row.isCompressed, "\(name)")
            #expect(entry.isHardLink == (row.kind == "file" && row.nlink > 1), "\(name)")
            if entry.kind == .file, !row.isCompressed {
                #expect(entry.size == row.size, "\(name)")
                #expect(sha256(try fs.contents(of: entry)) == row.sha256, "\(name) contents")
            }
            if entry.kind == .symlink {
                #expect(try fs.symlinkTarget(of: entry) == row.target, "\(name)")
            }
            let xattrs = try fs.xattrs(of: entry)
            #expect(Set(xattrs.keys) == Set(row.xattrs.keys), "\(name) xattrs")
            for (key, expected) in row.xattrs {
                guard let value = xattrs[key] else { continue }
                let bytes: [UInt8]
                switch value {
                case .inline(let inline): bytes = inline
                case .extents(let extents, let size): bytes = try readExtents(fs, extents, size: size)
                }
                #expect(bytes.count == expected.size && sha256(bytes) == expected.sha256, "\(name) xattr \(key)")
            }
        }
    }

    @Test func extentsHolesAndCompression() throws {
        let fs = try APFSContainer(device: try FileDevice(path: try Fixtures.path("ci.img"))).openDefaultVolume()
        let fragmented = try #require(try fs.lookup(["fragmented.bin"]))
        #expect(try fs.extents(of: fragmented).count > 1, "fragmented.bin should span several extents")

        let sparse = try #require(try fs.lookup(["sparse.bin"]))
        let extents = try fs.extents(of: sparse)
        #expect(extents.contains { $0.isHole }, "sparse.bin should have a hole")
        #expect(extents.reduce(0) { $0 + $1.length } >= sparse.size)
        let contents = try fs.contents(of: sparse)
        #expect(contents.prefix(4) == Array("head".utf8)[...])
        #expect(contents.suffix(4) == Array("tail".utf8)[...])

        let compressed = try #require(try fs.lookup(["compressed-in-image", "big.txt"]))
        #expect(compressed.isCompressed)
        #expect(throws: ReaderError.compressedFile(path: "/compressed-in-image/big.txt")) {
            try fs.extents(of: compressed)
        }
        let xattrs = try fs.xattrs(of: compressed)
        #expect(xattrs["com.apple.decmpfs"] != nil)

        let hardA = try #require(try fs.lookup(["hard-a.txt"]))
        let hardB = try #require(try fs.lookup(["hard-b.txt"]))
        #expect(hardA.id == hardB.id && hardA.isHardLink)
        let siblings = try fs.siblingLinks(of: hardA).map(\.name).sorted()
        #expect(siblings == ["hard-a.txt", "hard-b.txt"])

        let link = try #require(try fs.lookup(["link-absolute"]))
        #expect(try fs.symlinkTarget(of: link) == "/nonexistent/absolute/target")
        #expect(try fs.xattrs(of: link)["com.apple.fs.symlink"] == nil)
        #expect(throws: ReaderError.notADirectory) { try fs.children(of: link) }
        #expect(throws: ReaderError.notASymlink) { try fs.symlinkTarget(of: hardA) }
    }

    @Test func caseSensitiveNamesStayDistinct() throws {
        let fs = try APFSContainer(device: try FileDevice(path: try Fixtures.path("cs.img"))).openDefaultVolume()
        let directory = try #require(try fs.lookup(["case"]))
        #expect(try fs.children(of: directory).map(\.name).sorted() == ["Name.txt", "name.txt"])
    }

    @Test func unicodeNamesKeepStoredBytes() throws {
        let fs = try APFSContainer(device: try FileDevice(path: try Fixtures.path("ci.img"))).openDefaultVolume()
        let nfc = try #require(try fs.lookup(["unicode", "nfc"]))
        let nfd = try #require(try fs.lookup(["unicode", "nfd"]))
        #expect(try fs.children(of: nfc).map { Array($0.name.utf8) } == [Array("caf\u{e9}.txt".utf8)])
        #expect(try fs.children(of: nfd).map { Array($0.name.utf8) } == [Array("cafe\u{301}.txt".utf8)])
    }

    /// Reads every file from many threads at once through one volume and compares with
    /// a serial read.
    @Test func parallelReadsAgree() async throws {
        let fs = try APFSContainer(device: try FileDevice(path: try Fixtures.path("ci.img"))).openDefaultVolume()
        let files = try walk(fs).values.filter { $0.kind == .file && !$0.isCompressed }
        let serial = try Dictionary(
            files.map { ($0.id, sha256(try fs.contents(of: $0))) }, uniquingKeysWith: { a, _ in a })
        let parallel = try await withThrowingTaskGroup(of: (UInt64, String).self) { group in
            for file in files { group.addTask { (file.id, sha256(try fs.contents(of: file))) } }
            var result: [UInt64: String] = [:]
            for try await (id, hash) in group { result[id] = hash }
            return result
        }
        #expect(parallel == serial)
    }
}

private func readExtents(_ fs: any FileSystem, _ extents: [Extent], size: UInt64) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(size))
    for extent in extents where !extent.isHole && extent.fileOffset < size {
        let start = Int(extent.fileOffset)
        let length = Int(min(extent.length, size - extent.fileOffset))
        try out.withUnsafeMutableBytes {
            try fs.device.read(
                at: extent.deviceOffset, into: UnsafeMutableRawBufferPointer(rebasing: $0[start..<start + length]))
        }
    }
    return out
}

/// Damaged images must throw `corrupt`, never crash or hang.
@Suite(.timeLimit(.minutes(1))) struct CorruptionTests {
    static func image() throws -> [UInt8] {
        Array(try Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("ci.img"))))
    }

    static func openAndWalk(_ bytes: [UInt8]) throws {
        let fs = try APFSContainer(device: MemoryDevice(bytes: bytes)).openDefaultVolume()
        for entry in try walk(fs).values where entry.kind == .file && !entry.isCompressed {
            _ = try fs.contents(of: entry)
        }
    }

    /// Physical block of the volume's fs-tree root node.
    static func fsRootBlock(_ bytes: [UInt8]) throws -> (block: UInt64, blockSize: Int) {
        let container = try APFSContainer(device: MemoryDevice(bytes: bytes))
        let volume = try container.openDefaultVolume()
        guard case .virtual(let map) = volume.tree.addressing else {
            throw ReaderError.corrupt("expected a virtual fs tree")
        }
        return (try map.physicalAddress(of: volume.tree.rootOID), container.blockSize)
    }

    static func reseal(_ bytes: inout [UInt8], block: UInt64, blockSize: Int) {
        let start = Int(block) * blockSize
        let checksum = ObjectStore.fletcher64(Array(bytes[start..<start + blockSize]))
        bytes.storeLE64(checksum, at: start)
    }

    @Test func badSuperblockChecksum() throws {
        var bytes = try Self.image()
        bytes[200] ^= 0xFF
        expectCorrupt("block-zero superblock with a bad checksum") { try Self.openAndWalk(bytes) }
    }

    @Test func badNodeChecksum() throws {
        var bytes = try Self.image()
        let (block, blockSize) = try Self.fsRootBlock(bytes)
        bytes[Int(block) * blockSize + blockSize / 2] ^= 0xFF
        expectCorrupt("fs-tree root with a bad checksum") { try Self.openAndWalk(bytes) }
    }

    @Test(arguments: [1, 2, 4, 8]) func truncated(divisor: Int) throws {
        let bytes = try Self.image()
        let device = MemoryDevice(bytes: Array(bytes.prefix(bytes.count / divisor)))
        if divisor == 1 {
            try Self.openAndWalk(device.bytes)
            return
        }
        expectCorrupt("image cut to 1/\(divisor)") { try Self.openAndWalk(device.bytes) }
    }

    @Test func tooSmall() {
        expectCorrupt("a few bytes") {
            _ = try APFSContainer(device: MemoryDevice(bytes: [UInt8](repeating: 0, count: 100)))
        }
    }

    /// An index node whose first child points back at the root, with a valid checksum.
    @Test func loopingTree() throws {
        var bytes = try Self.image()
        let (block, blockSize) = try Self.fsRootBlock(bytes)
        let start = Int(block) * blockSize
        let node = try BTreeNode(ByteReader(Array(bytes[start..<start + blockSize])))
        try #require(!node.isLeaf, "fs-tree root is a leaf; the fixture needs more files")
        let value = try node.record(0, fixedKeySize: 0, fixedValueSize: 0).value
        bytes.storeLE64(node.oid, at: start + value.lowerBound)
        Self.reseal(&bytes, block: block, blockSize: blockSize)
        expectCorrupt("index node pointing at the root") { try Self.openAndWalk(bytes) }
    }

    /// A node claiming more records than fit, with a valid checksum.
    @Test func oversizedKeyCount() throws {
        var bytes = try Self.image()
        let (block, blockSize) = try Self.fsRootBlock(bytes)
        let start = Int(block) * blockSize
        bytes[start + Format.BTree.keyCount + 2] = 0xFF
        Self.reseal(&bytes, block: block, blockSize: blockSize)
        expectCorrupt("node with a huge key count") { try Self.openAndWalk(bytes) }
    }

    /// Random bytes after a valid-looking magic: must throw, never trap.
    @Test func randomGarbage() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var bytes = (0..<(64 * 4096)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            bytes.storeLE64(UInt64(Format.Container.magicValue), at: Format.Container.magic)
            bytes[Format.Container.magic + 4] = 0
            bytes.storeLE64(4096, at: Format.Container.blockSize)
            do {
                try Self.openAndWalk(bytes)
                Issue.record("garbage opened")
            } catch {}
        }
    }
}

/// The APFS sample DMGs, converted to raw by `scripts/fixtures-apfs.sh --corpus`.
@Suite(.enabled(if: Fixtures.corpusEnabled || Fixtures.timingEnabled)) struct APFSCorpusTests {
    struct SurveyCounts {
        let files: Int
        let symlinks: Int
    }

    static func survey(_ name: String) throws -> SurveyCounts {
        let path = Fixtures.packageRoot.appendingPathComponent(".claude/research/scripts/survey.jsonl").path
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        where line.contains("samples/\(name)/") {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let filesystems = object?["filesystems"] as? [[String: Any]] ?? []
            for fs in filesystems {
                for volume in fs["volumes"] as? [[String: Any]] ?? [] {
                    let stats = volume["stats"] as? [String: Int] ?? [:]
                    return SurveyCounts(files: stats["files"] ?? 0, symlinks: stats["symlinks"] ?? 0)
                }
            }
        }
        throw Fixtures.Missing(path: "survey entry for \(name)")
    }

    static func open(_ name: String) throws -> APFSVolume {
        let disk = try FileDevice(path: try Fixtures.path("corpus/\(name).img"))
        return try APFSContainer(device: try apfsPartition(of: disk)).openDefaultVolume()
    }

    @Test(.enabled(if: Fixtures.corpusEnabled), arguments: ["gimp", "warp", "zed"])
    func countsMatchSurvey(name: String) throws {
        let fs = try Self.open(name)
        let entries = try walk(fs).values
        let files = Set(entries.filter { $0.kind == .file }.map(\.id)).count
        let symlinks = Set(entries.filter { $0.kind == .symlink }.map(\.id)).count
        let expected = try Self.survey(name)
        #expect(files == expected.files, "\(name) files")
        #expect(symlinks == expected.symlinks, "\(name) symlinks")
        for entry in entries where entry.kind == .symlink { _ = try fs.symlinkTarget(of: entry) }
        print("corpus \(name): \(files) files, \(symlinks) symlinks (survey \(expected.files)/\(expected.symlinks))")
    }

    @Test(.enabled(if: Fixtures.timingEnabled)) func gimpWalkAndReadThroughput() throws {
        let clock = ContinuousClock()
        var files = 0
        var bytes: UInt64 = 0
        let elapsed = try clock.measure {
            let fs = try Self.open("gimp")
            for entry in try walk(fs).values where entry.kind == .file && !entry.isCompressed {
                try fs.read(entry) { _, chunk in bytes += UInt64(chunk.count) }
                files += 1
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(files) / seconds
        let megabytes = Double(bytes) / 1_048_576
        print(
            String(
                format: "gimp: %d files, %.1f MiB in %.2f s: %.0f files/s, %.0f MiB/s",
                files, megabytes, seconds, rate, megabytes / seconds))
    }
}
