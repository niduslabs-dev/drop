import Compression
import Darwin
import ReaderCore
import zlib

/// Chunk decompressors. Each one fills `output` exactly or throws `corrupt`: a chunk that
/// decodes to fewer or more bytes than its table says is a damaged image, and padding it
/// would hand the filesystem reader silently wrong data.
enum Decoders {
    static func decode(
        _ type: ChunkType, input: UnsafeRawBufferPointer, output: UnsafeMutableRawBufferPointer
    ) throws {
        switch type {
        case .zero, .ignore:
            if let base = output.baseAddress { memset(base, 0, output.count) }
        case .raw:
            guard input.count == output.count else { throw ReaderError.corrupt("raw chunk length mismatch") }
            output.copyMemory(from: input)
        case .adc: try adc(input, output)
        case .zlib: try zlib(input, output)
        case .bzip2: try bzip2(input, output)
        case .lzfse: try compression(input, output, algorithm: COMPRESSION_LZFSE, name: "lzfse")
        case .lzma: try compression(input, output, algorithm: COMPRESSION_LZMA, name: "lzma")
        }
    }

    // MARK: ADC

    private static let adcLiteralFlag: UInt8 = 0x80
    private static let adcLongMatchFlag: UInt8 = 0x40
    private static let adcLiteralLengthMask: UInt8 = 0x7F
    private static let adcLongLengthMask: UInt8 = 0x3F
    private static let adcLongMinimum = 4
    private static let adcShortMinimum = 3
    private static let adcShortLengthShift: UInt8 = 2
    private static let adcShortLengthMask: UInt8 = 0x0F
    private static let adcShortDistanceMask: UInt8 = 0x03

    /// Apple Data Compression, an LZ77 variant with three opcodes:
    /// - `1nnnnnnn`: copy `n + 1` literal bytes;
    /// - `01nnnnnn hi lo`: copy `n + 4` bytes from `(hi << 8 | lo) + 1` back;
    /// - `0nnnnloo lo`: copy `nnnn + 3` bytes from `(oo << 8 | lo) + 1` back.
    /// Matches may overlap their own output (run-length style), so they copy byte by byte.
    static func adc(_ input: UnsafeRawBufferPointer, _ output: UnsafeMutableRawBufferPointer) throws {
        var i = 0
        var o = 0
        while o < output.count {
            guard i < input.count else { throw ReaderError.corrupt("adc input ends early") }
            let op = input[i]
            if op & adcLiteralFlag != 0 {
                let n = Int(op & adcLiteralLengthMask) + 1
                guard i + 1 + n <= input.count, o + n <= output.count else {
                    throw ReaderError.corrupt("adc literal overruns")
                }
                for k in 0..<n { output[o + k] = input[i + 1 + k] }
                i += 1 + n
                o += n
                continue
            }
            let n: Int
            let distance: Int
            if op & adcLongMatchFlag != 0 {
                guard i + 2 < input.count else { throw ReaderError.corrupt("adc match truncated") }
                n = Int(op & adcLongLengthMask) + adcLongMinimum
                distance = (Int(input[i + 1]) << 8 | Int(input[i + 2])) + 1
                i += 3
            } else {
                guard i + 1 < input.count else { throw ReaderError.corrupt("adc match truncated") }
                n = Int((op >> adcShortLengthShift) & adcShortLengthMask) + adcShortMinimum
                distance = (Int(op & adcShortDistanceMask) << 8 | Int(input[i + 1])) + 1
                i += 2
            }
            guard distance <= o, o + n <= output.count else { throw ReaderError.corrupt("adc match out of range") }
            for _ in 0..<n {
                output[o] = output[o - distance]
                o += 1
            }
        }
    }

    // MARK: zlib

    private static func zlib(_ input: UnsafeRawBufferPointer, _ output: UnsafeMutableRawBufferPointer) throws {
        guard let source = input.baseAddress, let destination = output.baseAddress,
            let sourceLength = uInt(exactly: input.count), let destinationLength = uInt(exactly: output.count)
        else { throw ReaderError.corrupt("zlib chunk too large") }

        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ReaderError.corrupt("zlib init failed")
        }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: source.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = sourceLength
        stream.next_out = destination.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = destinationLength
        let status = inflate(&stream, Z_FINISH)
        guard status == Z_STREAM_END, stream.total_out == output.count else {
            throw ReaderError.corrupt("zlib chunk did not decode to \(output.count) bytes (status \(status))")
        }
    }

    // MARK: bzip2

    private typealias BZ2BuffToBuffDecompress =
        @convention(c) (
            UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32,
            Int32
        ) -> Int32

    private static let bz2OK: Int32 = 0
    private static let libbz2Path = "/usr/lib/libbz2.1.0.dylib"

    /// libbz2 ships in the SDK as a header without a Clang module, so Swift can't import it;
    /// the one function we need is looked up once. The library is in the shared cache.
    private static let bz2Decompress: BZ2BuffToBuffDecompress? = {
        let handle = dlopen(libbz2Path, RTLD_LAZY) ?? UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(handle, "BZ2_bzBuffToBuffDecompress") else { return nil }
        return unsafeBitCast(symbol, to: BZ2BuffToBuffDecompress.self)
    }()

    private static func bzip2(_ input: UnsafeRawBufferPointer, _ output: UnsafeMutableRawBufferPointer) throws {
        guard let decompress = bz2Decompress else { throw ReaderError.unsupportedCompression(ChunkType.bzip2Code) }
        guard let source = input.baseAddress, let destination = output.baseAddress,
            let sourceLength = UInt32(exactly: input.count), var destinationLength = UInt32(exactly: output.count)
        else { throw ReaderError.corrupt("bzip2 chunk too large") }
        let status = decompress(
            destination.assumingMemoryBound(to: CChar.self), &destinationLength,
            UnsafeMutablePointer(mutating: source.assumingMemoryBound(to: CChar.self)), sourceLength, 0, 0)
        guard status == bz2OK, destinationLength == output.count else {
            throw ReaderError.corrupt("bzip2 chunk did not decode to \(output.count) bytes (status \(status))")
        }
    }

    // MARK: Compression framework

    /// `compression_decode_buffer` returns the bytes written and can't report "more output
    /// remained", so a full buffer is the success condition.
    private static func compression(
        _ input: UnsafeRawBufferPointer, _ output: UnsafeMutableRawBufferPointer,
        algorithm: compression_algorithm, name: String
    ) throws {
        guard let source = input.baseAddress, let destination = output.baseAddress else {
            throw ReaderError.corrupt("\(name) chunk is empty")
        }
        let written = compression_decode_buffer(
            destination.assumingMemoryBound(to: UInt8.self), output.count,
            source.assumingMemoryBound(to: UInt8.self), input.count, nil, algorithm)
        guard written == output.count else {
            throw ReaderError.corrupt("\(name) chunk decoded to \(written) of \(output.count) bytes")
        }
    }
}
