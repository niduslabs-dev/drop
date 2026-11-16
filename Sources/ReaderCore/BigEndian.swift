/// Bounds-checked integer reads from on-disk structures. HFS+ and UDIF are big-endian,
/// APFS is little-endian; every reader uses these instead of raw pointer casts so a
/// corrupt image throws instead of crashing.
public struct ByteReader: Sendable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    @inline(__always)
    private func check(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset <= bytes.count - count else {
            throw ReaderError.corrupt("read of \(count) bytes at \(offset) past \(bytes.count)")
        }
    }

    public func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return bytes[offset]
    }

    public func be16(_ offset: Int) throws -> UInt16 { UInt16(try uint(offset, 2, bigEndian: true)) }
    public func be32(_ offset: Int) throws -> UInt32 { UInt32(try uint(offset, 4, bigEndian: true)) }
    public func be64(_ offset: Int) throws -> UInt64 { try uint(offset, 8, bigEndian: true) }
    public func le16(_ offset: Int) throws -> UInt16 { UInt16(try uint(offset, 2, bigEndian: false)) }
    public func le32(_ offset: Int) throws -> UInt32 { UInt32(try uint(offset, 4, bigEndian: false)) }
    public func le64(_ offset: Int) throws -> UInt64 { try uint(offset, 8, bigEndian: false) }

    public func slice(_ offset: Int, _ count: Int) throws -> [UInt8] {
        try check(offset, count)
        return Array(bytes[offset..<offset + count])
    }

    private func uint(_ offset: Int, _ count: Int, bigEndian: Bool) throws -> UInt64 {
        try check(offset, count)
        var value: UInt64 = 0
        for i in 0..<count {
            let byte = UInt64(bytes[offset + (bigEndian ? i : count - 1 - i)])
            value = value << 8 | byte
        }
        return value
    }
}
