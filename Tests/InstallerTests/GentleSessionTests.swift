import Dispatch
import Foundation
import Synchronization
import Testing
import Verifier

@testable import Extractor
@testable import Installer

/// Stand-in for Low Power Mode and thermal state that a test flips by hand.
final class FakeConditions: Sendable {
    private let constrained: Atomic<Bool>
    private let continuations = Mutex<[AsyncStream<Void>.Continuation]>([])

    init(constrained: Bool) { self.constrained = Atomic(constrained) }

    var conditions: StagingConditions {
        StagingConditions(
            isConstrained: { self.constrained.load(ordering: .acquiring) },
            changes: {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                self.continuations.withLock { $0.append(continuation) }
                return stream
            })
    }

    /// Sets the value and posts a change, like the system notifications.
    func set(_ value: Bool) {
        constrained.store(value, ordering: .releasing)
        for continuation in continuations.withLock({ $0 }) { continuation.yield() }
    }
}

/// Records the QoS of every signature check and holds utility ones open until cancelled.
final class HeldVerifier: Sendable {
    let calls = Mutex<[DispatchQoS.QoSClass]>([])

    var verify: @Sendable (URL, DispatchQoS.QoSClass) async -> Verdict {
        { app, qos in
            self.calls.withLock { $0.append(qos) }
            if qos != .userInitiated {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return await Verifier.verdict(app: app, qos: qos)
        }
    }

    var recorded: [DispatchQoS.QoSClass] { calls.withLock { $0 } }
}

@Suite(.serialized)
struct GentleSessionTests {
    private func appWasStaged(_ session: InstallSession) async -> Bool {
        guard let area = await session.stagingArea else { return false }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: area.url.path)) ?? []
        return !items.isEmpty
    }

    @Test func constrainedArrivalShowsTheSummaryButStagesNothing() async throws {
        let scratch = try Scratch("lowpower")
        defer { scratch.remove() }
        let fake = FakeConditions(constrained: true)
        var options = scratch.options()
        options.conditions = fake.conditions
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        let waiting = await waitFor(session) { if case .waitingToPrepare = $0 { true } else { $0.isSettled } }
        guard case .waitingToPrepare(let summary) = waiting else {
            Issue.record("expected waitingToPrepare, got \(waiting)")
            return
        }
        #expect(summary.name == "Tiny")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await session.state == .waitingToPrepare(summary), "it stayed waiting")
        #expect(await !appWasStaged(session), "nothing written while constrained")

        fake.set(false)
        let settled = await waitFor(session) { $0.isSettled }
        guard case .warning = settled else {
            Issue.record("expected warning after the constraint lifted, got \(settled)")
            return
        }
        await session.cancel()
    }

    @Test func installWhileWaitingStagesAtFullSpeed() async throws {
        let scratch = try Scratch("lowpower-install")
        defer { scratch.remove() }
        let fake = FakeConditions(constrained: true)
        var options = scratch.options()
        options.conditions = fake.conditions
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        _ = await waitFor(session) { if case .waitingToPrepare = $0 { true } else { $0.isSettled } }
        await session.install()
        // The fixture is ad hoc signed, so Install stops at the warning; Install Anyway installs.
        guard case .warning = await session.state else {
            Issue.record("expected warning, got \(await session.state)")
            return
        }
        #expect(await session.verificationQoS == [.userInitiated])
        await session.install()
        #expect(scratch.installed() == ["Tiny.app"])
    }

    @Test func constraintMidSessionGoesBackToWaitingAndResumes() async throws {
        let scratch = try Scratch("lowpower-mid")
        defer { scratch.remove() }
        let fake = FakeConditions(constrained: false)
        let held = HeldVerifier()
        var options = scratch.options()
        options.conditions = fake.conditions
        options.verify = held.verify
        options.reissuesVerificationOnBoost = true
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        // Held in the check: staging is done and the session still shows preparing.
        _ = await waitFor(session) { _ in !held.recorded.isEmpty }
        fake.set(true)
        let waiting = await waitFor(session) { if case .waitingToPrepare = $0 { true } else { $0.isSettled } }
        guard case .waitingToPrepare = waiting else {
            Issue.record("expected waitingToPrepare, got \(waiting)")
            return
        }
        fake.set(false)
        let preparing = await waitFor(session) { $0.isPreparing || $0.isSettled }
        #expect(preparing.isPreparing)
        await session.cancel()
    }

    @Test func installDuringABackgroundCheckReissuesItAtUserInitiated() async throws {
        let scratch = try Scratch("verify-boost")
        defer { scratch.remove() }
        let held = HeldVerifier()
        var options = scratch.options()
        options.verify = held.verify
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        _ = await waitFor(session) { _ in !held.recorded.isEmpty }
        #expect(held.recorded == [.utility])
        // Without the reissue this would never return: the held check waits for a cancel.
        await session.install()
        #expect(held.recorded == [.utility, .userInitiated])
        #expect(await session.verificationQoS == [.utility, .userInitiated])
        guard case .warning = await session.state else {
            Issue.record("expected warning, got \(await session.state)")
            return
        }
        await session.cancel()
    }

    @Test func reissueCanBeTurnedOff() async throws {
        let scratch = try Scratch("verify-wait")
        defer { scratch.remove() }
        let calls = Mutex<[DispatchQoS.QoSClass]>([])
        var options = scratch.options()
        options.reissuesVerificationOnBoost = false
        options.verify = { app, qos in
            calls.withLock { $0.append(qos) }
            try? await Task.sleep(for: .milliseconds(300))
            return await Verifier.verdict(app: app, qos: qos)
        }
        let session = InstallSession(dmg: try Fixtures.dmg("one-app"), options: options)
        await session.start()
        _ = await waitFor(session) { _ in !calls.withLock { $0 }.isEmpty }
        await session.install()
        #expect(calls.withLock { $0 } == [.utility])
        await session.cancel()
    }
}
