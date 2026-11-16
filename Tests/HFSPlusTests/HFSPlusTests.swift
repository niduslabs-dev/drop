import Foundation
import ReaderCore
import Testing

@testable import HFSPlus

/// Compares the reader's full tree against what the kernel showed for the mounted fixture.
@Suite struct FixtureTreeTests {
    @Test(arguments: ["hfsplus", "hfsx"])
    func treeMatchesMountedVolume(_ name: String) throws {
        let volume = try Fixtures.volume(name)
        let manifest = try Fixtures.manifest(name)
        #expect(volume.volumeName == "DropHFS")
        #expect(volume.kind == (name == "hfsx" ? "HFSX" : "HFS+"))
        #expect(volume.isCaseSensitive == (name == "hfsx"))

        let entries = try walk(volume)
        let paths = Set(entries.map(\.path))
        #expect(paths.count == entries.count, "duplicate paths")
        #expect(paths == Set(manifest.keys), "tree differs from the mounted volume")

        var linkGroups: [UInt64: Set<UInt64>] = [:]
        for (path, entry) in entries {
            guard let expected = manifest[path] else { continue }
            let kind: String =
                switch entry.kind {
                case .directory: "directory"
                case .file: "file"
                case .symlink: "symlink"
                case .other: "other"
                }
            #expect(kind == expected.kind, "\(path) kind")
            #expect(entry.mode == expected.mode, "\(path) mode")
            #expect(entry.isCompressed == expected.compressed, "\(path) compressed")

            var names = Set(try volume.xattrs(of: entry).keys)
            if entry.isCompressed {
                // The kernel hides the decmpfs header and payload of compressed files.
                #expect(names.contains("com.apple.decmpfs"), "\(path) decmpfs")
                names.subtract(["com.apple.decmpfs", "com.apple.ResourceFork"])
            }
            #expect(names == Set(expected.xattrs), "\(path) xattrs")

            switch entry.kind {
            case .file where entry.isCompressed:
                #expect(throws: ReaderError.compressedFile(path: entry.name)) { try volume.extents(of: entry) }
            case .file:
                #expect(entry.size == expected.size, "\(path) size")
                #expect(sha256(try volume.contents(of: entry)) == expected.sha256, "\(path) contents")
                if expected.nlink > 1 {
                    #expect(entry.isHardLink, "\(path) hard link")
                    linkGroups[expected.ino, default: []].insert(entry.id)
                } else {
                    #expect(!entry.isHardLink, "\(path) not a hard link")
                }
            case .symlink:
                #expect(try volume.symlinkTarget(of: entry) == expected.target, "\(path) target")
            case .directory, .other:
                break
            }
        }
        #expect(!linkGroups.isEmpty, "fixture has no hard links")
        for (_, ids) in linkGroups { #expect(ids.count == 1, "hard links resolve to one inode") }
    }

    @Test func privateFoldersAreHidden() throws {
        let volume = try Fixtures.volume("hfsplus")
        let names = try volume.children(of: try volume.root).map(\.name)
        #expect(!names.contains { $0.contains("HFS+ Private") })
        #expect(volume.statistics.hardLinks == 2)
    }

    @Test func namesKeepStoredDecomposedForm() throws {
        let volume = try Fixtures.volume("hfsplus")
        let unicode = try #require(try volume.lookup(["unicode"]))
        let names = try volume.children(of: unicode).map(\.name)
        let cafe = try #require(names.first { $0.hasPrefix("caf") })
        // Created NFC; HFS+ stores it decomposed and the reader keeps that.
        #expect(cafe.unicodeScalars.map(\.value).contains(0x0301))
        #expect(!cafe.unicodeScalars.map(\.value).contains(0x00E9))
        #expect(names.contains("colon:name.txt"))
        #expect(names.contains { $0.unicodeScalars.contains("\u{1F600}") })
    }

    @Test func caseOnlyNamesCoexistOnHFSX() throws {
        let volume = try Fixtures.volume("hfsx")
        let folder = try #require(try volume.lookup(["case"]))
        let names = try volume.children(of: folder).map(\.name)
        #expect(Set(names) == ["readme.txt", "README.txt", "ReadMe.txt"])
    }

    @Test func catalogNeedsSeveralLevels() throws {
        let volume = try Fixtures.volume("hfsplus")
        #expect(volume.catalog.depth >= 2, "catalog depth \(volume.catalog.depth)")
        let many = try #require(try volume.lookup(["many"]))
        #expect(try volume.children(of: many).count == 2000)
    }

    @Test func fragmentedFileUsesOverflowExtents() throws {
        let volume = try Fixtures.volume("hfsplus")
        let big = try #require(try volume.lookup(["frag", "big.bin"]))
        let extents = try volume.extents(of: big)
        #expect(extents.count > 8, "big.bin has \(extents.count) extents; overflow file not exercised")
        var offset: UInt64 = 0
        for extent in extents {
            #expect(extent.fileOffset == offset)
            offset += extent.length
        }
        #expect(offset >= big.size)
    }

    @Test func xattrValues() throws {
        let volume = try Fixtures.volume("hfsplus")
        let small = try #require(try volume.lookup(["xattrs", "small.txt"]))
        #expect(try volume.xattrs(of: small)["com.example.small"] == .inline(Array("hello".utf8)))

        let large = try #require(try volume.lookup(["xattrs", "large.txt"]))
        let value = try #require(try volume.xattrs(of: large)["com.example.large"])
        guard case .extents = value else {
            Issue.record("a 5,000-byte xattr should be a fork data record, got \(value)")
            return
        }
        let expected = (0..<5000).map { UInt8(($0 * 7) % 251) }
        #expect(try xattrBytes(value, device: volume.device) == expected)

        let rsrc = try #require(try volume.lookup(["xattrs", "rsrc.txt"]))
        let fork = try #require(try volume.xattrs(of: rsrc)["com.apple.ResourceFork"])
        #expect(try xattrBytes(fork, device: volume.device) == (0..<3000).map { UInt8(($0 * 13) % 256) })
    }

    @Test func compressedFileExposesDecmpfs() throws {
        let volume = try Fixtures.volume("hfsplus")
        let file = try #require(try volume.lookup(["compressed", "text.txt"]))
        #expect(file.isCompressed)
        let header = try xattrBytes(
            try #require(try volume.xattrs(of: file)["com.apple.decmpfs"]), device: volume.device)
        #expect(Array(header.prefix(4)) == Array("fpmc".utf8), "decmpfs magic is 'cmpf' little-endian")
    }

    @Test func wrongEntryKindsThrow() throws {
        let volume = try Fixtures.volume("hfsplus")
        let file = try #require(try volume.lookup(["links", "target.txt"]))
        #expect(throws: ReaderError.notADirectory) { try volume.children(of: file) }
        #expect(throws: ReaderError.notASymlink) { try volume.symlinkTarget(of: file) }
    }

    @Test func parallelReadsMatchSerialReads() async throws {
        let volume = try Fixtures.volume("hfsplus")
        let many = try #require(try volume.lookup(["many"]))
        let files = try volume.children(of: many)
        let serial = try files.map { sha256(try volume.contents(of: $0)) }
        let parallel = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, file) in files.enumerated() {
                group.addTask { (index, sha256(try volume.contents(of: file))) }
            }
            var out = [String](repeating: "", count: files.count)
            for try await (index, hash) in group { out[index] = hash }
            return out
        }
        #expect(parallel == serial)
    }
}

