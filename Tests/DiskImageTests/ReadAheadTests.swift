import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import DiskImage

/// Parallel decode and read-ahead on the read path: real fixtures for correctness, and a
/// scheduler over a slow fake decoder for the concurrency bounds and policy changes.
@Suite struct ReadAheadTests {
    /// The fixture's disk as hdiutil decoded it, padded with zeros to the device size.
    static func reference(_ name: String, size: UInt64) throws -> [UInt8] {
        var bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try Fixtures.path("\(name).dmg.cdr"))))
        bytes += [UInt8](repeating: 0, count: Int(size) - bytes.count)
        return bytes
    }

    /// Reads `range` of `device` front to back in `bufferSize` pieces and reports whether
    /// every piece matched `reference`.
    static func readSequentially(
        _ device: any BlockDevice, _ range: Range<Int>, bufferSize: Int, reference: [UInt8]
    ) -> Bool {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let count = min(bufferSize, range.upperBound - offset)
            guard let bytes = try? device.read(at: UInt64(offset), count: count),
                bytes[...] == reference[offset..<offset + count]
            else { return false }
            offset += count
        }
        return true
    }

    /// Four readers each stream a quarter of the disk, and four more stream the whole
    /// disk with different buffer sizes, all at once, on a small decoder budget.
    @Test(arguments: Fixtures.images)
    func concurrentSequentialReadersMatchReference(_ name: String) throws {
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        let device = image.device
        let reference = try Self.reference(name, size: device.size)
        image.udif?.decodePolicy = DecodePolicy(maxDecoders: 3, qos: .utility, readAheadBytes: 1 << 20)
        let size = reference.count
        let quarter = (size + 3) / 4
        let bufferSizes = [4_096, 65_536, 300_007, 4 << 20]
        let failures = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 8) { reader in
            let ok: Bool
            if reader < 4 {
                let range = min(size, reader * quarter)..<min(size, (reader + 1) * quarter)
                ok = Self.readSequentially(device, range, bufferSize: 131_072, reference: reference)
            } else {
                ok = Self.readSequentially(device, 0..<size, bufferSize: bufferSizes[reader - 4], reference: reference)
            }
            if !ok { failures.wrappingAdd(1, ordering: .relaxed) }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
    }

    /// A full sequential pass decodes every compressed chunk exactly once, with one reader
    /// or four readers on adjacent quarters (which share the chunks at their edges).
    @Test(arguments: Fixtures.images.filter { !$0.hasSuffix("UDRW") && !$0.hasSuffix("UDTO") }, [1, 4])
    func sequentialPassDecodesEachChunkOnce(_ name: String, readers: Int) throws {
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        let udif = try #require(image.udif)
        let reference = try Self.reference(name, size: udif.size)
        let size = reference.count
        let share = (size + readers - 1) / readers
        let failures = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            let range = min(size, reader * share)..<min(size, (reader + 1) * share)
            if !Self.readSequentially(udif, range, bufferSize: 200_000, reference: reference) {
                failures.wrappingAdd(1, ordering: .relaxed)
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
        let decodes = udif.decodeStats.decodes
        for chunk in udif.chunks {
            let compressed = !chunk.type.isZeroFill && chunk.type != .raw
            #expect(decodes[chunk.index] == (compressed ? 1 : 0), "chunk \(chunk.index) (\(chunk.type))")
        }
    }

    /// Random small reads, interleaved with a sequential reader, still see the right bytes.
    @Test func randomReadsBesideReadAhead() throws {
        let name = "apfs-GPTSPUD-ULMO"
        let image = try DiskImage.open(path: try Fixtures.path("\(name).dmg"))
        let device = image.device
        let reference = try Self.reference(name, size: device.size)
        let failures = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 3) { reader in
            if reader == 0 {
                if !Self.readSequentially(device, 0..<reference.count, bufferSize: 65_536, reference: reference) {
                    failures.wrappingAdd(1, ordering: .relaxed)
                }
                return
            }
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<500 {
                let count = Int.random(in: 1...20_000, using: &generator)
                let offset = Int.random(in: 0...(reference.count - count), using: &generator)
                let bytes = try? device.read(at: UInt64(offset), count: count)
                if bytes.map({ $0[...] != reference[offset..<offset + count] }) ?? true {
                    failures.wrappingAdd(1, ordering: .relaxed)
                }
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
    }

    // MARK: Scheduler over a fake decoder

    /// A fake codec that takes `delay` per chunk, fills it with the chunk's index and
    /// tracks how many decodes run at once.
    final class SlowDecoder: Sendable {
        let delay: Duration
        let running = Atomic<Int>(0)
        let peak = Atomic<Int>(0)
        let calls = Mutex<[Int: Int]>([:])

        init(delay: Duration) { self.delay = delay }

        func decode(_ chunk: Chunk) throws -> MappedBytes {
            let now = running.wrappingAdd(1, ordering: .relaxed).newValue
            peak.max(now, ordering: .relaxed)
            calls.withLock { $0[chunk.index, default: 0] += 1 }
            Thread.sleep(forTimeInterval: Double(delay.components.attoseconds) / 1e18)
            running.wrappingSubtract(1, ordering: .relaxed)
            return try MappedBytes(count: Int(chunk.length)) {
                $0.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: chunk.index))
            }
        }

        func resetPeak() { peak.store(running.load(ordering: .relaxed), ordering: .relaxed) }
    }

    static let fakeChunkSize: UInt64 = 64 * 1024

    static func fakeChunks(_ count: Int) -> [Chunk] {
        (0..<count).map {
            Chunk(
                index: $0, type: .lzma, deviceOffset: UInt64($0) * fakeChunkSize, length: fakeChunkSize,
                fileOffset: 0, fileLength: 1)
        }
    }

    static func scheduler(_ decoder: SlowDecoder, chunks: Int, policy: DecodePolicy) -> DecodeScheduler {
        DecodeScheduler(chunks: fakeChunks(chunks), cacheLimit: 64 << 20, policy: policy) { try decoder.decode($0) }
    }

    /// Reads chunks `range` the way `UDIFDevice.read` does, `perRead` chunks per read,
    /// and reports whether each came back with its own contents.
    static func stream(_ scheduler: DecodeScheduler, _ range: Range<Int>, perRead: Int) -> Bool {
        var first = range.lowerBound
        while first < range.upperBound {
            let last = min(first + perRead, range.upperBound) - 1
            scheduler.plan(first: first, last: last)
            for index in first...last {
                guard let bytes = try? scheduler.bytes(of: index),
                    bytes.count == Int(fakeChunkSize),
                    bytes.withUnsafeBytes({ $0.allSatisfy { $0 == UInt8(truncatingIfNeeded: index) } })
                else { return false }
            }
            first = last + 1
        }
        return true
    }

    /// Six readers share one decoder budget: never more than `maxDecoders` decode at once,
    /// counting reader threads, and no chunk is decoded twice.
    @Test(arguments: [1, 3])
    func decoderBoundIsSharedByAllReaders(_ limit: Int) {
        let decoder = SlowDecoder(delay: .milliseconds(2))
        let chunkCount = 240
        let policy = DecodePolicy(maxDecoders: limit, qos: .utility, readAheadBytes: 1 << 20)
        let scheduler = Self.scheduler(decoder, chunks: chunkCount, policy: policy)
        let readers = 6
        let share = chunkCount / readers
        let failures = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            if !Self.stream(scheduler, reader * share..<(reader + 1) * share, perRead: 4) {
                failures.wrappingAdd(1, ordering: .relaxed)
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
        #expect(decoder.peak.load(ordering: .relaxed) <= limit)
        #expect(scheduler.decodeStats.maxConcurrent <= limit)
        #expect(scheduler.decodeStats.maxConcurrent >= 1)
        #expect(decoder.calls.withLock { $0.values.allSatisfy { $0 == 1 } && $0.count == chunkCount })
    }

    /// One sequential reader with read-ahead keeps the whole budget busy.
    @Test func readAheadUsesTheWholeBudget() {
        let decoder = SlowDecoder(delay: .milliseconds(5))
        let scheduler = Self.scheduler(
            decoder, chunks: 200, policy: DecodePolicy(maxDecoders: 4, qos: .userInitiated, readAheadBytes: 2 << 20))
        #expect(Self.stream(scheduler, 0..<200, perRead: 1))
        #expect(scheduler.decodeStats.maxConcurrent == 4)
        #expect(scheduler.decodeStats.decodes.allSatisfy { $0 == 1 })
    }

    /// Lowering the budget and QoS mid-read applies to every decode that starts after it;
    /// raising it again lets more run at once.
    @Test func policyChangeMidReadTakesEffect() {
        let decoder = SlowDecoder(delay: .milliseconds(5))
        let scheduler = Self.scheduler(
            decoder, chunks: 300, policy: DecodePolicy(maxDecoders: 6, qos: .userInitiated, readAheadBytes: 2 << 20))
        #expect(Self.stream(scheduler, 0..<100, perRead: 4))
        #expect(scheduler.decodeStats.maxConcurrent > 2)
        #expect(scheduler.decodeStats.lastWorkerQoS == QOS_CLASS_USER_INITIATED)

        scheduler.decodePolicy = DecodePolicy(maxDecoders: 2, qos: .background, readAheadBytes: 2 << 20)
        scheduler.resetDecodeStats()
        #expect(Self.stream(scheduler, 100..<200, perRead: 4))
        #expect(scheduler.decodeStats.maxConcurrent <= 2)
        #expect(scheduler.decodeStats.lastWorkerQoS == QOS_CLASS_BACKGROUND)

        scheduler.decodePolicy = DecodePolicy(maxDecoders: 6, qos: .userInitiated, readAheadBytes: 2 << 20)
        scheduler.resetDecodeStats()
        #expect(Self.stream(scheduler, 200..<300, perRead: 4))
        #expect(scheduler.decodeStats.maxConcurrent > 2)
        #expect(decoder.calls.withLock { $0.values.allSatisfy { $0 == 1 } })
    }

    /// A reader that abandons its stream doesn't hold the read-ahead budget hostage: a
    /// new sequential reader still gets read-ahead.
    @Test func abandonedReadAheadIsReleased() {
        let decoder = SlowDecoder(delay: .milliseconds(1))
        // Budget of 8 chunks (half of a 1 MiB cache), per-stream depth of all of it.
        let scheduler = DecodeScheduler(
            chunks: Self.fakeChunks(400), cacheLimit: 1 << 20,
            policy: DecodePolicy(maxDecoders: 4, qos: .utility, readAheadBytes: 1 << 20)
        ) { try decoder.decode($0) }
        #expect(Self.stream(scheduler, 0..<10, perRead: 1))
        // The first stream stops at chunk 9 with read-ahead reserved past it.
        Thread.sleep(forTimeInterval: 0.05)
        scheduler.resetDecodeStats()
        #expect(Self.stream(scheduler, 200..<260, perRead: 1))
        // With read-ahead, workers decoded most of the second stream's chunks.
        let decoded = scheduler.decodeStats.decodes[200..<260].reduce(0, +)
        #expect(decoded == 60)
        #expect(scheduler.decodeStats.maxConcurrent > 1)
    }
}
