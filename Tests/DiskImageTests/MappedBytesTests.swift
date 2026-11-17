import CryptoKit
import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import DiskImage

/// Decoded chunks live in `MappedBytes`: each codec still decodes exactly what hdiutil does,
/// a damaged chunk throws instead of exposing stale or short bytes, and every mapping is gone
/// once the reader that made it is.
@Suite struct MappedBytesTests {
    /// One fixture per compressed chunk type.
    static let codecs: [(format: String, type: ChunkType)] = [
        ("UDZO", .zlib), ("UDBZ", .bzip2), ("ULFO", .lzfse), ("ULMO", .lzma), ("UDCO", .adc),
    ]
    static let formats = codecs.map(\.format)
    static let layouts = ["hfs-GPTSPUD", "apfs-GPTSPUD"]
    /// Reads of this size walk the disk the way the Extractor's stream buffers do.
    static let readSize = 1 << 20
    /// How long a test waits for decode workers still running to drop their last reference.
    static let releaseDeadline: Duration = .seconds(5)
    static let pollInterval: Duration = .milliseconds(10)

    struct Opened {
        let path: String
        let udif: UDIFDevice
        let reference: [UInt8]
    }

    static func open(_ name: String) throws -> Opened {
        let path = try Fixtures.path("\(name).dmg")
        let udif = try #require(try DiskImage.open(path: path).udif)
        let reference = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("\(name).dmg.cdr"))))
        try #require(udif.size == UInt64(reference.count))
        return Opened(path: path, udif: udif, reference: reference)
    }

    /// A second device over the same file and chunk table, with a smaller cache or edited chunks.
    static func device(
        _ opened: Opened, chunks: [Chunk]? = nil, cacheLimit: Int = UDIFDevice.defaultCacheLimit,
        policy: DecodePolicy = .fast
    ) throws -> UDIFDevice {
        try UDIFDevice(
            file: FileDevice(path: opened.path), size: opened.udif.size, tables: opened.udif.tables,
            chunks: chunks ?? opened.udif.chunks, cacheLimit: cacheLimit, decodePolicy: policy)
    }

    static func digest(_ bytes: some Sequence<UInt8>) -> SHA256.Digest { SHA256.hash(data: Array(bytes)) }

    static func waitForZero(_ regions: MappedRegions) async -> Int {
        let deadline = ContinuousClock.now + releaseDeadline
        while regions.count != 0, ContinuousClock.now < deadline { try? await Task.sleep(for: pollInterval) }
        return regions.count
    }

    /// Every codec, read through the cache in 1 MiB reads, hashes the same as hdiutil's raw copy.
    @Test(arguments: layouts, formats)
    func readPathMatchesReferenceChecksum(_ layout: String, _ format: String) throws {
        let opened = try Self.open("\(layout)-\(format)")
        var hasher = SHA256()
        var offset = 0
        while offset < opened.reference.count {
            let count = min(Self.readSize, opened.reference.count - offset)
            hasher.update(data: try opened.udif.read(at: UInt64(offset), count: count))
            offset += count
        }
        #expect(hasher.finalize() == Self.digest(opened.reference))
    }

    /// Each buffer is exactly its chunk's length, including a chunk shorter than the rest
    /// (the last of a table), so nothing past the real data is ever exposed.
    @Test(arguments: formats)
    func buffersHaveTheChunksExactLength(_ format: String) throws {
        let opened = try Self.open("hfs-GPTSPUD-\(format)")
        let file = try FileDevice(path: opened.path)
        let compressed = opened.udif.chunks.filter { !$0.type.isZeroFill && $0.type != .raw }
        let longest = try #require(compressed.map(\.length).max())
        let short = try #require(compressed.last { $0.length < longest }, "no short chunk in \(format)")
        for chunk in [compressed[0], short] {
            let bytes = try UDIFDevice.decode(chunk, from: file, regions: nil)
            #expect(bytes.count == Int(chunk.length))
            let start = Int(chunk.deviceOffset)
            bytes.withUnsafeBytes { decoded in
                #expect(Self.digest(decoded) == Self.digest(opened.reference[start..<start + Int(chunk.length)]))
            }
        }
    }

    /// A chunk whose stored bytes are cut in half throws `corrupt` for every codec, on every
    /// read, and leaves nothing mapped.
    @Test(arguments: zip(codecs.map(\.format), codecs.map(\.type)))
    func truncatedChunkThrows(_ format: String, _ type: ChunkType) throws {
        let opened = try Self.open("hfs-GPTSPUD-\(format)")
        let victim = try #require(opened.udif.chunks.first { $0.type == type && $0.fileLength > 1 })
        let chunks = opened.udif.chunks.map { chunk in
            chunk.index != victim.index
                ? chunk
                : Chunk(
                    index: chunk.index, type: chunk.type, deviceOffset: chunk.deviceOffset, length: chunk.length,
                    fileOffset: chunk.fileOffset, fileLength: chunk.fileLength / 2)
        }
        // No read-ahead: the repeated read would count as a stream and map the next chunks.
        let device = try Self.device(
            opened, chunks: chunks, policy: DecodePolicy(maxDecoders: 1, qos: .userInitiated, readAheadBytes: 0))
        for _ in 0..<2 {
            #expect {
                _ = try device.read(at: victim.deviceOffset, count: Int(victim.length))
            } throws: { error in
                guard case .corrupt = error as? ReaderError else { return false }
                return true
            }
        }
        #expect(device.mappedRegions.count == 0, "a failed decode left a mapping behind")
    }

    /// Many readers over a cache a few chunks big, so eviction races every read; each read's
    /// checksum matches the reference.
    @Test(arguments: formats)
    func concurrentReadersOverATinyCache(_ format: String) throws {
        let opened = try Self.open("apfs-GPTSPUD-\(format)")
        let compressed = opened.udif.chunks.filter { !$0.type.isZeroFill && $0.type != .raw }
        let longest = Int(try #require(compressed.map(\.length).max()))
        let cacheChunks = 3
        let device = try Self.device(
            opened, cacheLimit: longest * cacheChunks,
            policy: DecodePolicy(maxDecoders: 4, qos: .userInitiated, readAheadBytes: longest * 2))
        let readers = 8
        let readsPerReader = 40
        let total = opened.reference.count
        let maxRead = min(longest + longest / 2, total)
        let mismatches = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            var random = SystemRandomNumberGenerator()
            for _ in 0..<readsPerReader {
                let count = Int.random(in: 1...maxRead, using: &random)
                let offset = Int.random(in: 0...(total - count), using: &random)
                let bytes = try? device.read(at: UInt64(offset), count: count)
                if bytes.map({ Self.digest($0) != Self.digest(opened.reference[offset..<offset + count]) }) ?? true {
                    mismatches.wrappingAdd(1, ordering: .relaxed)
                }
            }
            // Then half the readers stream through the disk, so read-ahead races the rest.
            if reader.isMultiple(of: 2) {
                var offset = reader * longest % total
                while offset < total {
                    let count = min(longest, total - offset)
                    let bytes = try? device.read(at: UInt64(offset), count: count)
                    if bytes.map({ Self.digest($0) != Self.digest(opened.reference[offset..<offset + count]) })
                        ?? true
                    {
                        mismatches.wrappingAdd(1, ordering: .relaxed)
                    }
                    offset += count
                }
            }
        }
        #expect(mismatches.load(ordering: .relaxed) == 0)
    }

    /// Shrinking the cache to nothing unmaps what it held; releasing the device unmaps the rest.
    @Test(arguments: formats)
    func buffersAreUnmappedWhenTheCacheOrReaderGoes(_ format: String) async throws {
        let opened = try Self.open("hfs-GPTSPUD-\(format)")
        var device: UDIFDevice? = try Self.device(opened)
        let regions = try #require(device).mappedRegions
        _ = try device?.read(at: 0, count: opened.reference.count)
        #expect(regions.count > 0, "the cache holds decoded chunks")

        let empty = DecodePolicy(maxDecoders: 1, qos: .utility, readAheadBytes: 0, cacheBytes: 0)
        device?.decodePolicy = empty
        #expect(await Self.waitForZero(regions) == 0, "trimming the cache left mappings behind")

        device?.decodePolicy = .fast
        _ = try device?.read(at: 0, count: opened.reference.count)
        #expect(regions.count > 0)
        device = nil
        #expect(await Self.waitForZero(regions) == 0, "releasing the reader left mappings behind")
    }
}