/// Damaged images must throw `corrupt`, never crash or hang.
@Suite struct CorruptInputTests {
    private func image() throws -> (MemoryDevice, HFSPlusVolume) {
        let path = try Fixtures.path("hfsplus.cdr")
        let device = MemoryDevice(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        return (device, try HFSPlusVolume(device: device))
    }

    /// Opens and walks, reading every file; returns the error if any.
    private func openAndWalk(_ device: MemoryDevice) -> (any Error)? {
        do {
            let volume = try HFSPlusVolume(device: device)
            for (_, entry) in try walk(volume, limit: 10_000) where entry.kind == .file && !entry.isCompressed {
                _ = try volume.contents(of: entry)
                _ = try volume.xattrs(of: entry)
            }
            return nil
        } catch {
            return error
        }
    }

    private func catalogNodeOffset(_ volume: HFSPlusVolume, _ node: UInt32) -> Int {
        Int(volume.catalog.fork.extents[0].deviceOffset) + Int(node) * volume.catalog.nodeSize
    }

    @Test func truncatedVolume() throws {
        let (device, _) = try image()
        for size in [512, 1500, 64 * 1024, device.bytes.count / 2] {
            let error = openAndWalk(MemoryDevice(bytes: Array(device.bytes.prefix(size))))
            #expect(error.map(isCorrupt) == true, "truncated to \(size): \(String(describing: error))")
        }
    }

    @Test func badSignatureIsUnsupported() throws {
        var (device, _) = try image()
        device.bytes[1024] = 0x58
        #expect(throws: ReaderError.unsupportedFileSystem("unknown signature 0x582b")) {
            try HFSPlusVolume(device: device)
        }
    }

