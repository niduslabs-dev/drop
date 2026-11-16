import Foundation
import Synchronization
import Testing
import Verifier

@testable import Extractor
@testable import Installer

/// `InstallSession.changeDestination`: the panel's "Install to" switch, without starting over.
@Suite(.serialized)
struct DestinationChangeTests {
    /// Two destinations in one scratch folder. `other` is under a `VolumeB` folder that the
    /// injected volume identity calls another volume when `twoVolumes` is set (tests never
    /// mount one), so the cross-volume copy runs for real on the scratch volume.
    struct Setup {
        let scratch: Scratch
        let other: URL
        let checks: Counter
        let options: InstallOptions

        init(_ label: String, twoVolumes: Bool = false) throws {
            scratch = try Scratch(label)
            other = scratch.root.appending(path: "VolumeB/Applications", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let checks = Counter()
            self.checks = checks
            var options = scratch.options()
            options.verify = { app, qos in
                checks.increment()
                return await Verifier.verdict(app: app, qos: qos)
            }
            if twoVolumes {
                options.volumeIdentity = { $0.path.contains("/VolumeB/") ? "B" : "A" }
            }
            self.options = options
        }
    }

    @Test func sameVolumeKeepsTheStagedCopyAndVerdict() async throws {
        let setup = try Setup("switch-same")
        defer { setup.scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: setup.options)
        await session.start()
        let before = await waitFor(session) { $0.isSettled }
        guard case .warning = before else {
            Issue.record("expected warning, got \(before)")
            return
        }
        let area = try #require(await session.stagingArea)

        await session.changeDestination(setup.other)
        let took = try #require(await session.lastDestinationChange)
        print("same-volume switch: \(took)")
        #expect(await session.stagingArea == area)
        #expect(await session.relocations == 0)
        #expect(setup.checks.value == 1, "no new signature check")
        #expect(await session.state == before, "nothing installed in either: same board")

        await session.install()
        #expect(
            await session.state == .installed(setup.other.appending(path: "Tiny.app", directoryHint: .isDirectory)))
        #expect(setup.scratch.installed().isEmpty)
    }

    @Test func boardSwitchesToUpdateAndBack() async throws {
        let setup = try Setup("switch-update")
        defer { setup.scratch.remove() }
        try installedCopy(in: setup.other, version: "0.9")
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: setup.options)
        await session.start()
        let fresh = await waitFor(session) { $0.isSettled }
        #expect(fresh.summary != nil && fresh.summary?.update == nil)

        await session.changeDestination(setup.other)
        let update = try #require(await session.state.summary?.update)
        #expect(update.installedVersion == "0.9")
        #expect(update.developer == .installedUnsigned, "the stand-in copy has no signature")

