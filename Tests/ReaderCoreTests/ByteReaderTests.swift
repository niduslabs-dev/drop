import ReaderCore
import Testing

@Suite struct ByteReaderTests {
    @Test func readsBothEndians() throws {
        let reader = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        #expect(try reader.be16(0) == 0x0102)
        #expect(try reader.le16(0) == 0x0201)
        #expect(try reader.be32(0) == 0x0102_0304)
        #expect(try reader.le32(4) == 0x0807_0605)
        #expect(try reader.be64(0) == 0x0102_0304_0506_0708)
    }

    @Test func throwsPastTheEnd() {
        let reader = ByteReader([0x01, 0x02])
        #expect(throws: ReaderError.self) { try reader.be32(0) }
        #expect(throws: ReaderError.self) { try reader.u8(-1) }
    }
}

/// A tiny in-memory filesystem: one file laid out as data, hole, data, then an implicit
/// trailing hole, to check `read(_:bufferSize:_:)` against `contents(of:)`.
private struct OneFile: FileSystem {
    let device: any BlockDevice
    let file: Entry
    let layout: [Extent]
    var kind: String { "test" }
    var volumeName: String { "test" }
    var root: Entry { Entry(id: 1, name: "", kind: .directory, mode: 0o755, size: 0) }
    func children(of directory: Entry) throws -> [Entry] { [file] }
    func extents(of file: Entry) throws -> [Extent] { layout }
    func symlinkTarget(of link: Entry) throws -> String { throw ReaderError.notASymlink }
    func xattrs(of entry: Entry) throws -> [String: XattrValue] { [:] }
}

@Suite struct StreamingReadTests {
    @Test func streamsDataHolesAndTail() throws {
        let disk = (0..<100).map { UInt8($0) }
        let fs = OneFile(
            device: MemoryDevice(disk),
            file: Entry(id: 2, name: "f", kind: .file, mode: 0o644, size: 50),
            layout: [
                Extent(fileOffset: 0, deviceOffset: 10, length: 10),
                Extent(fileOffset: 10, deviceOffset: 0, length: 5, isHole: true),
                Extent(fileOffset: 20, deviceOffset: 40, length: 15),
            ])
        var streamed: [UInt8] = []
        try fs.read(fs.file, bufferSize: 4) { offset, bytes in
            #expect(Int(offset) == streamed.count)
            streamed.append(contentsOf: bytes)
        }
        let expected =
            Array(disk[10..<20]) + [UInt8](repeating: 0, count: 10) + Array(disk[40..<55])
            + [UInt8](repeating: 0, count: 15)
        #expect(streamed == expected)
        #expect(try fs.contents(of: fs.file) == expected)
    }

    @Test func refusesHugeInMemoryReads() {
        let fs = OneFile(
            device: MemoryDevice([]),
            file: Entry(id: 2, name: "big", kind: .file, mode: 0o644, size: maxInMemoryContents + 1), layout: [])
        #expect(throws: ReaderError.self) { try fs.contents(of: fs.file) }
    }
}
