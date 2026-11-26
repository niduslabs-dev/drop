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
//   drop-impact make-tree <dir> <GiB>         write random 2-8 MB files uncached (copy workload)
//   drop-impact evict <path>...               drop these files' pages from the page cache
//   drop-impact read-tree <dir>               read every file under <dir> once, timed
//   drop-impact stage <policy> <dest> [--boost-after <s>] [--cached | --uncached] [--rate <MB/s>]
//                     [--no-reissue] [--cache-mb <MiB>] <dmg>...
//
// `stage` samples its own `phys_footprint` every `footprintSampleInterval` and reports the
// peak per phase (open and plan, staging, verification) for each DMG.
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
/// The app's notarization lookup timeout (`Theme.Timing.notarizationLateAnswer`), so the
/// benchmark's sessions ask Apple as the app's do. The benchmark can't import the app's theme.
let notarizationLookupTimeout: Duration = .seconds(15)  // design-ok: the app's timeout
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

/// Smallest and largest file `make-tree` writes: "a folder of medium files", like photos.
let treeFileMinBytes = 2 << 20
let treeFileMaxBytes = 8 << 20

/// Writes random files of `treeFileMinBytes`–`treeFileMaxBytes` under `dir` with
/// `F_NOCACHE`, so the copy workload's source starts out of the page cache.
func makeTree(dir: String, gib: Int) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: treeFileMaxBytes, alignment: Int(getpagesize()))
    defer { buffer.deallocate() }
    var total = 0
    var index = 0
    while total < gib << 30 {
        let size = treeFileMinBytes + Int(arc4random_uniform(UInt32(treeFileMaxBytes - treeFileMinBytes)))
        arc4random_buf(buffer, size)
        let path = "\(dir)/\(index / 100)/file-\(index).bin"
        if index % 100 == 0 {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { fail("create \(path): \(errno)") }
        _ = fcntl(fd, F_NOCACHE, 1)
        guard write(fd, buffer, size) == size else { fail("write: \(errno)") }
        close(fd)
        total += size
        index += 1
    }
    emit(["kind": "make-tree", "files": index, "bytes": total])
}

/// Every regular file under each path (or the path itself), not following symlinks.
func regularFiles(_ paths: [String]) -> [String] {
    var files: [String] = []
    for root in paths {
        var info = stat()
        guard lstat(root, &info) == 0 else { continue }
        if info.st_mode & S_IFMT == S_IFREG {
            files.append(root)
            continue
        }
        guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
        for case let relative as String in walker {
            let path = "\(root)/\(relative)"
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { files.append(path) }
        }
    }
    return files
}

/// Evicts each file's pages from the unified buffer cache (`msync` with `MS_INVALIDATE`
/// on a shared read-only mapping, as `vmtouch -e` does) and reports how many bytes were
/// resident before and after (`mincore`). Touches only these files, unlike `purge`.
func evict(_ paths: [String]) {
    let page = Int(getpagesize())
    var before = 0
    var after = 0
    var bytes = 0
    for path in regularFiles(paths) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { continue }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { continue }
        let length = Int(info.st_size)
        guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { continue }
        defer { munmap(map, length) }
        var vector = [CChar](repeating: 0, count: (length + page - 1) / page)
        func resident() -> Int {
            guard mincore(map, length, &vector) == 0 else { return 0 }
            return vector.reduce(0) { $0 + ($1 & 1 != 0 ? page : 0) }
        }
        before += resident()
        msync(map, length, MS_INVALIDATE)
        after += resident()
        bytes += length
    }
    emit(["kind": "evict", "bytes": bytes, "residentBefore": before, "residentAfter": after])
}

/// Bytes per read in `read-tree`.
let treeReadBlock = 1 << 20

/// Opens and reads every file under `dir` once, like a search or an indexer would.
func readTree(dir: String) {
    let start = now()
    let files = regularFiles([dir])
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: treeReadBlock, alignment: Int(getpagesize()))
    defer { buffer.deallocate() }
    var bytes = 0
    for path in files {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { continue }
        while true {
            let got = read(fd, buffer, treeReadBlock)
            if got <= 0 { break }
            bytes += got
        }
        close(fd)
    }
    emit(["kind": "read-tree", "files": files.count, "bytes": bytes, "seconds": now() - start])
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

