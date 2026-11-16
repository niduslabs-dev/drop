import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import Extractor

// MARK: - Boost

@Suite struct BoostTests {
    private func manyFiles() -> (FakeFileSystem, Entry) {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        for index in 0..<200 {
            builder.file(
                "f\(index)", in: contents.id, contents: [UInt8](repeating: UInt8(index % 251), count: 64 << 10))
        }
        return (builder.build(), builder.app)
    }

    @Test func boostMidStageRaisesWorkersAndRunsTheHookOnce() throws {
        let (fileSystem, app) = manyFiles()
        let job = StagingJob()
        let hookCalls = Atomic<Int>(0)
        let options = StageOptions(
            priority: .background, bufferSize: 4096, job: job, onBoost: { hookCalls.add(1, ordering: .relaxed) })
        let destination = try scratchFolder("boost")
        let staged = try Extractor.stage(
            app: app, from: fileSystem, into: try Extractor.makeStagingArea(for: destination), options: options
        ) { progress in
            if progress.bytesDone > 0 { job.boost() }
        }
        defer { discardAndWait(staged) }
        #expect(job.isBoosted)
        #expect(hookCalls.load(ordering: .relaxed) == 1)
        #expect(
            job.boostedWorkers.load(ordering: .relaxed) >= 1, "no worker confirmed user-initiated QoS and default I/O")
        #expect(try snapshot(staged.url).count == 201)
        job.boost()
        #expect(hookCalls.load(ordering: .relaxed) == 1, "the hook ran after stage returned")
    }

    @Test func boostBeforeStageStartsFast() throws {
        let (fileSystem, app) = manyFiles()
        let job = StagingJob()
        job.boost()
        let hookCalls = Atomic<Int>(0)
        let options = StageOptions(
            priority: .background, job: job, onBoost: { hookCalls.add(1, ordering: .relaxed) })
        let destination = try scratchFolder("boost-early")
        let staged = try Extractor.stage(
            app: app, from: fileSystem, into: try Extractor.makeStagingArea(for: destination), options: options)
        defer { discardAndWait(staged) }
        #expect(hookCalls.load(ordering: .relaxed) == 1)
        #expect(job.boostedWorkers.load(ordering: .relaxed) == 0, "workers should start fast, not switch")
    }

    @Test func boostingAFinishedJobIsHarmless() throws {
        let (fileSystem, app) = manyFiles()
        let job = StagingJob()
        let hookCalls = Atomic<Int>(0)
        let options = StageOptions(
            priority: .background, job: job, onBoost: { hookCalls.add(1, ordering: .relaxed) })
        let staged = try Extractor.stage(
            app: app, from: fileSystem, into: try Extractor.makeStagingArea(for: try scratchFolder("boost-late")),
            options: options)
        defer { discardAndWait(staged) }
        job.boost()
        #expect(hookCalls.load(ordering: .relaxed) == 0)
    }
}

// MARK: - Sweep

