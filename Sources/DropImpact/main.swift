import CryptoKit
import Darwin
import DiskImage
import Extractor
import Foundation
import Installer

// drop-impact: the pieces of the background-impact benchmark (plan step 3). Each mode is
// its own process, so Drop's CPU time and memory are measured apart from the foreground
// load. `.claude/research/scripts/impact_bench.py` runs them and writes the report.
//
//   drop-impact cpu <seconds>                 hash 64 MB buffers on one thread per P-core
//   drop-impact disk <file> <seconds>         read <file> uncached in 1 MB blocks
//   drop-impact make-file <file> <GiB>        write the uncached test file once
//   drop-impact stage <policy> <dest> [--boost-after <s>] <dmg>...
//
// Every timestamp is `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` in seconds, which is
// system-wide, so the runner can line foreground samples up with Drop's staging window.
// Output is one JSON object per line on stdout.

/// Size of the buffer each CPU thread hashes per sample.
let hashBufferSize = 64 << 20
/// Bytes per uncached read.
let diskBlockSize = 1 << 20
/// Bytes the disk reader counts per sample.
let diskSampleBytes = 64 << 20
let bytesPerMB = 1_000_000.0
let nanosecondsPerSecond = 1e9

/// The runner creates this file (path in `DROP_IMPACT_STOP`) to end a foreground load early.
let stopFile = ProcessInfo.processInfo.environment["DROP_IMPACT_STOP"]

func shouldStop(_ deadline: Double) -> Bool {
    if now() >= deadline { return true }
    guard let stopFile else { return false }
    return access(stopFile, F_OK) == 0
}

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / nanosecondsPerSecond }

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("drop-impact: \(message)\n".utf8))
    exit(2)
}

func performanceCores() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else {
        return ProcessInfo.processInfo.activeProcessorCount
    }
    return Int(count)
}

/// Samples are (end time, MB) for each finished unit of work, collected per thread.
final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, Double)] = []
    func add(_ time: Double, _ mb: Double) { lock.withLock { items.append((time, mb)) } }
    var all: [(Double, Double)] { lock.withLock { items } }
}

func runCPU(seconds: Double) {
    let threads = performanceCores()
    let samples = Samples()
    let deadline = now() + seconds
    let group = DispatchGroup()
    for _ in 0..<threads {
        group.enter()
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: hashBufferSize)
            for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: index &* 31) }
            var sink: UInt8 = 0
            while !shouldStop(deadline) {
                let digest = SHA256.hash(data: buffer)
                sink ^= digest.first { _ in true } ?? 0
                buffer[0] = sink
                samples.add(now(), Double(hashBufferSize) / bytesPerMB)
            }
            group.leave()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    let start = now()
    group.wait()
    emit(["kind": "cpu", "threads": threads, "start": start, "samples": samples.all.map { [$0.0, $0.1] }])
}

func runDisk(path: String, seconds: Double) {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { fail("open \(path): \(errno)") }
    defer { close(fd) }
    guard fcntl(fd, F_NOCACHE, 1) == 0 else { fail("F_NOCACHE: \(errno)") }
    var info = stat()
    fstat(fd, &info)
    let size = Int64(info.st_size)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: diskBlockSize, alignment: Int(getpagesize()))
    defer { buffer.deallocate() }
    var offset: Int64 = 0
    var counted = 0
    var samples: [[Double]] = []
    let start = now()
    let deadline = start + seconds
    while !shouldStop(deadline) {
        if offset + Int64(diskBlockSize) > size { offset = 0 }
        let got = pread(fd, buffer, diskBlockSize, offset)
        guard got > 0 else { fail("pread: \(errno)") }
        offset += Int64(got)
        counted += got
        if counted >= diskSampleBytes {
            samples.append([now(), Double(counted) / bytesPerMB])
            counted = 0
        }
    }
    emit(["kind": "disk", "start": start, "samples": samples])
}

func makeFile(path: String, gib: Int) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { fail("create \(path): \(errno)") }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let block = diskBlockSize * 8
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: Int(getpagesize()))
    defer { buffer.deallocate() }
    arc4random_buf(buffer, block)
    for _ in 0..<(gib << 30) / block {
        guard write(fd, buffer, block) == block else { fail("write: \(errno)") }
    }
    emit(["kind": "make-file", "path": path, "bytes": gib << 30])
}

