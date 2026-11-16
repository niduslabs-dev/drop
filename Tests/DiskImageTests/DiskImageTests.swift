import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import DiskImage

/// Fixtures from `scripts/fixtures-diskimage.sh`, in `.build/fixtures/diskimage/`.
enum Fixtures {
    /// The package root, or `DROP_PACKAGE_ROOT` when the tests run from a copy of the sources.
    static let packageRoot =
        ProcessInfo.processInfo.environment["DROP_PACKAGE_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let directory = packageRoot.appendingPathComponent(".build/fixtures/diskimage")
    static let samples = packageRoot.appendingPathComponent(".claude/samples")

    static let formats = ["UDZO", "UDBZ", "ULFO", "ULMO", "UDCO", "UDRO", "UDRW", "UDTO"]
    static let layouts = ["hfs-GPTSPUD", "hfs-SPUD", "hfs-NONE", "apfs-GPTSPUD", "apfs-NONE"]
    static let images = layouts.flatMap { layout in formats.map { "\(layout)-\($0)" } }

    static func path(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            Issue.record("Missing fixture \(name). Run scripts/fixtures-diskimage.sh first.")
            throw FixtureMissing()
        }
        return path
    }

    struct FixtureMissing: Error {}

    static var corpusEnabled: Bool { ProcessInfo.processInfo.environment["DROP_CORPUS"] == "1" }
}

/// Collects decoded runs into one buffer from several threads; each run is a disjoint range.
final class DiskBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawBufferPointer

    init(size: Int) {
        pointer = .allocate(byteCount: size, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0)
    }

    deinit { pointer.deallocate() }

    func write(_ offset: UInt64, _ bytes: UnsafeRawBufferPointer) {
        UnsafeMutableRawBufferPointer(rebasing: pointer[Int(offset)..<Int(offset) + bytes.count]).copyMemory(
            from: bytes)
    }

    var bytes: [UInt8] { Array(pointer) }
}

@Suite struct FormatTests {
    @Test(arguments: Fixtures.images)
    func decodesWholeDiskLikeHdiutil(_ name: String) throws {
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        var reference = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("\(name).dmg.cdr"))))
        // hdiutil's UDTO conversion drops trailing free space from APM disks, so the
        // reference can be shorter than the disk; the missing tail must be zeros.
        #expect(image.device.size >= UInt64(reference.count))
        if name.contains("-SPUD-") {
            reference += [UInt8](repeating: 0, count: Int(image.device.size) - reference.count)
        } else {
            #expect(image.device.size == UInt64(reference.count))
        }

        let sequential = try image.device.read(at: 0, count: Int(image.device.size))
        #expect(sequential == reference, "sequential read differs from hdiutil's raw conversion")

        if let udif = image.udif {
            let buffer = DiskBuffer(size: Int(udif.size))
            try udif.decodeAll(maxConcurrency: 4) { offset, bytes in buffer.write(offset, bytes) }
            #expect(buffer.bytes == reference, "parallel decode differs from hdiutil's raw conversion")
        } else {
            #expect(name.hasSuffix("UDRW") || name.hasSuffix("UDTO"), "only raw formats open without a trailer")
        }
    }

    @Test(arguments: Fixtures.images)
    func findsFileSystem(_ name: String) throws {
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        let map = try image.partitionMap()
        let location = try image.fileSystem()
        let expectedKind: FileSystemLocation.Kind = name.hasPrefix("apfs") ? .apfs : .hfsPlus
        #expect(location.kind == expectedKind)
        if name.contains("GPTSPUD") {
            #expect(map.scheme == .gpt)
            #expect(location.partition != nil)
        } else if name.contains("-SPUD") {
            #expect(map.scheme == .apm)
            #expect(location.partition != nil)
        } else {
            #expect(map.scheme == .none)
            #expect(location.partition == nil)
        }
    }

    /// Many threads reading overlapping ranges through the shared cache see the right bytes.
    @Test(arguments: ["hfs-GPTSPUD-UDZO", "apfs-GPTSPUD-ULMO"])
    func concurrentReadsAgree(_ name: String) throws {
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        let reference = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("\(name).dmg.cdr"))))
        let device = image.device
        let mismatches = Atomic<Int>(0)
        let readLength = 70_000
        let stride = 9_973
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            var offset = worker * 4_099
            while offset + readLength <= reference.count {
                let bytes = try? device.read(at: UInt64(offset), count: readLength)
                if bytes.map({ $0[...] != reference[offset..<offset + readLength] }) ?? true {
                    mismatches.wrappingAdd(1, ordering: .relaxed)
                }
                offset += stride * 8
            }
        }
        #expect(mismatches.load(ordering: .relaxed) == 0)
    }

    @Test func compressedFormatsUseTheirCodec() throws {
        let expected: [String: ChunkType] = [
            "UDZO": .zlib, "UDBZ": .bzip2, "ULFO": .lzfse, "ULMO": .lzma, "UDCO": .adc, "UDRO": .raw,
        ]
        for (format, type) in expected {
            let image = try DiskImage.open(path: try Fixtures.path("hfs-GPTSPUD-\(format).dmg"))
            let types = Set(try #require(image.udif).chunks.map(\.type))
            #expect(types.contains(type), "\(format) has \(types)")
        }
    }

    @Test func smallReadsAcrossChunkBoundaries() throws {
        let image = try DiskImage.open(path: try Fixtures.path("hfs-GPTSPUD-UDZO.dmg"))
        let reference = try [UInt8](
            Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("hfs-GPTSPUD-UDZO.dmg.cdr"))))
        let udif = try #require(image.udif)
        for chunk in udif.chunks where chunk.deviceOffset >= 100 {
            let start = Int(chunk.deviceOffset) - 100
            #expect(try udif.read(at: UInt64(start), count: 333) == Array(reference[start..<start + 333]))
        }
        #expect(throws: ReaderError.outOfBounds) { try udif.read(at: udif.size - 1, count: 2) }
    }
}

