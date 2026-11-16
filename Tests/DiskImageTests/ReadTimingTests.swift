import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import DiskImage

/// Sequential read speed of a real image's filesystem partition, the way the Extractor
/// reads big files: 4 MB buffers, one reader or four readers on separate ranges. Opt-in
/// (`DROP_TIMING=1`) and meant for release builds:
/// `DROP_TIMING=1 timeout 900 scripts/swift.sh test -c release --filter DiskImageTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DROP_TIMING"] == "1", "set DROP_TIMING=1"))
struct ReadTimingTests {
    static let bufferSize = 4 * 1024 * 1024
    static let samples = ["firefox/Firefox-160.0.dmg", "docker/Docker.dmg"]

    @Test(arguments: samples, [1, 4])
    func sequentialReadSpeed(_ relative: String, readers: Int) throws {
        try measure(relative, readers: readers, policy: .fast)
    }

    /// The background staging policy, for comparison: it is meant to be slower.
    @Test(arguments: samples)
    func backgroundPolicyReadSpeed(_ relative: String) throws {
        try measure(relative, readers: 4, policy: .background)
    }

    private func measure(_ relative: String, readers: Int, policy: DecodePolicy) throws {
        let image = try DiskImage.open(path: Fixtures.samples.appendingPathComponent(relative).path)
        image.udif?.decodePolicy = policy
        let partition = try image.fileSystem().device
        let size = partition.size
        let buffer = UInt64(Self.bufferSize)
        let share = (size / UInt64(readers) + buffer - 1) / buffer * buffer
        let failures = Atomic<Int>(0)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            DispatchQueue.concurrentPerform(iterations: readers) { reader in
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
                defer { buffer.deallocate() }
                var offset = UInt64(reader) * share
                let end = min(size, offset + share)
                while offset < end {
                    let count = Int(min(UInt64(Self.bufferSize), end - offset))
                    do {
                        try partition.read(at: offset, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]))
                    } catch {
                        failures.wrappingAdd(1, ordering: .relaxed)
                        return
                    }
                    offset += UInt64(count)
                }
            }
        }
        #expect(failures.load(ordering: .relaxed) == 0)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let megabytes = Double(size) / 1_048_576
        print(
            String(
                format: "timing %@ readers=%d decoders=%d: %.0f MB in %.2f s = %.0f MB/s", relative, readers,
                policy.maxDecoders, megabytes, seconds,
                megabytes / seconds))
    }
}