/// How often `stage` samples its footprint.
let footprintSampleInterval = 0.01

func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// (time, footprint) samples from a thread of its own, at utility QoS.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, UInt64)] = []
    private var running = true

    func start() {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sample = (now(), physFootprint())
                lock.withLock { items.append(sample) }
                Thread.sleep(forTimeInterval: footprintSampleInterval)
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { lock.withLock { running = false } }

    func peak(from start: Double, to end: Double) -> UInt64 {
        lock.withLock { items.filter { $0.0 >= start && $0.0 <= end }.map(\.1).max() ?? 0 }
    }
}

struct StageTuning {
    var uncached = false
    var rateMBps: Double?
    var reissue = true
    var cacheMB: Int?
}

func runStage(policyName: String, destination: URL, boostAfter: Double?, tuning: StageTuning, dmgs: [URL]) async {
    var policy: DecodePolicy
    let priority: StageOptions.Priority
    switch policyName {
    case "background": (policy, priority) = (.background, .background)
    case "utility": (policy, priority) = (.utility, .background)
    case "fast": (policy, priority) = (.fast, .userInitiated)
    default: fail("unknown policy \(policyName)")
    }
    if let cacheMB = tuning.cacheMB { policy.cacheBytes = cacheMB << 20 }
    let trashed = destination.appending(path: "trash")
    try? FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
    let options = InstallOptions(
        destination: destination, stagingPriority: priority, backgroundDecodePolicy: policy,
        trash: { url in
            try FileManager.default.moveItem(at: url, to: trashed.appending(path: UUID().uuidString))
        }, conditions: .unconstrained, uncachedBackgroundWrites: tuning.uncached,
        backgroundWriteRate: tuning.rateMBps.map { Int($0 * bytesPerMB) }, reissuesVerificationOnBoost: tuning.reissue,
        notarizationLookupTimeout: notarizationLookupTimeout)
    let sampler = FootprintSampler()
    let idleFootprint = physFootprint()
    sampler.start()
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
        let at = { (offset: Double?) in offset.map { started + $0 } ?? readyAt }
        record["peakOpen"] = sampler.peak(from: started, to: at(timings.stagingStarted))
        record["peakStage"] = sampler.peak(from: at(timings.stagingStarted), to: at(timings.staged))
        record["peakVerify"] = sampler.peak(from: at(timings.staged), to: readyAt)
        emit(record)
    }
    sampler.stop()
    var summary = ownUsage()
    summary["idleFootprint"] = idleFootprint
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
case "make-tree":
    guard arguments.count == 3, let gib = Int(arguments[2]), gib > 0 else { fail("make-tree <dir> <GiB>") }
    makeTree(dir: arguments[1], gib: gib)
case "evict":
    guard arguments.count >= 2 else { fail("evict <path>...") }
    evict(Array(arguments.dropFirst()))
case "read-tree":
    guard arguments.count == 2 else { fail("read-tree <dir>") }
    readTree(dir: arguments[1])
case "stage":
    guard arguments.count >= 4 else { fail("stage <policy> <dest> [--boost-after s] <dmg>...") }
    var rest = Array(arguments.dropFirst(3))
    var boostAfter: Double?
    var tuning = StageTuning()
    while let flag = rest.first, flag.hasPrefix("--") {
        rest.removeFirst()
        switch flag {
        case "--boost-after":
            guard let value = rest.first.flatMap(Double.init) else { fail("--boost-after <s>") }
            boostAfter = value
            rest.removeFirst()
        case "--rate":
            guard let value = rest.first.flatMap(Double.init), value > 0 else { fail("--rate <MB/s>") }
            tuning.rateMBps = value
            rest.removeFirst()
        case "--cached": tuning.uncached = false
        case "--uncached": tuning.uncached = true
        case "--no-reissue": tuning.reissue = false
        case "--cache-mb":
            guard let value = rest.first.flatMap(Int.init), value > 0 else { fail("--cache-mb <MiB>") }
            tuning.cacheMB = value
            rest.removeFirst()
        default: fail("unknown flag \(flag)")
        }
    }
    await runStage(
        policyName: arguments[1], destination: URL(fileURLWithPath: arguments[2]), boostAfter: boostAfter,
        tuning: tuning, dmgs: rest.map { URL(fileURLWithPath: $0) })
default:
    fail("unknown mode \(mode)")
}
