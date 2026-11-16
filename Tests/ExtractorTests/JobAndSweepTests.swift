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
