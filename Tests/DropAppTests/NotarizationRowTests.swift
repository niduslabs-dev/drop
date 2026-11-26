import AppKit
import Foundation
import Installer
import SwiftUI
import Synchronization
import Testing

@testable import DropApp

/// Sleeps that end only when the test says: `advance()` ends the oldest one. Records what
/// each asked for, so the test knows where on the timeline it is.
final class ManualSleeper: Sendable {
    private let state = Mutex<(requested: [Duration], waiting: [CheckedContinuation<Void, Never>])>(([], []))

    var sleep: NotarizationRowClock.Sleep {
        { duration in
            await withCheckedContinuation { continuation in
                self.state.withLock {
                    $0.requested.append(duration)
                    $0.waiting.append(continuation)
                }
            }
        }
    }

    var requested: [Duration] { state.withLock { $0.requested } }

    /// Ends the oldest pending sleep (waiting for one to be asked for), then waits until
    /// `settled` holds: the clock's task has run past its wake-up. Real time bounds both
    /// waits, so a loaded machine only makes it slower, never wrong.
    @MainActor
    func advance(until settled: () -> Bool) async {
        let deadline = ContinuousClock.now + Self.patience
        var next: CheckedContinuation<Void, Never>?
        while next == nil, ContinuousClock.now < deadline {
            next = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
            if next == nil { try? await Task.sleep(for: Self.poll) }
        }
        guard let next else {
            Issue.record("no sleep was pending")
            return
        }
        next.resume()
        while !settled(), ContinuousClock.now < deadline { try? await Task.sleep(for: Self.poll) }
    }

    private static let patience: Duration = .seconds(5)
    private static let poll: Duration = .milliseconds(2)
}

@MainActor
@Suite struct NotarizationRowTests {
    private func summary(_ notarization: Notarization, checked: Bool = false) -> AppSummary {
        AppSummary(
            bundleName: "Linea.app", name: "Linea", version: "2.4.1", bundleIdentifier: "com.example.linea",
            size: 1, signer: "Linea Software Ltd", teamID: "ABCDE12345", isNotarized: notarization.isNotarized,
            notarization: notarization, isSignatureChecked: checked)
    }

    /// The rows a panel shows over one lookup: the session's notarization at each tick of
    /// the clock (before the delay, after it, after the give-up), and the clock's phase.
    private func timeline(_ ticks: [(Notarization, NotarizationRow.Phase)]) -> [NotarizationRow] {
        ticks.map { NotarizationRow.resolve(summary($0.0), phase: $0.1) }
    }

    @Test func aStapledTicketIsNotarizedFromTheFirstFrame() {
        #expect(NotarizationRow.resolve(summary(.stapled), phase: .beforeCheckingDelay) == .notarized)
    }

    @Test func aFastAnswerNeverShowsTheCheckingLine() {
        // Asked at 0, answered at 0.2 s: within the 0.4 s delay.
        let rows = timeline([(.asking(attempt: 1), .beforeCheckingDelay), (.confirmed, .beforeCheckingDelay)])
        #expect(rows == [.reserved, .notarized])
        #expect(!rows.contains(.checkingWithApple))
    }

    @Test func aSlowAnswerShowsCheckingThenNotarized() {
        // Answered at 2 s: after the delay, before the give-up.
        let rows = timeline([
            (.asking(attempt: 1), .beforeCheckingDelay), (.asking(attempt: 1), .afterCheckingDelay),
            (.confirmed, .afterCheckingDelay),
        ])
        #expect(rows == [.reserved, .checkingWithApple, .notarized])
    }

    @Test func anAnswerAfterTheGiveUpReplacesTheLine() {
        // Answered at 5 s: the line at 3 s, then Notarized.
        let rows = timeline([
            (.asking(attempt: 1), .afterCheckingDelay), (.asking(attempt: 1), .afterGiveUp), (.confirmed, .afterGiveUp),
        ])
        #expect(rows == [.checkingWithApple, .unreachable, .notarized])
    }