/// Drop's own usage so far: CPU split by QoS, lifetime peak footprint, disk bytes.
func ownUsage() -> [String: Any] {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return [:] }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / nanosecondsPerSecond
    }
    return [
        "cpuUser": seconds(info.ri_user_time), "cpuSystem": seconds(info.ri_system_time),
        "cpuBackground": seconds(info.ri_cpu_time_qos_background),
        "cpuUtility": seconds(info.ri_cpu_time_qos_utility),
        "cpuUserInitiated": seconds(info.ri_cpu_time_qos_user_initiated),
        "cpuDefault": seconds(info.ri_cpu_time_qos_default),
        "peakFootprint": info.ri_lifetime_max_phys_footprint, "diskRead": info.ri_diskio_bytesread,
        "diskWritten": info.ri_diskio_byteswritten,
    ]
}

func runStage(policyName: String, destination: URL, boostAfter: Double?, dmgs: [URL]) async {
    let policy: DecodePolicy
    let priority: StageOptions.Priority
    switch policyName {
    case "background": (policy, priority) = (.background, .background)
    case "utility": (policy, priority) = (.utility, .background)
    case "fast": (policy, priority) = (.fast, .userInitiated)
    default: fail("unknown policy \(policyName)")
    }
    let trashed = destination.appending(path: "trash")
    try? FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
    let options = InstallOptions(
        destination: destination, stagingPriority: priority, backgroundDecodePolicy: policy,
        trash: { url in
            try FileManager.default.moveItem(at: url, to: trashed.appending(path: UUID().uuidString))
        })
    let windowStart = now()
    for dmg in dmgs {
        let session = InstallSession(dmg: dmg, options: options)
        let started = now()
        await session.start()
        var boostedAt: Double?
        if let boostAfter {
            try? await Task.sleep(for: .milliseconds(Int(boostAfter * 1000)))
            boostedAt = now()
            await session.install()
        }
        var final = await session.state
        while !(final.isFinal || isReadyOrWarning(final)) {
            try? await Task.sleep(for: .milliseconds(10))
            final = await session.state
        }
        let readyAt = now()
        let timings = await session.timings
        await session.cancel()
        var record: [String: Any] = [
            "kind": "stage", "policy": policyName, "dmg": dmg.lastPathComponent, "start": started,
            "readyAt": readyAt, "timeToReady": readyAt - started, "state": String(describing: final).prefix(60),
        ]
        if let staged = timings.staged, let begun = timings.stagingStarted { record["stageSeconds"] = staged - begun }
        if let verified = timings.verified, let staged = timings.staged { record["verifySeconds"] = verified - staged }
        if let boostedAt { record["boostToReady"] = readyAt - boostedAt }
        emit(record)
    }
    var summary = ownUsage()
    summary["kind"] = "usage"
    summary["windowStart"] = windowStart
    summary["windowEnd"] = now()
    emit(summary)
}

func isReadyOrWarning(_ state: InstallState) -> Bool {
    switch state {
    case .ready, .warning: true
    default: false
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else { fail("usage: see the comment at the top of main.swift") }
switch mode {
case "cpu":
    guard arguments.count == 2, let seconds = Double(arguments[1]) else { fail("cpu <seconds>") }
    runCPU(seconds: seconds)
case "disk":
    guard arguments.count == 3, let seconds = Double(arguments[2]) else { fail("disk <file> <seconds>") }
    runDisk(path: arguments[1], seconds: seconds)
case "make-file":
    guard arguments.count == 3, let gib = Int(arguments[2]), gib > 0 else { fail("make-file <file> <GiB>") }
    makeFile(path: arguments[1], gib: gib)
case "stage":
    guard arguments.count >= 4 else { fail("stage <policy> <dest> [--boost-after s] <dmg>...") }
    var rest = Array(arguments.dropFirst(3))
    var boostAfter: Double?
    if rest.first == "--boost-after", rest.count >= 3, let value = Double(rest[1]) {
        boostAfter = value
        rest.removeFirst(2)
    }
    await runStage(
        policyName: arguments[1], destination: URL(fileURLWithPath: arguments[2]), boostAfter: boostAfter,
        dmgs: rest.map { URL(fileURLWithPath: $0) })
default:
    fail("unknown mode \(mode)")
}
