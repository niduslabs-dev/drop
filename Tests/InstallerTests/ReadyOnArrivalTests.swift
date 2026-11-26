import DMGReader
import Foundation
import ReaderCore
import Synchronization
import Testing

@testable import Extractor
@testable import Installer
@testable import Mounter
@testable import Verifier

/// The fast signer read (`SignerPeek`), straight from the fixture images.
@Suite struct SignerPeekTests {
    private func app(in dmg: URL) throws -> (Entry, any FileSystem) {
        let opened = try DMGReader.open(path: dmg.path)
        let app = try #require(try DMGReader.apps(in: opened.fileSystem).first)
        return (app, opened.fileSystem)
    }

    private func scratchRoot(_ label: String) -> URL {
        packageRoot.appending(path: ".build/installer-tests/peek-\(label)-\(UUID().uuidString)")
    }

    @Test func readsARealCertificateSignerWithoutStaging() throws {
        let (app, fileSystem) = try app(in: try Fixtures.dmg("apple-signed"))
        let root = scratchRoot("apple")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(SignerPeek.read(app: app, in: fileSystem, dmgTicket: nil, root: root))
        let original = try Verifier.signingInfo(app: URL(filePath: "/System/Applications/Stickies.app"))
        #expect(result.signing.kind == .apple)
        #expect(result.signing.hasSigner)
        #expect(result.signing.organisation == original.organisation)
        #expect(result.signing.signer == original.signer)
        #expect(result.signing.teamID == original.teamID)
        #expect(Set(result.signing.cdhashes) == Set(original.cdhashes), "every architecture's cdhash")
        #expect(!result.hasStapledTicket)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "the skeleton bundle is deleted")
    }

    @Test func anUnsignedAppHasNoSigner() throws {
        let (app, fileSystem) = try app(in: try Fixtures.dmg("unsigned"))
        let root = scratchRoot("unsigned")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(SignerPeek.read(app: app, in: fileSystem, dmgTicket: nil, root: root))
        #expect(result.signing.kind == .unsigned)
        #expect(!result.signing.hasSigner)
    }

    @Test func writesOnlyHeadersAndSignatureOfTheExecutable() throws {
        let (app, fileSystem) = try app(in: try Fixtures.dmg("apple-signed"))
        let binary = try #require(try fileSystem.lookup([app.name, "Contents", "MacOS", "Stickies"]))
        let ranges = try SignerPeek.signatureRanges(size: binary.size) { offset, count in
            try SignerPeek.readRange(of: binary, at: offset, count: count, in: fileSystem)
        }
        let total = ranges.reduce(0) { $0 + $1.count }
        #expect(ranges.count >= 3, "fat header, then a header and a signature per slice")
        #expect(ranges.allSatisfy { $0.offset + UInt64($0.count) <= binary.size })
        #expect(UInt64(total) < binary.size / 2)
    }

    @Test func rejectsWhatIsNotMachO() {
        #expect(throws: ReaderError.self) {
            try SignerPeek.signatureRanges(size: 64) { _, count in [UInt8](repeating: 0x41, count: count) }
        }
    }

    /// The stapled case, from a folder read through `MountedFileSystem` (POSIX, no mount):
    /// the synthetic ad hoc app, then with a ticket listing its cdhash.
    @Test func findsAStapledTicketThatNamesTheApp() throws {
        let folder = scratchRoot("stapled")
        defer { try? FileManager.default.removeItem(at: folder) }
        let volume = folder.appending(path: "volume", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let source = packageRoot.appending(path: ".build/fixtures/verifier/synthetic/AdHoc.app")
        try #require(FileManager.default.fileExists(atPath: source.path), "run scripts/fixtures-verifier.sh")
        let copy = volume.appending(path: "Tiny.app", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: copy)
        let hashes = try Verifier.signingInfo(app: copy).cdhashes
        let root = folder.appending(path: "peek", directoryHint: .isDirectory)

        func peek(dmgTicket: NotarizationTicket? = nil) throws -> SignerPeek.Result {
            let fileSystem = try MountedFileSystem(mountPoint: volume, volumeName: "Tiny")
            let app = try #require(try fileSystem.lookup(["Tiny.app"]))
            return try #require(SignerPeek.read(app: app, in: fileSystem, dmgTicket: dmgTicket, root: root))
        }

        #expect(try !peek().hasStapledTicket, "unstapled")
        let other = try SyntheticTicket.make([CDHash(hashType: 2, bytes: [UInt8](repeating: 7, count: 20))])
        #expect(try !peek(dmgTicket: other).hasStapledTicket, "a disk image ticket for other code doesn't count")
        let covering = try SyntheticTicket.make(hashes)
        #expect(try peek(dmgTicket: covering).hasStapledTicket, "the disk image's ticket names the app")
        try Data(covering.bytes).write(to: copy.appending(path: "Contents/CodeResources"))
        #expect(try peek().hasStapledTicket, "stapled into the app")
    }
}