    @Test func noAnswerByTheLateLimitKeepsTheLine() {
        // At 15 s the session's lookup times out and says unreachable.
        let rows = timeline([(.asking(attempt: 1), .afterGiveUp), (.unreachable, .afterGiveUp)])
        #expect(rows == [.unreachable, .unreachable])
    }

    @Test func offlineShowsTheLineAtOnce() {
        #expect(NotarizationRow.resolve(summary(.unreachable), phase: .beforeCheckingDelay) == .unreachable)
    }

    @Test func aLookupAfterTheNetworkReturnsKeepsTheLineUntilTheDelay() {
        let rows = timeline([
            (.unreachable, .beforeCheckingDelay), (.asking(attempt: 2), .beforeCheckingDelay),
            (.asking(attempt: 2), .afterCheckingDelay), (.confirmed, .afterCheckingDelay),
        ])
        #expect(rows == [.unreachable, .unreachable, .checkingWithApple, .notarized])
    }

    @Test func appleWithoutATicketWaitsForTheFullCheck() {
        #expect(NotarizationRow.resolve(summary(.notFound), phase: .beforeCheckingDelay) == .reserved)
        #expect(NotarizationRow.resolve(summary(.notFound), phase: .afterCheckingDelay) == .checkingSignature)
    }

    @Test func theClockStepsThroughTheDelayAndTheGiveUp() async {
        let sleeper = ManualSleeper()
        let clock = NotarizationRowClock(checkingDelay: .milliseconds(400), giveUp: .seconds(3), sleep: sleeper.sleep)
        clock.restart()
        #expect(clock.phase == .beforeCheckingDelay)
        await sleeper.advance { clock.phase == .afterCheckingDelay }
        #expect(clock.phase == .afterCheckingDelay)
        await sleeper.advance { clock.phase == .afterGiveUp }
        #expect(clock.phase == .afterGiveUp)
        #expect(sleeper.requested == [.milliseconds(400), .milliseconds(2600)])
    }

    /// The model drives the clock: it starts when the signer shows and starts again when a
    /// new lookup begins (the network came back), not on every state.
    @Test func theModelRestartsTheClockForEachLookup() async {
        let sleeper = ManualSleeper()
        let clock = NotarizationRowClock(sleep: sleeper.sleep)
        let model = PanelModel(
            dmg: URL(filePath: "/tmp/Linea.dmg"), origin: .watched(folderName: "Downloads"), location: .applications,
            trashImage: false, notarizationClock: clock)
        let progress = InstallProgress(bytesDone: 1, bytesTotal: 2)
        model.state = .preparing(summary(.unreachable), progress)
        #expect(model.notarizationRow == .unreachable)
        await sleeper.advance { clock.phase == .afterCheckingDelay }
        await sleeper.advance { clock.phase == .afterGiveUp }
        #expect(clock.phase == .afterGiveUp)
        model.state = .preparing(summary(.asking(attempt: 2)), progress)
        #expect(clock.phase == .beforeCheckingDelay, "a new lookup starts the clock again")
        #expect(model.notarizationRow == .unreachable)
        await sleeper.advance { clock.phase == .afterCheckingDelay }
        #expect(model.notarizationRow == .checkingWithApple)
        model.state = .preparing(summary(.confirmed), progress)
        #expect(model.notarizationRow == .notarized)
    }
}

/// Install to and the Trash switch are gone from both surfaces (Settings keeps them). SwiftUI
/// builds no accessibility tree for a view that is never shown, so this reads the surfaces'
/// sources; the captures of the built app check what is drawn.
@Suite struct SurfaceSettingsTests {
    private static let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/DropApp")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
    }

    @Test(arguments: ["Boards.swift", "InstallWindow.swift"])
    func neitherSurfaceOffersTheSettings(file: String) throws {
        let text = try source(file)
        #expect(!text.contains("\"Install to\""))
        #expect(!text.contains("Move the disk image to the Trash"))
        #expect(!text.contains("changeLocation"))
    }

    @Test func settingsStillOffersBoth() throws {
        let text = try source("SettingsView.swift")
        #expect(text.contains("Move the disk image to the Trash"))
        #expect(text.contains("Install apps to"))
    }
}