@Suite struct ContainerTests {
    @Test func encryptedImageIsRefused() throws {
        #expect(throws: ReaderError.encrypted) { try DiskImage.open(path: try Fixtures.path("encrypted.dmg")) }
    }

    @Test func sparseImageIsRefused() throws {
        #expect(throws: ReaderError.sparseImage) { try DiskImage.open(path: try Fixtures.path("sparse.sparseimage")) }
    }

    @Test func signatureAreaIsReported() throws {
        let signed = try DiskImage.open(path: try Fixtures.path("signed.dmg"))
        let area = try #require(signed.codeSignature)
        #expect(area.length > 0)
        let unsigned = try DiskImage.open(path: try Fixtures.path("hfs-GPTSPUD-UDZO.dmg"))
        #expect(unsigned.codeSignature == nil)
        #expect(unsigned.licence == nil)
    }

    /// Damaged trailers, plists and tables must throw `corrupt`, never crash or hang.
    @Test func corruptionThrowsCorrupt() throws {
        let original = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("hfs-GPTSPUD-UDZO.dmg"))))
        let trailer = original.count - UDIFTrailer.size
        let reader = ByteReader(original)
        let xmlOffset = Int(try reader.be64(trailer + 216))

        func expectCorrupt(_ label: String, _ mutate: (inout [UInt8]) -> Void) {
            var bytes = original
            mutate(&bytes)
            do {
                let image = try DiskImage.open(file: MemoryDevice(bytes))
                _ = try image.device.read(at: 0, count: Int(image.device.size))
                Issue.record("\(label): opened and decoded without error")
            } catch let error as ReaderError {
                if case .corrupt = error {} else { Issue.record("\(label): threw \(error), wanted corrupt") }
            } catch {
                Issue.record("\(label): threw \(error)")
            }
        }

        expectCorrupt("plist offset past end") { b in for i in 0..<8 { b[trailer + 216 + i] = 0x7F } }
        expectCorrupt("plist length huge") { b in for i in 0..<8 { b[trailer + 224 + i] = 0xFF } }
        expectCorrupt("garbled plist") { b in for i in 0..<64 { b[xmlOffset + 40 + i] = 0x3C } }
        expectCorrupt("bad header size") { b in b[trailer + 10] = 0 }
        expectCorrupt("compressed data garbled") { b in for i in 0..<4096 { b[1024 + i] ^= 0x5A } }
        expectCorrupt("plist cut short") { b in
            for i in 0..<8 { b[trailer + 224 + i] = 0 }
            b[trailer + 231] = 100
        }
    }

    @Test func noTrailerOpensAsRaw() throws {
        let image = try DiskImage.open(file: MemoryDevice([UInt8](repeating: 0, count: 4096)))
        #expect(image.container == .raw)
        #expect(throws: ReaderError.self) { try image.fileSystem() }
        #expect(try DiskImage.open(file: MemoryDevice([1, 2, 3])).container == .raw)
    }

    @Test func licenceResourcesParse() throws {
        let lpic: [UInt8] = [0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 14, 0, 1, 0, 1]
        var strings: [UInt8] = [0, 2]
        for word in ["English", "Agree"] { strings += [UInt8(word.utf8.count)] + Array(word.utf8) }
        let resources: [String: [[String: Any]]] = [
            "LPic": [["ID": "5000", "Data": lpic]],
            "RTF ": [["ID": "5000", "Data": Array("{\\rtf1}".utf8)]],
            "STR#": [["ID": "5000", "Data": strings]],
            "TEXT": [["ID": "5001", "Data": Array("hello".utf8)]],
        ]
        let licence = try #require(try LicenceAgreement(resources: resources))
        #expect(licence.languages.count == 2)
        #expect(licence.languages[0].body == .rtf(Array("{\\rtf1}".utf8)))
        #expect(licence.languages[0].buttons == ["English", "Agree"])
        #expect(licence.languages[1].regionCode == 14)
        #expect(licence.languages[1].isMultiByte)
        #expect(licence.languages[1].body == .plain(bytes: Array("hello".utf8), text: "hello"))

        #expect(throws: ReaderError.self) {
            _ = try LicenceAgreement(resources: ["LPic": [["ID": "5000", "Data": [UInt8](arrayLiteral: 0, 0, 0, 9)]]])
        }
        #expect(try LicenceAgreement(resources: [:]) == nil)
    }
}