/// Ticket bytes in the layout `NotarizationTicket` parses, with no certificates and a zero
/// signature: enough for parsing and coverage, never for Gatekeeper.
enum SyntheticTicket {
    static func make(_ hashes: [CDHash]) throws -> NotarizationTicket {
        func le(_ value: Int, _ size: Int) -> [UInt8] {
            (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        let ticketLength = 24 + hashes.count * 21
        var bytes = Array("s8ch".utf8) + le(1, 4) + le(0, 4) + le(ticketLength, 4)
        bytes += Array("g8tk".utf8) + le(2, 2) + le(20, 2) + le(hashes.count, 4) + le(0, 4) + le(1_700_000_000, 8)
        for hash in hashes { bytes += [hash.hashType] + hash.bytes }
        return try NotarizationTicket(bytes: bytes)
    }
}

/// A scripted network path: `set(_:)` flips it and tells every listener.
final class FakeNetwork: Sendable {
    private let state = Mutex<(satisfied: Bool, listeners: [AsyncStream<Bool>.Continuation])>((false, []))

    init(satisfied: Bool) { state.withLock { $0.satisfied = satisfied } }

    var path: NetworkPath {
        NetworkPath(
            isSatisfied: { self.state.withLock { $0.satisfied } },
            changes: { AsyncStream { continuation in self.state.withLock { $0.listeners.append(continuation) } } })
    }

    func set(_ satisfied: Bool) {
        let listeners = state.withLock { state in
            state.satisfied = satisfied
            return state.listeners
        }
        for listener in listeners { listener.yield(satisfied) }
    }
}

/// A lookup the test answers when it wants (`answer(_:)`), counting calls.
final class ScriptedLookup: Sendable {
    private let state = Mutex<(calls: Int, waiting: [CheckedContinuation<TicketAnswer, Never>])>((0, []))

    var lookUp: @Sendable ([CDHash], Duration) async -> TicketAnswer {
        { _, _ in
            await withCheckedContinuation { continuation in
                self.state.withLock {
                    $0.calls += 1
                    $0.waiting.append(continuation)
                }
            }
        }
    }

    var calls: Int { state.withLock { $0.calls } }

    func answer(_ answer: TicketAnswer) {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume(returning: answer) }
    }
}

/// Sessions with a played Developer ID signer: the fast read, Apple's ticket service with a
/// scripted network, and the full check that still gates the install.
@Suite(.serialized)
struct ReadyOnArrivalSessionTests {
    static let team = "ABCDE12345"

    static func developerID(team: String = team, organisation: String = "Linea Software Ltd") -> SigningInfo {
        SigningInfo(
            kind: .developerID, identifier: "dev.niduslabs.drop.fixture.tiny", teamID: team,
            signer: "Developer ID Application: \(organisation) (\(team))", organisation: organisation,
            anchoredToApple: true, cdhashes: [CDHash(hashType: 2, bytes: [UInt8](repeating: 1, count: 20))],
            hardenedRuntime: true, hasStapledTicket: false)
    }

    static func verdict(
        _ signing: SigningInfo,
        assessment: AssessmentResult? = .assessed(
            Assessment(accepted: true, source: Assessment.Source.notarizedDeveloperID, status: nil))
    ) -> Verdict {
        Verdict(signing: signing, validity: .valid, assessment: assessment)
    }

    /// Options with the played signer, `network`, `lookup`, and a full check that waits for
    /// `gate` before answering `verdict`.
    static func options(
        _ scratch: Scratch, stapled: Bool = false, network: NetworkPath, lookup: ScriptedLookup,
        verdict: Verdict, gate: Gate = Gate(open: true)
    ) -> InstallOptions {
        var options = scratch.options()
        options.network = network
        options.lookUpTicket = lookup.lookUp
        options.peek = { _, _, _, _ in SignerPeek.Result(signing: developerID(), hasStapledTicket: stapled) }
        options.verify = { _, _ in
            await gate.wait()
            return verdict
        }
        return options
    }

    private func notarization(_ state: InstallState) -> Notarization? { state.summary?.notarization }