    @Test func badNodeDescriptor() throws {
        var (device, volume) = try image()
        let kindOffset = 8
        device.bytes[catalogNodeOffset(volume, volume.catalog.rootNode) + kindOffset] = 7
        let error = openAndWalk(device)
        #expect(error.map(isCorrupt) == true, "\(String(describing: error))")

        var (other, _) = try image()
        let recordCountOffset = 10
        other.bytes[catalogNodeOffset(volume, volume.catalog.firstLeaf) + recordCountOffset] = 0xFF
        let second = openAndWalk(other)
        #expect(second.map(isCorrupt) == true, "\(String(describing: second))")
    }

    @Test func loopingLeafChain() throws {
        var (device, volume) = try image()
        let first = volume.catalog.firstLeaf
        let offset = catalogNodeOffset(volume, first)
        withUnsafeBytes(of: first.bigEndian) { device.bytes.replaceSubrange(offset..<offset + 4, with: $0) }
        let error = openAndWalk(device)
        #expect(error.map(isCorrupt) == true, "\(String(describing: error))")
    }

    @Test func loopingIndexPointer() throws {
        var (device, volume) = try image()
        // Point the root index node's first child back at the root.
        let root = volume.catalog.rootNode
        let node = try volume.catalog.node(root)
        let record = try volume.catalog.record(node, 0)
        let offset = catalogNodeOffset(volume, root) + record.dataStart
        withUnsafeBytes(of: root.bigEndian) { device.bytes.replaceSubrange(offset..<offset + 4, with: $0) }
        let error = openAndWalk(device)
        #expect(error.map(isCorrupt) == true, "\(String(describing: error))")
    }

    @Test func randomCatalogDamageNeverCrashes() throws {
        let (device, volume) = try image()
        let start = Int(volume.catalog.fork.extents[0].deviceOffset)
        let length = Int(volume.catalog.fork.extents[0].length)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            var damaged = device
            for _ in 0..<16 {
                damaged.bytes[start + Int.random(in: 0..<length, using: &generator)] = UInt8.random(
                    in: 0...255, using: &generator)
            }
            _ = openAndWalk(damaged)
        }
    }

    @Test func hfsWrapperOpensEmbeddedVolume() throws {
        let (device, _) = try image()
        let prefixSize = 64 * 1024
        let wrapperBlockSize: UInt32 = 4096
        var bytes = [UInt8](repeating: 0, count: prefixSize) + device.bytes
        func put16(_ value: UInt16, _ at: Int) {
            bytes[1024 + at] = UInt8(value >> 8)
            bytes[1024 + at + 1] = UInt8(value & 0xFF)
        }
        put16(0x4244, 0)
        put16(UInt16(wrapperBlockSize >> 16), 0x14)
        put16(UInt16(wrapperBlockSize & 0xFFFF), 0x16)
        put16(0, 0x1C)
        put16(0x482B, 0x7C)
        put16(UInt16(prefixSize / Int(wrapperBlockSize)), 0x7E)
        put16(UInt16(device.bytes.count / Int(wrapperBlockSize)), 0x80)
        let volume = try HFSPlusVolume(device: MemoryDevice(bytes: bytes))
        #expect(volume.volumeName == "DropHFS")
        let deep = try #require(try volume.lookup(["a", "b", "c", "d", "e", "deep.txt"]))
        #expect(try volume.contents(of: deep) == Array("deep\n".utf8))
    }
}