        await session.changeDestination(setup.scratch.destination)
        #expect(await session.state.summary?.update == nil)
        #expect(await session.state.summary?.name == "Tiny")
        #expect(setup.checks.value == 1)
        await session.cancel()
    }

    @Test func switchWhileStagingSettlesAtTheNewDestination() async throws {
        let setup = try Setup("switch-early", twoVolumes: true)
        defer { setup.scratch.remove() }
        try installedCopy(in: setup.other, version: "0.8")
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: setup.options)
        await session.start()
        await waitFor(session) { if case .identified = $0 { true } else { $0.isSettled } }
        await session.changeDestination(setup.other)
        let settled = await waitFor(session) { $0.isSettled }
        guard case .warning(let summary, _) = settled else {
            Issue.record("expected warning, got \(settled)")
            return
        }
        #expect(summary.update?.installedVersion == "0.8")
        #expect(summary.update?.developer == .installedUnsigned)
        #expect(setup.checks.value == 1)
        await session.install()
        #expect(
            await session.state == .installed(setup.other.appending(path: "Tiny.app", directoryHint: .isDirectory)))
        #expect(setup.scratch.trashed().count == 1, "the stand-in copy was replaced")
    }

    @Test func licenceIsNotAskedAgain() async throws {
        let setup = try Setup("switch-licence")
        defer { setup.scratch.remove() }
        try installedCopy(in: setup.other, version: "0.9")
        let dmg = setup.scratch.root.appending(path: "licence.dmg")
        try FileManager.default.copyItem(
            at: MountFixtures.image("licence.dmg"), to: dmg)
        let session = InstallSession(dmg: dmg, options: setup.options)
        let seen = Mutex<[InstallState]>([])
        let listener = Task {
            for await state in session.updates { seen.withLock { $0.append(state) } }
        }
        await session.start()
        let shown = await waitFor(session) { $0.isSettled }
        guard case .needsLicence = shown else {
            Issue.record("expected the licence, got \(shown)")
            return
        }
        // A switch on the licence screen carries over to the summary after Agree.
        await session.changeDestination(setup.other)
        await session.acceptLicence()
        let settled = await waitFor(session) { $0.isSettled && !$0.isLicence }
        #expect(settled.summary?.update?.installedVersion == "0.9")
        await session.changeDestination(setup.scratch.destination)
        #expect(await session.state.summary?.update == nil)
        await session.changeDestination(setup.other)
        #expect(await session.state.summary?.update != nil)
        await session.cancel()
        await listener.value

        let states = seen.withLock { $0 }
        let licences = states.filter(\.isLicence).count
        let firstAfter = try #require(states.firstIndex { !$0.isLicence && $0 != .reading })
        #expect(licences >= 1)
        let shownAgain = states[firstAfter...].contains { $0.isLicence }
        #expect(!shownAgain, "the licence is never shown again")
        #expect(setup.checks.value == 1)
    }

    @Test func otherVolumeCopiesCheckedAndCleansUp() async throws {
        let setup = try Setup("switch-volume", twoVolumes: true)
        defer { setup.scratch.remove() }
        let dmg = setup.scratch.root.appending(path: "one-app.dmg")
        try FileManager.default.copyItem(at: try Fixtures.dmg("one-app"), to: dmg)
        let value = "0083;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666"
        try setQuarantine(value, on: dmg)
        let session = InstallSession(dmg: dmg, options: setup.options)
        await session.start()
        let before = await waitFor(session) { $0.isSettled }
        guard case .warning = before else {
            Issue.record("expected warning, got \(before)")
            return
        }
        let old = try #require(await session.stagingArea)
        let original = try snapshot(old.url.appending(path: "Tiny.app"))

        await session.changeDestination(setup.other)
        print("cross-volume switch: \(try #require(await session.lastDestinationChange))")
        #expect(await session.relocations == 1)
        let new = try #require(await session.stagingArea)
        #expect(new != old)
        #expect(await waitUntilGone(old), "the old staging area is deleted")
        let copied = try snapshot(new.url.appending(path: "Tiny.app"))
        #expect(copied == original, "modes, times and xattrs (the quarantine too) kept")
        #expect(setup.checks.value == 1, "no new signature check")
        #expect(await session.state == before)

        await session.install()
        let app = setup.other.appending(path: "Tiny.app", directoryHint: .isDirectory)
        #expect(await session.state == .installed(app))
        #expect(try quarantine(app) == "0183;6560a8f2;Safari;7A4B1F5C-1111-2222-3333-444455556666")
        #expect(!LiveAreas.contains(new.url.path))
    }

    @Test func cancelDuringASwitchLeavesNothing() async throws {
        let setup = try Setup("switch-cancel", twoVolumes: true)
        defer { setup.scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: setup.options)
        await session.start()
        await waitFor(session) { $0.isSettled }
        let old = try #require(await session.stagingArea)
        let switching = Task { await session.changeDestination(setup.other) }
        await session.cancel()
        await switching.value
        #expect(await session.state == .cancelled)
        let last = try #require(await session.stagingArea)
        #expect(await waitUntilGone(old))
        #expect(await waitUntilGone(last))
        #expect(!LiveAreas.contains(old.url.path) && !LiveAreas.contains(last.url.path))
        #expect(setup.scratch.installed().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: setup.other.path)
        #expect(leftovers.isEmpty)
    }

    @Test func copyMatchesTheStagedTree() async throws {
        let setup = try Setup("copy-tree")
        defer { setup.scratch.remove() }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: setup.options)
        await session.start()
        await waitFor(session) { $0.isSettled }
        let area = try #require(await session.stagingArea)
        let staged = StagedApp(url: area.url.appending(path: "Tiny.app", directoryHint: .isDirectory), area: area)
        let copy = try Extractor.copy(staged, toVolumeOf: setup.other)
        defer { Extractor.discard(copy) }
        let copied = try snapshot(copy.url)
        let source = try snapshot(staged.url)
        #expect(copied == source)
        let copiedHashes = try Verifier.signingInfo(app: copy.url).cdhashes
        let sourceHashes = try Verifier.signingInfo(app: staged.url).cdhashes
        #expect(copiedHashes == sourceHashes)
        #expect(throws: ExtractorError.cancelled) {
            try Extractor.copy(staged, toVolumeOf: setup.other, isCancelled: { true })
        }
        await session.cancel()
    }

    // MARK: Helpers

    /// A stand-in installed copy: a bundle folder with only an `Info.plist`.
    private func installedCopy(in folder: URL, version: String) throws {
        let contents = folder.appending(path: "Tiny.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleIdentifier": "dev.niduslabs.drop.fixture.tiny", "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    /// Every item under `root`: its relative path, mode, modification time and xattrs.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = root.path
        func visit(_ path: String) throws {
            var info = stat()
            try #require(lstat(path, &info) == 0)
            let relative = String(path.dropFirst(base.count))
            let mtime = info.st_mtimespec
            result[relative] = "\(String(info.st_mode, radix: 8)) \(mtime.tv_sec).\(mtime.tv_nsec) \(xattrs(path))"
            if info.st_mode & S_IFMT == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path) { try visit(path + "/" + name) }
            }
        }
        try visit(base)
        return result
    }

    private func xattrs(_ path: String) -> String {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return "" }
        var names = [CChar](repeating: 0, count: size)
        listxattr(path, &names, size, XATTR_NOFOLLOW)
        let list = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return list.sorted().map { name -> String in
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            var value = [UInt8](repeating: 0, count: max(0, length))
            getxattr(path, name, &value, value.count, 0, XATTR_NOFOLLOW)
            return "\(name)=\(value.map { String($0, radix: 16) }.joined())"
        }.joined(separator: ",")
    }
}

/// Counts calls from any thread.
final class Counter: Sendable {
    private let count = Atomic<Int>(0)
    func increment() { count.add(1, ordering: .relaxed) }
    var value: Int { count.load(ordering: .relaxed) }
}