@Suite struct UnitTests {
    @Test func adcDecodesAllOpcodes() throws {
        // Literal "abc", short match (3 back, 4 long), long match (1 back, 5 long, overlapping).
        let input: [UInt8] = [0x82, 0x61, 0x62, 0x63, 0x04, 0x02, 0x41, 0x00, 0x00]
        var output = [UInt8](repeating: 0, count: 12)
        try input.withUnsafeBytes { source in try output.withUnsafeMutableBytes { try Decoders.adc(source, $0) } }
        #expect(String(decoding: output, as: UTF8.self) == "abcabcaaaaaa")

        var short = [UInt8](repeating: 0, count: 4)
        #expect(throws: ReaderError.self) {
            try [UInt8]([0x04, 0x02]).withUnsafeBytes { s in
                try short.withUnsafeMutableBytes { try Decoders.adc(s, $0) }
            }
        }
    }

    @Test func cacheEvictsByBytes() {
        var cache = ChunkCache(limit: 10)
        cache.put(1, [UInt8](repeating: 1, count: 4))
        cache.put(2, [UInt8](repeating: 2, count: 4))
        _ = cache.get(1)
        cache.put(3, [UInt8](repeating: 3, count: 4))
        #expect(cache.get(2) == nil)
        #expect(cache.get(1) != nil)
        #expect(cache.get(3) != nil)
        #expect(cache.total == 8)
        cache.put(4, [UInt8](repeating: 4, count: 11))
        #expect(cache.get(4) == nil)
    }

    @Test func unknownChunkTypeIsUnsupported() {
        #expect(throws: ReaderError.unsupportedCompression(0x8000_0009)) { try ChunkType.from(code: 0x8000_0009) }
    }
}

@Suite(.enabled(if: Fixtures.corpusEnabled, "set DROP_CORPUS=1 to read .claude/samples"))
struct CorpusTests {
    static let dmgs: [String] = {
        guard let walker = FileManager.default.enumerator(atPath: Fixtures.samples.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".dmg") }.sorted()
    }()

    @Test(arguments: dmgs)
    func opensAndFindsFileSystem(_ relative: String) throws {
        let image = try DiskImage.open(path: Fixtures.samples.appendingPathComponent(relative).path)
        #expect(image.container == .udif)
        let location = try image.fileSystem()
        let head = try location.device.read(at: 0, count: 2048)
        switch location.kind {
        case .apfs: #expect(Array(head[32..<36]) == Array("NXSB".utf8))
        case .hfsPlus: #expect(Array(head[1024..<1026]) == Array("H+".utf8))
        case .hfsx: #expect(Array(head[1024..<1026]) == Array("HX".utf8))
        }
        let hasLicence = relative.hasPrefix("zed/")
        #expect((image.licence != nil) == hasLicence)
        if let licence = image.licence {
            #expect(!licence.languages.isEmpty)
            if case .rtf(let bytes) = licence.languages[0].body {
                #expect(bytes.starts(with: Array("{\\rtf".utf8)))
            } else {
                Issue.record("Zed's licence should be RTF")
            }
            #expect(licence.languages[0].buttons.contains("Agree"))
        }
        print("corpus \(relative): \(location.kind.rawValue) \(try image.partitionMap().scheme) licence=\(hasLicence)")
    }

    @Test func dockerParallelDecodeSpeed() throws {
        let image = try DiskImage.open(path: Fixtures.samples.appendingPathComponent("docker/Docker.dmg").path)
        let udif = try #require(image.udif)
        let workers = ProcessInfo.processInfo.activeProcessorCount
        let decoded = Atomic<Int>(0)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            try udif.decodeAll(maxConcurrency: workers) { _, bytes in
                decoded.wrappingAdd(bytes.count, ordering: .relaxed)
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let megabytes = Double(decoded.load(ordering: .relaxed)) / 1_048_576
        print(
            String(
                format: "Docker: %.0f MB decoded in %.2f s with %d workers = %.0f MB/s", megabytes, seconds, workers,
                megabytes / seconds))
        #expect(megabytes > 0)
    }
}
