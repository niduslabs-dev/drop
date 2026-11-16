import AppKit

/// The running copy Quit and Update has to quit first, as closures, so tests pass a fake
/// that quits when (or whether) they say.
@MainActor
struct RunningApp: Sendable {
    var isTerminated: @MainActor @Sendable () -> Bool
    /// Asks the app to quit as its Quit menu item would; never forces. False when the
    /// request couldn't be sent.
    var requestQuit: @MainActor @Sendable () -> Bool
    /// Starts watching for the app's end when called, and yields once it has ended (at
    /// once when it already has).
    var terminations: @MainActor @Sendable () -> AsyncStream<Void>
}

extension RunningApp {
    /// A real app. Its end is observed through KVO on `isTerminated`, which AppKit
    /// updates on the main run loop.
    init(_ app: NSRunningApplication) {
        nonisolated(unsafe) let app = app
        self.init(
            isTerminated: { app.isTerminated },
            requestQuit: { app.terminate() },
            terminations: {
                AsyncStream { continuation in
                    let observation = app.observe(\.isTerminated, options: [.initial, .new]) { app, _ in
                        guard app.isTerminated else { return }
                        continuation.yield()
                        continuation.finish()
                    }
                    let box = ObservationBox(observation)
                    continuation.onTermination = { _ in box.invalidate() }
                }
            })
    }
}

/// Keeps a KVO observation alive for an `AsyncStream` and ends it with the stream.
private final class ObservationBox: @unchecked Sendable {
    private let observation: NSKeyValueObservation
    init(_ observation: NSKeyValueObservation) { self.observation = observation }
    func invalidate() { observation.invalidate() }
}

/// Quit and Update as one step: one press quits the running copy, waits for it to go and
/// installs, with no second press. The panel, the session and the app are injected, so the
/// sequence is tested with fakes (`QuitThenInstallTests`).
@MainActor
struct QuitThenInstall {
    enum Step: Equatable, Sendable {
        /// The app was asked to quit: the primary reads "Quitting …", the controls dim.
        case quitting
        /// The app has gone (or none was running): the install runs.
        case installing
        /// The app didn't quit in time: the controls come back with the "didn't quit"
        /// message and the button reads Quit and Update again.
        case quitFailed
    }

    enum Outcome: Equatable, Sendable {
        /// The install ran. `reopen`: a running copy was quit for it, so the new one opens.
        case installed(reopen: Bool)
        case quitFailed
        /// The panel was cancelled or closed while the app was quitting: nothing installed.
        case cancelled
    }

    /// The installed copy, when it is running.
    var running: RunningApp?
    /// How long the app gets to quit by itself.
    var timeout: Duration = Theme.Timing.quitTimeout
    /// False once the panel was cancelled or replaced.
    var isCurrent: @MainActor () -> Bool
    /// Tells the panel which step shows.
    var show: @MainActor (Step) -> Void
    /// Runs the session's install to its end.
    var install: @MainActor () async -> Void

    func run() async -> Outcome {
        var reopen = false
        if let running {
            show(.quitting)
            let quit = await Self.quit(running, timeout: timeout)
            guard isCurrent() else { return .cancelled }
            guard quit else {
                show(.quitFailed)
                return .quitFailed
            }
            reopen = true
        }
        show(.installing)
        await install()
        return .installed(reopen: reopen)
    }

    /// Asks `app` to quit and waits until it has, or `timeout` passes. Never forces: an
    /// app with unsaved work may ask the user, and the user may say no.
    ///
    /// The watch starts before the request, so an app that goes at once is never missed,
    /// and `isTerminated` is read again at the end whatever the watch reported.
    static func quit(_ app: RunningApp, timeout: Duration) async -> Bool {
        if app.isTerminated() { return true }
        let terminations = app.terminations()
        guard app.requestQuit() else { return app.isTerminated() }
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in terminations { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return ended || app.isTerminated()
    }
}