@Suite struct SweepTests {
    private func mkdirs(_ path: String, mode: mode_t = 0o755) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        chmod(path, mode)
    }

    /// A staging-area-shaped tree with read-only folders, as a crash leaves it.
    private func fakeArea(_ path: String) throws {
        try mkdirs(path + "/App.app/Contents/Locked")
        FileManager.default.createFile(atPath: path + "/App.app/Contents/Locked/file", contents: Data([1]))
        chmod(path + "/App.app/Contents/Locked/file", 0o444)
        chmod(path + "/App.app/Contents/Locked", 0o555)
        chmod(path + "/App.app/Contents", 0o555)
    }

    private func sweep(_ destination: URL, processName: String) -> Int? {
        let result = Mutex<Int?>(nil)
        let done = DispatchSemaphore(value: 0)
        Extractor.sweepLeftovers(near: destination, processName: processName) { removed in
            result.withLock { $0 = removed }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { return nil }
        return result.withLock { $0 }
    }

    @Test func removesOnlyItsOwnLeftovers() throws {
        let destination = try scratchFolder("sweep")
        let outside = try scratchFolder("sweep-outside")
        FileManager.default.createFile(atPath: outside.path + "/keep", contents: Data([1]))
        let fresh = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        rmdir(fresh.path)
        let temporaryItems = fresh.deletingLastPathComponent().path
        // A name no other process has, so the sweep can't reach anyone else's folders.
        let process = "DropSweepTest" + UUID().uuidString.prefix(8)
        let uuid = { UUID().uuidString }

        let mixed = temporaryItems + "/NSIRD_\(process)_mixed"
        try fakeArea(mixed + "/\(uuid()).noindex")
        try fakeArea(mixed + "/.discarded-\(uuid()).noindex")
        try mkdirs(mixed + "/notes.noindex")
        try mkdirs(mixed + "/\(uuid().lowercased()).noindex")
        let onlyArea = temporaryItems + "/NSIRD_\(process)_only"
        try fakeArea(onlyArea + "/\(uuid()).noindex")
        let linked = temporaryItems + "/NSIRD_\(process)_link"
        try mkdirs(linked)
        let linkedArea = linked + "/\(uuid()).noindex"
        try #require(symlink(outside.path, linkedArea) == 0)
        let otherApp = temporaryItems + "/NSIRD_Other\(process)_x"
        let otherArea = otherApp + "/\(uuid()).noindex"
        try mkdirs(otherArea)
        defer {
            for folder in [mixed, onlyArea, linked, otherApp] { Extractor.removeTree(folder) }
        }

        let dest = destination.path
        try fakeArea(dest + "/.Drop Staging \(uuid()).noindex")
        try fakeArea(dest + "/.discarded-.Drop Staging \(uuid()).noindex")
        let live = dest + "/.Drop Staging \(uuid()).noindex"
        try mkdirs(live)
        LiveAreas.add(live)
        defer { LiveAreas.remove(live) }
        let kept = [
            dest + "/.Drop Staging not-a-uuid.noindex", dest + "/\(uuid()).noindex", dest + "/Other.app",
        ]
        for path in kept { try mkdirs(path) }
        let linkedFallback = dest + "/.Drop Staging \(uuid()).noindex"
        try #require(symlink(outside.path, linkedFallback) == 0)

        #expect(sweep(destination, processName: process) == 5)

        let mixedLeft = try FileManager.default.contentsOfDirectory(atPath: mixed)
        #expect(mixedLeft.count == 2 && mixedLeft.contains("notes.noindex"), "\(mixedLeft)")
        #expect(!exists(URL(fileURLWithPath: onlyArea)), "empty NSIRD folder left behind")
        #expect(exists(URL(fileURLWithPath: linkedArea)), "a symlink with an area's name was removed")
        #expect(exists(URL(fileURLWithPath: otherArea)), "another process's folder was swept")
        #expect(exists(URL(fileURLWithPath: live)), "a live area was swept")
        #expect(exists(URL(fileURLWithPath: linkedFallback)))
        for path in kept { #expect(exists(URL(fileURLWithPath: path)), "\(path) removed") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep"])
        let destLeft = Set(try FileManager.default.contentsOfDirectory(atPath: dest))
        #expect(destLeft.count == kept.count + 2, "\(destLeft)")
    }

    @Test func installAndDiscardLeaveNoItemReplacementFolder() throws {
        let destination = try scratchFolder("nsird")
        let builder = FakeBuilder()
        builder.file("x", contents: [1])
        let area = try Extractor.makeStagingArea(for: destination)
        let parent = area.url.deletingLastPathComponent()
        let staged = try Extractor.stage(app: builder.app, from: builder.build(), into: area)
        _ = try Extractor.install(staged, into: destination) { _ in }
        if parent.lastPathComponent.hasPrefix("NSIRD_") { #expect(!exists(parent)) }

        let second = try Extractor.makeStagingArea(for: destination)
        let secondParent = second.url.deletingLastPathComponent()
        discardAndWait(second)
        if secondParent.lastPathComponent.hasPrefix("NSIRD_") { #expect(!exists(secondParent)) }
    }
}

// MARK: - Gentle background writes

@Suite struct GentleWriteTests {
    private static let fileCount = 200
    private static let fileSize = 64 << 10

    private func manyFiles() -> (FakeFileSystem, Entry) {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        for index in 0..<Self.fileCount {
            builder.file(
                "f\(index)", in: contents.id, contents: [UInt8](repeating: UInt8(index % 251), count: Self.fileSize))
        }
        return (builder.build(), builder.app)
    }

    /// Records every `F_NOCACHE` change the writer makes.
    private final class NoCacheLog: Sendable {
        let entries = Mutex<[(String, Bool)]>([])
        var hook: @Sendable (String, Bool) -> Void { { path, on in self.entries.withLock { $0.append((path, on)) } } }
        var all: [(String, Bool)] { entries.withLock { $0 } }
    }

    private func stage(_ options: StageOptions, label: String) throws -> StagedApp {
        let (fileSystem, app) = manyFiles()
        return try Extractor.stage(
            app: app, from: fileSystem, into: try Extractor.makeStagingArea(for: try scratchFolder(label)),
            options: options)
    }

    @Test func backgroundWritesEveryFileUncached() throws {
        let log = NoCacheLog()
        var options = StageOptions(priority: .background, uncachedBackgroundWrites: true, backgroundWriteRate: nil)
        options.noCacheHook = log.hook
        let staged = try stage(options, label: "nocache")
        defer { discardAndWait(staged) }
        #expect(log.all.count == Self.fileCount)
        #expect(log.all.allSatisfy { $0.1 }, "every background file should be uncached")
        #expect(Set(log.all.map(\.0)).count == Self.fileCount)
    }

    @Test func fastAndOptedOutWritesStayCached() throws {
        for options in [
            StageOptions(priority: .userInitiated),
            StageOptions(priority: .background, uncachedBackgroundWrites: false, backgroundWriteRate: nil),
        ] {
            let log = NoCacheLog()
            var options = options
            options.noCacheHook = log.hook
            let staged = try stage(options, label: "cached")
            discardAndWait(staged)
            #expect(log.all.isEmpty)
        }
    }

    @Test func boostTurnsCachingBackOnMidFile() throws {
        let builder = FakeBuilder()
        let contents = builder.directory("Contents")
        builder.file("big", in: contents.id, contents: [UInt8](repeating: 7, count: 1 << 20))
        let job = StagingJob()
        let log = NoCacheLog()
        var options = StageOptions(
            priority: .background, bufferSize: 4096, job: job, uncachedBackgroundWrites: true,
            backgroundWriteRate: nil)
        options.noCacheHook = log.hook
        let staged = try Extractor.stage(
            app: builder.app, from: builder.build(),
            into: try Extractor.makeStagingArea(for: try scratchFolder("nocache-boost")), options: options
        ) { progress in
            if progress.bytesDone > 0 { job.boost() }
        }
        defer { discardAndWait(staged) }
        #expect(log.all.map(\.1) == [true, false])
    }

    @Test func pacingHoldsTheRate() throws {
        let rate = 20_000_000
        let buffer = Self.fileSize
        let options = StageOptions(priority: .background, bufferSize: buffer, backgroundWriteRate: rate)
        let started = ContinuousClock.now
        let staged = try stage(options, label: "paced")
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        defer { discardAndWait(staged) }
        // One buffer per worker passes on the bucket's burst; the rest at the rate.
        let burst = buffer * options.workerCount
        let expected = Double(Self.fileCount * Self.fileSize - burst) / Double(rate)
        #expect(elapsed >= expected * 0.9, "\(elapsed) s, expected about \(expected) s")
        // Background-QoS workers are starved on purpose under load (the full parallel suite
        // or a corpus run), so the tight bound, which catches a pacer that sleeps too long,
        // only runs in the opt-in timing pass (`DROP_TIMING=1`, run on its own).
        let timingPass = ProcessInfo.processInfo.environment["DROP_TIMING"] == "1"
        let slack = timingPass ? 1.5 : 3.0
        #expect(elapsed <= expected * slack + 0.3, "\(elapsed) s, expected about \(expected) s")
    }

    @Test func boostLiftsPacing() throws {
        let job = StagingJob()
        let slowRate = 1_000_000  // 12.8 MB would take about 13 s
        let options = StageOptions(
            priority: .background, bufferSize: Self.fileSize, job: job, backgroundWriteRate: slowRate)
        let (fileSystem, app) = manyFiles()
        let started = ContinuousClock.now
        let staged = try Extractor.stage(
            app: app, from: fileSystem, into: try Extractor.makeStagingArea(for: try scratchFolder("paced-boost")),
            options: options
        ) { progress in
            if progress.bytesDone > 0 { job.boost() }
        }
        defer { discardAndWait(staged) }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func pacerReservesAtTheRate() {
        let pacer = WritePacer(bytesPerSecond: 1_000_000, burstBytes: 100_000)
        #expect(pacer.reserve(100_000) == 0, "the burst passes at once")
        let wait = pacer.reserve(500_000)
        #expect(abs(wait - 0.5) < 0.01)
        let next = pacer.reserve(500_000)
        #expect(abs(next - 1.0) < 0.01, "waits queue up behind each other")
    }

    @Test func pausedJobWritesNothingUntilResumed() throws {
        let job = StagingJob()
        job.pause()
        let (fileSystem, app) = manyFiles()
        let destination = try scratchFolder("paused")
        let area = try Extractor.makeStagingArea(for: destination)
        let options = StageOptions(priority: .background, job: job, backgroundWriteRate: nil)
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<Result<StagedApp, any Error>?>(nil)
        Thread {
            let outcome = Result { try Extractor.stage(app: app, from: fileSystem, into: area, options: options) }
            result.withLock { $0 = outcome }
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + 0.5) == .timedOut, "a paused stage should wait")
        #expect(try FileManager.default.contentsOfDirectory(atPath: area.url.path).isEmpty)
        job.resume()
        #expect(done.wait(timeout: .now() + 20) == .success)
        let staged = try #require(result.withLock { $0 }).get()
        defer { discardAndWait(staged) }
        #expect(try snapshot(staged.url).count == Self.fileCount + 1)
    }

    @Test func cancelEndsAPausedStage() throws {
        let job = StagingJob()
        job.pause()
        let stop = Atomic<Bool>(false)
        let (fileSystem, app) = manyFiles()
        let area = try Extractor.makeStagingArea(for: try scratchFolder("paused-cancel"))
        let options = StageOptions(
            priority: .background, isCancelled: { stop.load(ordering: .relaxed) }, job: job, backgroundWriteRate: nil)
        let done = DispatchSemaphore(value: 0)
        let failed = Atomic<Bool>(false)
        Thread {
            do {
                _ = try Extractor.stage(app: app, from: fileSystem, into: area, options: options)
            } catch ExtractorError.cancelled {
                failed.store(true, ordering: .relaxed)
            } catch {}
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.2)
        stop.store(true, ordering: .relaxed)
        // No resume(): the gate's own recheck has to notice.
        #expect(done.wait(timeout: .now() + 5) == .success)
        let sawCancel = failed.load(ordering: .relaxed)
        #expect(sawCancel)
        #expect(waitForDiscard(area))
    }

    @Test func boostLiftsAPause() {
        let job = StagingJob()
        job.pause()
        job.boost()
        #expect(!job.isPaused)
        job.pause()
        #expect(!job.isPaused, "a boosted job never pauses")
    }
}