    @Test func showsTheSignerBeforeTheFullCheck() async throws {
        let scratch = try Scratch("arrival-signer")
        defer { scratch.remove() }
        let gate = Gate(open: false)
        let lookup = ScriptedLookup()
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, stapled: true, network: FakeNetwork(satisfied: true).path, lookup: lookup,
                verdict: Self.verdict(Self.developerID()), gate: gate))
        await session.start()
        let early = await waitFor(session, timeout: .seconds(30)) { $0.summary?.signer != nil }
        #expect(early.summary?.signer == "Linea Software Ltd")
        #expect(early.summary?.teamID == Self.team)
        #expect(early.summary?.isSignatureChecked == false)
        #expect(notarization(early) == .stapled, "a stapled ticket says Notarized at once")
        #expect(early.summary?.isNotarized == true)
        #expect(lookup.calls == 0, "no lookup when a ticket is stapled")
        gate.open()
        let settled = await waitFor(session) { $0.isSettled }
        guard case .ready(let summary) = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(summary.isSignatureChecked)
        #expect(summary.notarization == .stapled)
        await session.cancel()
    }

    @Test func noNetworkPathSaysUnreachableAtOnceThenAsksWhenItReturns() async throws {
        let scratch = try Scratch("arrival-offline")
        defer { scratch.remove() }
        let network = FakeNetwork(satisfied: false)
        let lookup = ScriptedLookup()
        let gate = Gate(open: false)
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, network: network.path, lookup: lookup, verdict: Self.verdict(Self.developerID()), gate: gate))
        await session.start()
        let offline = await waitFor(session, timeout: .seconds(30)) { $0.summary?.signer != nil }
        #expect(notarization(offline) == .unreachable, "no Checking with Apple first")
        #expect(lookup.calls == 0)

        network.set(true)
        let asking = await waitFor(session, timeout: .seconds(10)) {
            if case .asking = $0.summary?.notarization { true } else { false }
        }
        #expect(notarization(asking) == .asking(attempt: 2))
        try await waitUntil { lookup.calls == 1 }
        lookup.answer(.notarized(try SyntheticTicket.make(Self.developerID().cdhashes)))
        let confirmed = await waitFor(session, timeout: .seconds(10)) { $0.summary?.notarization == .confirmed }
        #expect(confirmed.summary?.isNotarized == true)
        gate.open()
        await session.cancel()
    }

    @Test func aLateNotarizedAnswerStillCountsAfterTheFullCheck() async throws {
        let scratch = try Scratch("arrival-late")
        defer { scratch.remove() }
        let lookup = ScriptedLookup()
        // Gatekeeper couldn't be asked either: the ready board with Couldn't reach Apple.
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, network: FakeNetwork(satisfied: true).path, lookup: lookup,
                verdict: Self.verdict(Self.developerID(), assessment: .notAssessed(.timedOut))))
        await session.start()
        let settled = await waitFor(session) { $0.isSettled }
        guard case .ready(let summary) = settled else {
            Issue.record("expected ready, got \(settled)")
            return
        }
        #expect(
            summary.notarization == .asking(attempt: 1), "the lookup still runs; the panel's give-up shows the line")
        #expect(!summary.isNotarized)
        lookup.answer(.unreachable)
        let line = await waitFor(session, timeout: .seconds(10)) { $0.summary?.notarization == .unreachable }
        #expect(line.summary?.isNotarized == false)
        await session.cancel()
    }

    @Test func aLateAnswerTurnsTheLineIntoNotarized() async throws {
        let scratch = try Scratch("arrival-late-yes")
        defer { scratch.remove() }
        let lookup = ScriptedLookup()
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, network: FakeNetwork(satisfied: true).path, lookup: lookup,
                verdict: Self.verdict(Self.developerID(), assessment: .notAssessed(.timedOut))))
        await session.start()
        _ = await waitFor(session) { $0.isSettled }
        lookup.answer(.notarized(try SyntheticTicket.make(Self.developerID().cdhashes)))
        let notarized = await waitFor(session, timeout: .seconds(10)) { $0.summary?.notarization == .confirmed }
        #expect(notarized.summary?.isNotarized == true)
        await session.cancel()
    }

    @Test func aDisagreeingFullCheckIsRefusedAndNothingIsReplaced() async throws {
        let scratch = try Scratch("arrival-disagree")
        defer { scratch.remove() }
        // An installed copy that must survive.
        let installed = scratch.destination.appending(path: "Tiny.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appending(path: "marker"))
        let gate = Gate(open: false)
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, stapled: true, network: FakeNetwork(satisfied: true).path, lookup: ScriptedLookup(),
                verdict: Self.verdict(Self.developerID(team: "ZZZZZ99999", organisation: "Someone Else")), gate: gate))
        await session.start()
        _ = await waitFor(session, timeout: .seconds(30)) { $0.summary?.signer != nil }
        // Install early: the button's fill covers the rest, then the full check says no.
        let installing = Task { await session.install() }
        _ = await waitFor(session, timeout: .seconds(30)) { if case .installing = $0 { true } else { false } }
        gate.open()
        await installing.value
        let final = await session.state
        guard case .refused(let summary, .damaged) = final else {
            Issue.record("expected refused, got \(final)")
            return
        }
        #expect(summary.teamID == "ZZZZZ99999", "the full check's signer wins")
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "marker").path), "old copy untouched")
        #expect(scratch.trashed().isEmpty)
    }

    @Test func anEarlyInstallThatEndsInAWarningReplacesNothing() async throws {
        let scratch = try Scratch("arrival-warning")
        defer { scratch.remove() }
        let installed = scratch.destination.appending(path: "Tiny.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appending(path: "marker"))
        let gate = Gate(open: false)
        let rejected = AssessmentResult.assessed(
            Assessment(accepted: false, source: Assessment.Source.developerID, status: nil))
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, network: FakeNetwork(satisfied: true).path, lookup: ScriptedLookup(),
                verdict: Self.verdict(Self.developerID(), assessment: rejected), gate: gate))
        await session.start()
        _ = await waitFor(session, timeout: .seconds(30)) { $0.summary?.signer != nil }
        let installing = Task { await session.install() }
        _ = await waitFor(session, timeout: .seconds(30)) { if case .installing = $0 { true } else { false } }
        gate.open()
        await installing.value
        let final = await session.state
        guard case .warning(_, .notNotarized) = final else {
            Issue.record("expected warning, got \(final)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "marker").path), "old copy untouched")
        #expect(scratch.trashed().isEmpty)
        await session.cancel()
    }

    @Test func updatesShowSameDeveloperFromTheFastRead() async throws {
        let scratch = try Scratch("arrival-update")
        defer { scratch.remove() }
        // The installed copy: the real ad hoc app has no Team ID, so the fast read can't
        // confirm the developer and says so.
        let source = packageRoot.appending(path: ".build/fixtures/verifier/synthetic/AdHoc.app")
        try FileManager.default.copyItem(at: source, to: scratch.destination.appending(path: "Tiny.app"))
        let gate = Gate(open: false)
        let session = InstallSession(
            dmg: try Fixtures.dmg("one-app"),
            options: Self.options(
                scratch, stapled: true, network: FakeNetwork(satisfied: true).path, lookup: ScriptedLookup(),
                verdict: Self.verdict(Self.developerID()), gate: gate))
        await session.start()
        let early = await waitFor(session, timeout: .seconds(30)) { $0.summary?.update?.developer != nil }
        #expect(early.summary?.isSignatureChecked == false)
        #expect(early.summary?.update?.developer == .installedUnsigned)
        gate.open()
        await session.cancel()
    }

    @Test func notarizationAfterTheFullCheck() {
        let signing = Self.developerID()
        let accepted = Self.verdict(signing)
        #expect(InstallSession.notarization(after: accepted, decision: .install, early: .stapled) == .stapled)
        #expect(InstallSession.notarization(after: accepted, decision: .install, early: .unreachable) == .confirmed)
        let unknown = Self.verdict(signing, assessment: .notAssessed(.timedOut))
        #expect(InstallSession.decision(for: unknown, early: nil) == .install)
        #expect(InstallSession.notarization(after: unknown, decision: .install, early: .confirmed) == .confirmed)
        #expect(
            InstallSession.notarization(after: unknown, decision: .install, early: .asking(attempt: 1)) == .unreachable)
        let early = EarlyTrust(signing: signing, notarization: .notFound)
        #expect(InstallSession.decision(for: unknown, early: early) == .warn(.notarizationUnknown))
        let other = EarlyTrust(signing: Self.developerID(team: "ZZZZZ99999"), notarization: .stapled)
        guard case .refuse(.damaged) = InstallSession.decision(for: accepted, early: other) else {
            Issue.record("a different signer must be refused")
            return
        }
    }
}

/// Holds the scripted full check until `open()`.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    init(open: Bool) { state.withLock { $0.open = open } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Polls `condition` every 20 ms for up to 10 s.
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition never held")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
