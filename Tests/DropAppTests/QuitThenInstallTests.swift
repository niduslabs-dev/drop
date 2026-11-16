import Foundation
import Testing

@testable import DropApp

/// Quit and Update is one press: quit the running copy, wait for it, install.
@MainActor
struct QuitThenInstallTests {
    /// A running app that quits the way the test says.
    @MainActor
    final class FakeApp {
        enum Behaviour {
            /// Gone this long after the request, like a real app closing its windows.
            case quitsAfter(Duration)
            /// Gone before `requestQuit` returns: the case a late observer would miss.
            case quitsDuringTheRequest
            case neverQuits
            /// The request can't be sent.
            case refusesTheRequest
        }

        let behaviour: Behaviour
        private(set) var terminated = false
        private(set) var requests = 0
        private var watchers: [AsyncStream<Void>.Continuation] = []

        init(_ behaviour: Behaviour) { self.behaviour = behaviour }

        var handle: RunningApp {
            RunningApp(
                isTerminated: { self.terminated },
                requestQuit: {
                    self.requests += 1
                    switch self.behaviour {
                    case .quitsAfter(let delay):
                        Task {
                            try? await Task.sleep(for: delay)
                            self.terminate()
                        }
                    case .quitsDuringTheRequest: self.terminate()
                    case .neverQuits: break
                    case .refusesTheRequest: return false
                    }
                    return true
                },
                terminations: {
                    AsyncStream { continuation in
                        if self.terminated { continuation.yield() }
                        self.watchers.append(continuation)
                    }
                })
        }

        private func terminate() {
            terminated = true
            for watcher in watchers { watcher.yield() }
        }
    }

    /// What the panel was told and whether the install ran.
    @MainActor
    final class Panel {
        var steps: [QuitThenInstall.Step] = []
        var installs = 0
        var isCurrent = true
        /// Called when "Quitting …" shows, to act while the app is still going.
        var whileQuitting: () -> Void = {}

        func sequence(_ app: FakeApp?, timeout: Duration = .seconds(5)) -> QuitThenInstall {
            QuitThenInstall(
                running: app?.handle, timeout: timeout, isCurrent: { self.isCurrent },
                show: { step in
                    self.steps.append(step)
                    if step == .quitting { self.whileQuitting() }
                },
                install: { self.installs += 1 })
        }
    }

    @Test func onePressQuitsTheAppThenInstalls() async {
        let app = FakeApp(.quitsAfter(.milliseconds(60)))
        let panel = Panel()
        #expect(await panel.sequence(app).run() == .installed(reopen: true))
        #expect(panel.steps == [.quitting, .installing])
        #expect(panel.installs == 1, "installed from the one press, with no second one")
        #expect(app.requests == 1)
    }

    @Test func anAppThatGoesBeforeTheRequestReturnsIsNotMissed() async {
        let app = FakeApp(.quitsDuringTheRequest)
        let panel = Panel()
        #expect(await panel.sequence(app).run() == .installed(reopen: true))
        #expect(panel.installs == 1)
    }

    @Test func anAppThatDoesNotQuitInTimeRestoresThePromptAndInstallsNothing() async {
        let app = FakeApp(.neverQuits)
        let panel = Panel()
        #expect(await panel.sequence(app, timeout: .milliseconds(80)).run() == .quitFailed)
        #expect(panel.steps == [.quitting, .quitFailed])
        #expect(panel.installs == 0)
        #expect(!app.terminated, "never forced")
    }

    @Test func aRequestThatCannotBeSentFailsAtOnce() async {
        let app = FakeApp(.refusesTheRequest)
        let panel = Panel()
        let started = ContinuousClock.now
        #expect(await panel.sequence(app).run() == .quitFailed)
        #expect(ContinuousClock.now - started < .seconds(2), "doesn't sit out the timeout")
        #expect(panel.installs == 0)
    }

    @Test func cancelWhileTheAppIsQuittingInstallsNothing() async {
        let app = FakeApp(.quitsAfter(.milliseconds(60)))
        let panel = Panel()
        panel.whileQuitting = { panel.isCurrent = false }
        #expect(await panel.sequence(app).run() == .cancelled)
        #expect(panel.steps == [.quitting])
        #expect(panel.installs == 0)
    }

    @Test func nothingRunningInstallsStraightAway() async {
        let panel = Panel()
        #expect(await panel.sequence(nil).run() == .installed(reopen: false))
        #expect(panel.steps == [.installing])
        #expect(panel.installs == 1)
    }

    @Test func anAppAlreadyGoneIsNotAskedToQuit() async {
        let app = FakeApp(.quitsDuringTheRequest)
        let panel = Panel()
        _ = await panel.sequence(app).run()
        #expect(await panel.sequence(app).run() == .installed(reopen: true))
        #expect(app.requests == 1)
    }
}
